import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One subtitle track inside a video file.
class SubtitleTrack {
  const SubtitleTrack({
    required this.index,
    required this.codec,
    this.language,
    this.title,
  });

  /// Position among the file's subtitle tracks (0, 1, 2, ...).
  final int index;
  final String codec;
  final String? language;
  final String? title;

  /// Picture-based subtitles (Blu-ray/DVD) can't be turned into text.
  bool get isText => !_pictureCodecs.contains(codec);

  Map<String, Object?> toJson() => {
    'index': index,
    'codec': codec,
    if (language != null) 'language': language,
    if (title != null) 'title': title,
    'text': isText,
  };
}

const _pictureCodecs = {
  'hdmv_pgs_subtitle',
  'dvd_subtitle',
  'dvb_subtitle',
  'xsub',
  'dvb_teletext',
};

/// Reads the subtitle tracks built into video files (MKV, MP4, ...) with
/// FFmpeg, and converts a chosen track to WebVTT for the phone. Converted
/// tracks are cached in `%LOCALAPPDATA%\PocketDrive\subs`.
class SubtitleService {
  SubtitleService(this.cacheDir);

  final Directory cacheDir;
  String? _ffprobe;
  String? _ffmpeg;
  final _inFlight = <String, Future<File?>>{};

  /// Whether FFmpeg is installed (looked up again until found, so installing
  /// it works without restarting PocketDrive).
  Future<bool> available() async {
    _ffprobe ??= await findFfmpegTool('ffprobe');
    _ffmpeg ??= await findFfmpegTool('ffmpeg');
    return _ffprobe != null && _ffmpeg != null;
  }

  /// The subtitle tracks in [realPath] (empty if none or no FFmpeg).
  Future<List<SubtitleTrack>> tracks(String realPath) async {
    if (!await available()) return const [];
    final r = await Process.run(_ffprobe!, [
      '-v', 'error', //
      '-select_streams', 's',
      '-show_entries', 'stream=index,codec_name:stream_tags=language,title',
      '-of', 'json',
      realPath,
    ], stdoutEncoding: utf8).timeout(const Duration(seconds: 30));
    if (r.exitCode != 0) return const [];
    return parseFfprobeTracks(r.stdout as String);
  }

  /// Track [track] of [realPath] as a WebVTT file, or null if it can't be
  /// converted. Can take a while for a big file the first time (FFmpeg reads
  /// through the whole video); after that it comes from the cache.
  Future<File?> webVtt(String realPath, int track) async {
    if (!await available()) return null;
    final stat = await File(realPath).stat();
    final key = sha1
        .convert(
          utf8.encode(
            '${realPath.toLowerCase()}|'
            '${stat.modified.millisecondsSinceEpoch}|${stat.size}|$track',
          ),
        )
        .toString();
    final out = File(p.join(cacheDir.path, '$key.vtt'));
    if (await out.exists()) return out;
    return _inFlight[key] ??= _convert(realPath, track, out).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<File?> _convert(String realPath, int track, File out) async {
    await cacheDir.create(recursive: true);
    final tmp = File('${out.path}.tmp');
    final r = await Process.run(_ffmpeg!, [
      '-nostdin', '-v', 'error', '-y', //
      '-i', realPath,
      '-map', '0:s:$track',
      '-c:s', 'webvtt',
      '-f', 'webvtt',
      tmp.path,
    ]).timeout(const Duration(minutes: 3));
    if (r.exitCode != 0 || !await tmp.exists()) {
      if (await tmp.exists()) await tmp.delete();
      return null;
    }
    await tmp.rename(out.path);
    return out;
  }
}

/// `%LOCALAPPDATA%\PocketDrive\subs`.
Directory defaultSubtitleCache() => Directory(
  p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'PocketDrive',
    'subs',
  ),
);

/// Parses `ffprobe -show_entries stream=... -of json` output.
List<SubtitleTrack> parseFfprobeTracks(String json) {
  final streams = (jsonDecode(json) as Map)['streams'] as List? ?? const [];
  return [
    for (final (i, s) in streams.indexed)
      SubtitleTrack(
        index: i,
        codec: ((s as Map)['codec_name'] as String?) ?? 'unknown',
        language: _tag(s, 'language'),
        title: _tag(s, 'title'),
      ),
  ];
}

String? _tag(Map stream, String name) {
  final tags = stream['tags'];
  if (tags is! Map) return null;
  for (final MapEntry(:key, :value) in tags.entries) {
    if ((key as String).toLowerCase() == name && value is String) {
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

/// Finds an FFmpeg tool: on the PATH, or where winget installs it (so it
/// works right after `winget install Gyan.FFmpeg`, before any restart).
Future<String?> findFfmpegTool(String name) async {
  try {
    final r = await Process.run('where', ['$name.exe']);
    if (r.exitCode == 0) {
      final first = (r.stdout as String).split(RegExp(r'\r?\n')).first.trim();
      if (first.isNotEmpty) return first;
    }
  } on Object {
    // fall through
  }
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) return null;
  final packages = Directory(p.join(local, 'Microsoft', 'WinGet', 'Packages'));
  if (!await packages.exists()) return null;
  await for (final dir in packages.list()) {
    if (dir is! Directory ||
        !p.basename(dir.path).toLowerCase().contains('ffmpeg')) {
      continue;
    }
    await for (final f in dir.list(recursive: true)) {
      if (f is File && p.basename(f.path).toLowerCase() == '$name.exe') {
        return f.path;
      }
    }
  }
  return null;
}
