import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembers how far you got in each video, on the phone only.
///
/// A video is identified by PC, path and modified time, so a changed file
/// starts from the beginning. Only videos longer than [minVideo] are
/// remembered, and the most recent [maxEntries] are kept.
class ResumeStore {
  ResumeStore(this._prefs);

  static const _key = 'resume_positions';
  static const minVideo = Duration(minutes: 2);
  static const maxEntries = 300;

  final SharedPreferences _prefs;

  static Future<ResumeStore> load() async =>
      ResumeStore(await SharedPreferences.getInstance());

  static String idFor(String pcId, String path, DateTime modified) =>
      '$pcId|$path|${modified.millisecondsSinceEpoch}';

  Map<String, List<int>> _read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return {};
    try {
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries)
          key as String: [for (final n in value as List) (n as num).toInt()],
      };
    } on Object {
      return {};
    }
  }

  Future<void> _write(Map<String, List<int>> all) async {
    if (all.length > maxEntries) {
      final newest = all.entries.toList()
        ..sort((a, b) => b.value[1].compareTo(a.value[1]));
      all = Map.fromEntries(newest.take(maxEntries));
    }
    await _prefs.setString(_key, jsonEncode(all));
  }

  /// Where to continue [id], or null to start from the beginning.
  Duration? positionFor(String id) {
    final entry = _read()[id];
    return entry == null ? null : Duration(milliseconds: entry[0]);
  }

  /// Saves the position, or forgets it when there's nothing worth resuming
  /// (short video, barely started, or (nearly) finished).
  Future<void> save(String id, Duration position, Duration length) async {
    final all = _read();
    if (shouldRemember(position, length)) {
      all[id] = [
        position.inMilliseconds,
        DateTime.now().millisecondsSinceEpoch,
      ];
    } else if (all.remove(id) == null) {
      return;
    }
    await _write(all);
  }

  Future<void> clear(String id) async {
    final all = _read();
    if (all.remove(id) != null) await _write(all);
  }
}

/// Worth resuming: a long enough video, past the first 10 seconds and not
/// in the last 5% (or last 30 seconds) of it.
bool shouldRemember(Duration position, Duration length) {
  if (length < ResumeStore.minVideo) return false;
  if (position < const Duration(seconds: 10)) return false;
  final tail = length * 0.05 < const Duration(seconds: 30)
      ? const Duration(seconds: 30)
      : length * 0.05;
  return position < length - tail;
}
