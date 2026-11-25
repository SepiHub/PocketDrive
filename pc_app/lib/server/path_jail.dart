import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// The request named a path we refuse to touch (bad syntax or outside the
/// shared folder). The reason is for logs only, never sent to clients.
class PathRejected implements Exception {
  const PathRejected(this.reason);
  final String reason;
  @override
  String toString() => 'PathRejected: $reason';
}

class PathNotFound implements Exception {
  const PathNotFound();
}

/// Windows device names that refer to devices, not files, in any folder and
/// with any extension (`nul.txt` is the NUL device).
final _reservedNames = {
  'CON', 'PRN', 'AUX', 'NUL', 'CONIN\$', 'CONOUT\$', //
  for (final n in [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '¹',
    '²',
    '³',
  ]) ...['COM$n', 'LPT$n'],
};

/// `:` blocks drive letters and NTFS alternate data streams (`a.txt::$DATA`),
/// `\` blocks the second separator (clients must use `/`).
final _badChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Names we never list or serve.
bool isHiddenName(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('.') ||
      lower == 'desktop.ini' ||
      lower == 'thumbs.db' ||
      lower.endsWith('.partial');
}

/// Confines every file access to one folder.
///
/// A client path is first checked for syntax (no `..`, no absolute or drive
/// paths, no streams, no device names), then joined to the shared folder, and
/// finally resolved through symlinks and junctions with the OS. Only if the
/// real, final path is still inside the shared folder's real path is it used.
class PathJail {
  PathJail._(this.root);

  /// Real (fully resolved) path of the shared folder.
  final String root;

  static Future<PathJail> open(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) {
      throw ArgumentError.value(folder, 'folder', 'does not exist');
    }
    return PathJail._(p.normalize(await dir.resolveSymbolicLinks()));
  }

  /// Splits a client path like `Photos/2024/a.jpg` into checked segments.
  static List<String> splitRelative(String rel) {
    if (rel.isEmpty) return const [];
    if (rel.length > 2048) throw const PathRejected('too long');
    final parts = rel.split('/');
    for (final part in parts) {
      checkName(part);
    }
    return parts;
  }

  /// Checks one file or folder name.
  static void checkName(String name) {
    if (name.isEmpty) throw const PathRejected('empty segment');
    if (name == '.' || name == '..') throw const PathRejected('dot segment');
    if (_badChars.hasMatch(name)) throw const PathRejected('bad character');
    // Windows silently drops trailing dots and spaces ("a.txt." opens
    // "a.txt"), so refuse them rather than reason about it.
    if (name.endsWith('.') || name.endsWith(' ')) {
      throw const PathRejected('trailing dot or space');
    }
    final stem = name.split('.').first.trimRight().toUpperCase();
    if (_reservedNames.contains(stem)) {
      throw const PathRejected('device name');
    }
  }

  /// True if [realPath] is the shared folder or inside it.
  /// (The `path` package compares case-insensitively on Windows.)
  bool contains(String realPath) =>
      p.equals(root, realPath) || p.isWithin(root, realPath);

  /// Returns the real path of an existing file or folder named by [rel].
  ///
  /// Throws [PathRejected] or [PathNotFound].
  Future<String> resolveExisting(String rel) async {
    final joined = p.joinAll([root, ...splitRelative(rel)]);
    final String real;
    try {
      real = p.normalize(await File(joined).resolveSymbolicLinks());
    } on FileSystemException {
      throw const PathNotFound();
    }
    if (!contains(real)) throw const PathRejected('outside shared folder');
    return real;
  }

  /// Lists the folder named by [rel]. Entries that resolve outside the shared
  /// folder, broken links, hidden names and names we couldn't address
  /// anyway are left out.
  Future<List<RemoteEntry>> list(String rel) async {
    final dirPath = await resolveExisting(rel);
    if (!await FileSystemEntity.isDirectory(dirPath)) {
      throw const NotADirectory();
    }
    final entries = <RemoteEntry>[];
    await for (final e in Directory(dirPath).list(followLinks: false)) {
      final name = p.basename(e.path);
      if (isHiddenName(name)) continue;
      try {
        checkName(name);
      } on PathRejected {
        continue;
      }
      var target = e.path;
      // Links (and junctions, and folders, to be safe) are resolved and must
      // stay inside the jail. Plain files can't point anywhere else.
      if (e is Link || e is Directory) {
        try {
          target = p.normalize(await e.resolveSymbolicLinks());
        } on FileSystemException {
          continue; // broken link
        }
        if (!contains(target)) continue;
      }
      final stat = await FileStat.stat(target);
      switch (stat.type) {
        case FileSystemEntityType.directory:
          entries.add(
            RemoteEntry(
              name: name,
              type: EntryType.dir,
              size: 0,
              modified: stat.modified,
              kind: MediaKind.other,
              fileCount: await _countFiles(target),
            ),
          );
        case FileSystemEntityType.file:
          entries.add(
            RemoteEntry(
              name: name,
              type: EntryType.file,
              size: stat.size,
              modified: stat.modified,
              kind: mediaKindForName(name),
            ),
          );
        default:
          continue;
      }
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }
}

/// Number of visible files directly in [dir] (what the phone would list).
Future<int?> _countFiles(String dir) async {
  try {
    var n = 0;
    await for (final e in Directory(dir).list(followLinks: false)) {
      if (e is File && !isHiddenName(p.basename(e.path))) n++;
    }
    return n;
  } on FileSystemException {
    return null; // unreadable folder: just don't show a count
  }
}

class NotADirectory implements Exception {
  const NotADirectory();
}
