import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Makes JPEG thumbnails for photos and videos and caches them on disk.
///
/// Uses the Windows shell thumbnail engine (the one Explorer uses), so every
/// format Windows can preview works: JPEG, PNG, HEIC (with Microsoft's HEIF
/// extension), MP4, MOV, ... Falls back to decoding common image formats in
/// Dart if the shell has nothing.
class ThumbnailService {
  ThumbnailService(this.cacheDir, {int maxParallel = 4})
    : _slots = _Semaphore(maxParallel);

  /// Sizes we render; requests snap up to the next one so the cache stays
  /// small. The phone uses 256 for the grid and 2048 for the viewer.
  static const sizes = [128, 256, 512, 1024, 2048];

  final Directory cacheDir;
  final _Semaphore _slots;
  final _inFlight = <String, Future<File?>>{};
  final _failed = <String>{};

  static int snapSize(int? requested) {
    for (final s in sizes) {
      if ((requested ?? 256) <= s) return s;
    }
    return sizes.last;
  }

  /// Returns a cached JPEG for [realPath] at [size], or null if Windows
  /// can't make a thumbnail for it.
  Future<File?> thumbnail(String realPath, int size) async {
    final stat = await File(realPath).stat();
    final key = sha1
        .convert(
          utf8.encode(
            '${realPath.toLowerCase()}|'
            '${stat.modified.millisecondsSinceEpoch}|${stat.size}|$size',
          ),
        )
        .toString();
    if (_failed.contains(key)) return null;
    final out = File(p.join(cacheDir.path, key.substring(0, 2), '$key.jpg'));
    if (await out.exists()) return out;
    // Several tiles may ask for the same thumbnail at once: render it once.
    // (The block body matters: returning the removed future from
    // whenComplete would make the future wait for itself.)
    return _inFlight[key] ??= _make(realPath, size, key, out).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<File?> _make(String path, int size, String key, File out) async {
    await _slots.acquire();
    try {
      final jpeg = await _renderInIsolate(path, size);
      if (jpeg == null) {
        _failed.add(key);
        return null;
      }
      await out.parent.create(recursive: true);
      final tmp = File('${out.path}.tmp');
      await tmp.writeAsBytes(jpeg, flush: true);
      await tmp.rename(out.path);
      return out;
    } finally {
      _slots.release();
    }
  }
}

/// Top-level so the isolate closure captures only [path] and [size], not
/// the service object.
Future<Uint8List?> _renderInIsolate(String path, int size) =>
    Isolate.run(() => makeThumbnailJpeg(path, size));

/// Renders a JPEG thumbnail that fits in [size] x [size]. Runs on its own
/// thread (isolate) because it initializes COM. Returns null if impossible.
Uint8List? makeThumbnailJpeg(String path, int size) {
  final image = _shellThumbnail(path, size) ?? _dartThumbnail(path, size);
  if (image == null) return null;
  return img.encodeJpg(image, quality: 82);
}

img.Image? _shellThumbnail(String path, int size) {
  final hr = CoInitializeEx(COINIT_MULTITHREADED);
  final comReady = !hr.isError;
  final arena = Arena();
  HBITMAP? hbm;
  IShellItemImageFactory? factory;
  try {
    factory = SHCreateItemFromParsingName<IShellItemImageFactory>(
      arena.pcwstr(path),
      null,
    );
    final sz = arena<SIZE>().ref
      ..cx = size
      ..cy = size;
    // THUMBNAILONLY: real previews only, never a generic file icon.
    hbm = factory.getImage(sz, SIIGBF_THUMBNAILONLY);
    return _bitmapToImage(hbm, arena);
  } on Object {
    return null;
  } finally {
    if (hbm != null) DeleteObject(HGDIOBJ(hbm));
    factory?.release();
    arena.releaseAll();
    if (comReady) CoUninitialize();
  }
}

img.Image? _bitmapToImage(HBITMAP hbm, Arena arena) {
  final bm = arena<BITMAP>();
  if (GetObject(HGDIOBJ(hbm), sizeOf<BITMAP>(), bm) == 0) return null;
  final w = bm.ref.bmWidth;
  final h = bm.ref.bmHeight.abs();
  if (w <= 0 || h <= 0) return null;

  final info = arena<BITMAPINFO>();
  info.ref.bmiHeader
    ..biSize = sizeOf<BITMAPINFOHEADER>()
    ..biWidth = w
    ..biHeight =
        -h // top-down rows
    ..biPlanes = 1
    ..biBitCount = 32
    ..biCompression = BI_RGB;
  final pixels = arena<Uint8>(w * h * 4);
  final hdc = GetDC(null);
  try {
    final lines = GetDIBits(hdc, hbm, 0, h, pixels, info, DIB_RGB_COLORS);
    if (lines != h) return null;
  } finally {
    ReleaseDC(null, hdc);
  }
  final bytes = Uint8List.fromList(pixels.asTypedList(w * h * 4));
  // Shell bitmaps are BGRA. Thumbnails are opaque; ignore the alpha byte.
  return img.Image.fromBytes(
    width: w,
    height: h,
    bytes: bytes.buffer,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  ).convert(numChannels: 3);
}

const _dartDecodable = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'};

img.Image? _dartThumbnail(String path, int size) {
  if (!_dartDecodable.contains(p.extension(path).toLowerCase())) return null;
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return null;
    final oriented = img.bakeOrientation(decoded);
    final landscape = oriented.width >= oriented.height;
    if ((landscape ? oriented.width : oriented.height) <= size) {
      return oriented;
    }
    return landscape
        ? img.copyResize(oriented, width: size)
        : img.copyResize(oriented, height: size);
  } on Object {
    return null;
  }
}

class _Semaphore {
  _Semaphore(this._free);
  int _free;
  final _waiting = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _free++;
    }
  }
}
