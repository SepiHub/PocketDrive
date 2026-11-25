import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'path_jail.dart';

/// Sends files/folders to the Windows Recycle Bin (never deletes for good).
typedef Recycler = Future<void> Function(List<String> realPaths);

/// Deletes [paths] (relative to the shared folder) by moving them to the
/// Recycle Bin. Same safety rules as moving: inside the shared folder only,
/// not the shared folder itself, no links, no hidden/temp files.
///
/// Returns `{"deleted": [path], "failed": [{"path", "error"}]}`.
Future<Map<String, Object?>> deleteEntries(
  PathJail jail,
  List<String> paths, {
  Recycler recycler = recycleToBin,
}) async {
  final failed = <Map<String, String>>[];
  final ok = <String, String>{}; // rel -> real
  for (final rel in paths) {
    try {
      final parts = PathJail.splitRelative(rel);
      if (parts.isEmpty) throw const PathRejected('shared folder itself');
      if (isHiddenName(parts.last)) throw const PathRejected('hidden');
      final joined = p.joinAll([jail.root, ...parts]);
      if (await FileSystemEntity.type(joined, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const PathRejected('link');
      }
      ok[rel] = await jail.resolveExisting(rel);
    } on PathRejected {
      failed.add({'path': rel, 'error': 'bad_path'});
    } on PathNotFound {
      failed.add({'path': rel, 'error': 'not_found'});
    }
  }
  if (ok.isNotEmpty) await recycler(ok.values.toList());
  final deleted = <String>[];
  for (final MapEntry(key: rel, value: real) in ok.entries) {
    if (await FileSystemEntity.type(real, followLinks: false) ==
        FileSystemEntityType.notFound) {
      deleted.add(rel);
    } else {
      failed.add({'path': rel, 'error': 'delete_failed'});
    }
  }
  return {'deleted': deleted, 'failed': failed};
}

/// The real Recycle Bin, via the Windows shell (SHFileOperationW with
/// "allow undo"). Runs on its own thread because it blocks.
Future<void> recycleToBin(List<String> realPaths) =>
    Isolate.run(() => _shellRecycle(realPaths));

// SHFILEOPSTRUCTW, declared here (the win32 package doesn't expose the call).
final class _ShFileOp extends Struct {
  external Pointer<Void> hwnd;
  @Uint32()
  external int wFunc;
  external Pointer<Utf16> pFrom;
  external Pointer<Utf16> pTo;
  @Uint16()
  external int fFlags;
  @Int32()
  external int fAnyOperationsAborted;
  external Pointer<Void> hNameMappings;
  external Pointer<Utf16> lpszProgressTitle;
}

const _foDelete = 3;
const _fofSilent = 0x0004;
const _fofNoConfirmation = 0x0010;
const _fofAllowUndo = 0x0040; // = Recycle Bin instead of deleting
const _fofNoErrorUi = 0x0400;
// If something can't go to the Recycle Bin (e.g. a network drive), Windows
// asks on the PC instead of silently deleting it for good.
const _fofWantNukeWarning = 0x4000;

void _shellRecycle(List<String> paths) {
  final shFileOperation = DynamicLibrary.open('shell32.dll')
      .lookupFunction<
        Int32 Function(Pointer<_ShFileOp>),
        int Function(Pointer<_ShFileOp>)
      >('SHFileOperationW');
  // pFrom: paths separated by NUL, ending with a double NUL.
  final from = '${paths.join('\u0000')}\u0000\u0000';
  final arena = Arena();
  try {
    final op = arena<_ShFileOp>();
    op.ref
      ..hwnd = nullptr
      ..wFunc = _foDelete
      ..pFrom = from.toNativeUtf16(allocator: arena)
      ..pTo = nullptr
      ..fFlags =
          _fofAllowUndo |
          _fofNoConfirmation |
          _fofSilent |
          _fofNoErrorUi |
          _fofWantNukeWarning
      ..fAnyOperationsAborted = 0
      ..hNameMappings = nullptr
      ..lpszProgressTitle = nullptr;
    shFileOperation(op);
  } finally {
    arena.releaseAll();
  }
}
