import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'pc_client.dart';

/// Keeps thumbnails from the PC on the phone, so scrolling back is instant
/// and works without asking the PC again. Lives in the app's cache folder,
/// which Android may clear when space runs low.
class ThumbnailCache {
  ThumbnailCache(this.client);

  final PcClient client;
  Directory? _dir;

  Future<Directory> _cacheDir() async =>
      _dir ??= await Directory('${(await getApplicationCacheDirectory()).path}'
              '/thumbs/${client.pairing.pcId}')
          .create(recursive: true);

  /// Thumbnail bytes for [path] at [size]; null if the PC has no preview.
  /// [modified] is part of the cache key, so edited files get new previews.
  Future<Uint8List?> get(String path, DateTime modified, int size) async {
    final key = sha1
        .convert(utf8.encode('$path|${modified.millisecondsSinceEpoch}|$size'))
        .toString();
    final file = File('${(await _cacheDir()).path}/$key.jpg');
    if (await file.exists()) return file.readAsBytes();
    final bytes = await client.thumbnail(path, size);
    if (bytes != null) {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes);
      await tmp.rename(file.path);
    }
    return bytes;
  }
}

/// The file has no preview on the PC (e.g. a document).
class NoPreview implements Exception {
  const NoPreview();
}

/// An image of a file on the PC, loaded through [ThumbnailCache]. Flutter
/// also keeps decoded images in memory, keyed by [PcImage]'s equality.
@immutable
class PcImage extends ImageProvider<PcImage> {
  const PcImage(this.cache, this.entryPath, this.entry, this.size);

  final ThumbnailCache cache;
  final String entryPath;
  final RemoteEntry entry;
  final int size;

  @override
  Future<PcImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(PcImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: '$entryPath@$size',
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await cache.get(entryPath, entry.modified, size);
    if (bytes == null) throw const NoPreview();
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is PcImage &&
      other.cache.client.pairing.pcId == cache.client.pairing.pcId &&
      other.entryPath == entryPath &&
      other.entry.modified == entry.modified &&
      other.size == size;

  @override
  int get hashCode => Object.hash(cache.client.pairing.pcId, entryPath,
      entry.modified.millisecondsSinceEpoch, size);
}
