import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// App settings, stored in `%APPDATA%\PocketDrive\config.json`.
class AppConfig {
  AppConfig({this.sharedFolder});

  String? sharedFolder;

  static Directory get dataDir {
    final base = Platform.environment['APPDATA'] ?? Directory.current.path;
    return Directory(p.join(base, 'PocketDrive'));
  }

  static File get _file => File(p.join(dataDir.path, 'config.json'));

  static Future<AppConfig> load() async {
    try {
      final json = jsonDecode(await _file.readAsString()) as Map;
      return AppConfig(sharedFolder: json['sharedFolder'] as String?);
    } on Object {
      return AppConfig(); // missing or unreadable: start fresh
    }
  }

  Future<void> save() async {
    await dataDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert({'sharedFolder': sharedFolder}),
    );
    await tmp.rename(_file.path);
  }
}

/// Returns why [folder] shouldn't be shared, or null if it's fine.
String? checkShareableFolder(String folder) {
  final full = p.normalize(p.absolute(folder));
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
