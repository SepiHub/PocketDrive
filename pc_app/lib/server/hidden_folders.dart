import 'dart:convert';
import 'dart:io';

/// Folders the user hid on the phone. Kept on the PC (in PocketDrive's own
/// settings, `hidden.json`), so every paired phone sees the same thing and
/// nothing is changed in Windows: the folders stay normal in File Explorer.
///
/// Paths are relative to the shared folder (with `/`), compared without
/// case like Windows does, and kept per shared folder.
class HiddenFolders {
  HiddenFolders._(this._file, this._byRoot);

  /// A store that isn't saved anywhere (tests, or before loading).
  HiddenFolders.memory() : this._(null, {});

  final File? _file;
  final Map<String, Set<String>> _byRoot;

  static Future<HiddenFolders> load(File file) async {
    final byRoot = <String, Set<String>>{};
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      json.forEach((root, paths) {
        byRoot[root as String] = {for (final p in paths as List) p as String};
      });
    } on Object {
      // missing or unreadable: nothing hidden
    }
    return HiddenFolders._(file, byRoot);
  }

  Set<String> _set(String root) =>
      _byRoot.putIfAbsent(root.toLowerCase(), () => <String>{});

  bool isHidden(String root, String rel) =>
      _set(root).contains(rel.toLowerCase());

  Future<void> setHidden(String root, String rel, bool hidden) async {
    final set = _set(root);
    hidden ? set.add(rel.toLowerCase()) : set.remove(rel.toLowerCase());
    await _save();
  }

  /// A folder moved from [from] to [to]: it (and hidden folders inside it)
  /// stay hidden at the new place.
  Future<void> renamed(String root, String from, String to) async {
    final set = _set(root);
    final f = from.toLowerCase();
    final changed = [
      for (final p in set)
        if (p == f || p.startsWith('$f/')) p,
    ];
    if (changed.isEmpty) return;
    for (final p in changed) {
      set
        ..remove(p)
        ..add(to.toLowerCase() + p.substring(f.length));
    }
    await _save();
  }

  /// A folder was deleted: forget it and anything inside it.
  Future<void> removed(String root, String rel) async {
    final set = _set(root);
    final r = rel.toLowerCase();
    final before = set.length;
    set.removeWhere((p) => p == r || p.startsWith('$r/'));
    if (set.length != before) await _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        for (final MapEntry(key: root, value: paths) in _byRoot.entries)
          if (paths.isNotEmpty) root: paths.toList()..sort(),
      }),
    );
    await tmp.rename(file.path);
  }
}
