import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_jail.dart';

/// Moves are done one at a time, so two moves can't pick the same free name.
Future<void> _moveChain = Future.value();

/// Moves files and folders (paths relative to the shared folder) into the
/// folder [targetRel]. Each item succeeds or fails on its own.
///
/// Rules: everything must be inside the shared folder (checked through the
/// jail, links resolved); the shared folder itself, links/junctions and
/// hidden or temp files can't be moved; a folder can't go into itself;
/// nothing is overwritten (`a.jpg` becomes `a (2).jpg`).
///
/// Returns `{"moved": [{"from": path, "name": newName}], "failed": [{"path":
/// path, "error": code}]}`.
Future<Map<String, Object?>> moveEntries(
  PathJail jail,
  List<String> paths,
  String targetRel,
) async {
  final target = await jail.resolveExisting(targetRel);
  if (!await FileSystemEntity.isDirectory(target)) throw const NotADirectory();

  final moved = <Map<String, String>>[];
  final failed = <Map<String, String>>[];
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
      final real = await jail.resolveExisting(rel);
      final isDir = await FileSystemEntity.isDirectory(real);
      if (isDir && (p.equals(real, target) || p.isWithin(real, target))) {
        throw const _MoveError('into_itself');
      }
      if (p.equals(p.dirname(real), target)) {
        moved.add({'from': rel, 'name': p.basename(real)}); // already there
        continue;
      }
      final done = Completer<String>();
      _moveChain = _moveChain.then((_) async {
        try {
          final dest = await _freeName(target, p.basename(real));
          if (isDir) {
            await Directory(real).rename(dest);
          } else {
            await File(real).rename(dest);
          }
          done.complete(p.basename(dest));
        } on Object catch (e, st) {
          done.completeError(e, st);
        }
      });
      moved.add({'from': rel, 'name': await done.future});
    } on PathRejected {
      failed.add({'path': rel, 'error': 'bad_path'});
    } on PathNotFound {
      failed.add({'path': rel, 'error': 'not_found'});
    } on _MoveError catch (e) {
      failed.add({'path': rel, 'error': e.code});
    } on FileSystemException {
      failed.add({'path': rel, 'error': 'move_failed'});
    }
  }
  return {'moved': moved, 'failed': failed};
}

class _MoveError implements Exception {
  const _MoveError(this.code);
  final String code;
}

/// `name`, or `name (2)`, `name (3)`, ... whichever doesn't exist yet.
Future<String> _freeName(String dir, String name) async {
  final ext = p.extension(name);
  final stem = p.basenameWithoutExtension(name);
  for (var i = 1; ; i++) {
    final candidate = p.join(dir, i == 1 ? name : '$stem ($i)$ext');
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) return candidate;
  }
}
