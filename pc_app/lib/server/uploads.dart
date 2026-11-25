import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import '../identity.dart';
import 'path_jail.dart';

/// The body ended before `Content-Length` bytes arrived (connection lost).
class UploadIncomplete implements Exception {
  const UploadIncomplete();
}

/// Writing to disk failed (full disk, permissions, ...).
class UploadWriteFailed implements Exception {
  const UploadWriteFailed(this.reason);
  final String reason;
}

/// Renames are done one at a time, so two uploads with the same name can't
/// both pick the same free name.
Future<void> _renameChain = Future.value();

/// Saves an uploaded file into [folderRel] (relative to the shared folder).
///
/// - [name] must be a plain, safe file name (same rules as all paths).
/// - Data goes to a hidden `.partial` file first; only a complete upload is
///   renamed into place, so a dropped connection never leaves half a photo.
/// - Existing files are never overwritten: `IMG.jpg` becomes `IMG (2).jpg`.
/// - [modified] (from the phone) becomes the file's modified time, so the PC
///   sorts photos by when they were taken rather than uploaded.
Future<RemoteEntry> receiveUpload(
  PathJail jail,
  String folderRel,
  String name,
  Stream<List<int>> body, {
  int? expectedLength,
  DateTime? modified,
}) async {
  PathJail.checkName(name);
  if (isHiddenName(name)) throw const PathRejected('hidden name');
  final dir = await jail.resolveExisting(folderRel);
  if (!await FileSystemEntity.isDirectory(dir)) throw const NotADirectory();

  final partial = File(p.join(dir, '.$name.${randomHex(6)}.partial'));
  var written = 0;
  try {
    final sink = partial.openWrite();
    try {
      await for (final chunk in body) {
        sink.add(chunk);
        written += chunk.length;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (expectedLength != null && written != expectedLength) {
      throw const UploadIncomplete();
    }
    if (modified != null) await partial.setLastModified(modified);

    final done = Completer<File>();
    _renameChain = _renameChain.then((_) async {
      try {
        done.complete(await partial.rename(await _freeName(dir, name)));
      } on Object catch (e, st) {
        done.completeError(e, st);
      }
    });
    final file = await done.future;
    final stat = await file.stat();
    final finalName = p.basename(file.path);
    return RemoteEntry(
      name: finalName,
      type: EntryType.file,
      size: stat.size,
      modified: stat.modified,
      kind: mediaKindForName(finalName),
    );
  } on UploadIncomplete {
    await _deleteQuietly(partial);
    rethrow;
  } on FileSystemException catch (e) {
    await _deleteQuietly(partial);
    throw UploadWriteFailed(e.osError?.message ?? e.message);
  } on Object {
    await _deleteQuietly(partial);
    rethrow;
  }
}

/// The name is already taken by a file or folder.
class AlreadyExists implements Exception {
  const AlreadyExists();
}

/// Creates folder [name] inside [parentRel]. Same name rules as uploads;
/// never touches an existing file or folder.
Future<RemoteEntry> createFolder(
  PathJail jail,
  String parentRel,
  String name,
) async {
  PathJail.checkName(name);
  if (isHiddenName(name)) throw const PathRejected('hidden name');
  final parent = await jail.resolveExisting(parentRel);
  if (!await FileSystemEntity.isDirectory(parent)) throw const NotADirectory();
  final target = p.join(parent, name);
  if (await FileSystemEntity.type(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const AlreadyExists();
  }
  try {
    final dir = await Directory(target).create();
    final stat = await dir.stat();
    return RemoteEntry(
      name: name,
      type: EntryType.dir,
      size: 0,
      modified: stat.modified,
      kind: MediaKind.other,
    );
  } on FileSystemException catch (e) {
    throw UploadWriteFailed(e.osError?.message ?? e.message);
  }
}

/// `name`, or `name (2)`, `name (3)`, ... whichever doesn't exist yet. Links
/// count as existing, so an upload never writes through one.
Future<String> _freeName(String dir, String name) async {
  final ext = p.extension(name);
  final stem = p.basenameWithoutExtension(name);
  for (var i = 1; ; i++) {
    final candidate = p.join(dir, i == 1 ? name : '$stem ($i)$ext');
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) return candidate;
  }
}

Future<void> _deleteQuietly(File f) async {
  try {
    await f.delete();
  } on FileSystemException {
    // already gone
  }
}
