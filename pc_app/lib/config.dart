import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// App settings, stored in `%APPDATA%\PocketDrive\config.json`.
class AppConfig {
  AppConfig({List<String>? sharedFolders})
    : sharedFolders = sharedFolders ?? [];

  /// The folders the phone can see, in the order they were added.
  final List<String> sharedFolders;

  static Directory get dataDir {
    final base = Platform.environment['APPDATA'] ?? Directory.current.path;
    return Directory(p.join(base, 'PocketDrive'));
  }

  static File get _file => File(p.join(dataDir.path, 'config.json'));

  static Future<AppConfig> load() async {
    try {
      final json = jsonDecode(await _file.readAsString()) as Map;
      final list = json['sharedFolders'];
      final old = json['sharedFolder']; // before several folders were allowed
      return AppConfig(
        sharedFolders: [
          if (list is List) ...list.whereType<String>(),
          if (list is! List && old is String) old,
        ],
      );
    } on Object {
      return AppConfig(); // missing or unreadable: start fresh
    }
  }

  Future<void> save() async {
    await dataDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert({'sharedFolders': sharedFolders}),
    );
    await tmp.rename(_file.path);
  }
}

/// Returns why [folder] shouldn't be shared, or null if it's fine.
/// [others] are the folders already shared.
String? checkShareableFolder(String folder, [List<String> others = const []]) {
  final full = p.normalize(p.absolute(folder));
  for (final other in others) {
    final o = p.normalize(p.absolute(other));
    if (p.equals(o, full)) return 'That folder is already shared.';
    if (p.isWithin(o, full)) {
      return 'That folder is inside one you already share.';
    }
    if (p.isWithin(full, o)) {
      return 'That folder contains one you already share. Remove that one '
          'first.';
    }
  }
  if (p.split(full).length <= 1) {
    return 'Pick a specific folder, not a whole drive.';
  }
  final windir = Platform.environment['SystemRoot'];
  if (windir != null &&
      (p.equals(windir, full) ||
          p.isWithin(windir, full) ||
          p.isWithin(full, windir))) {
    return 'That folder contains Windows system files. Pick another one.';
  }
  final profile = Platform.environment['USERPROFILE'];
  if (profile != null && p.equals(profile, full)) {
    return 'That is your whole user folder. Pick a folder inside it instead.';
  }
  if (!Directory(full).existsSync()) return 'That folder does not exist.';
  return null;
}
