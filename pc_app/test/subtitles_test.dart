import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_pc/server/subtitles.dart';
import 'package:pocketdrive_pc/server/thumbnails.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

void main() {
  test('parses ffprobe output', () {
    final tracks = parseFfprobeTracks('''
{ "streams": [
  {"index": 2, "codec_name": "subrip", "tags": {"language": "eng"}},
  {"index": 3, "codec_name": "ass", "tags": {"language": "fre", "title": "Forced"}},
  {"index": 4, "codec_name": "hdmv_pgs_subtitle", "tags": {"LANGUAGE": "ger"}},
  {"index": 5, "codec_name": "subrip"}
]}''');
    expect(tracks.map((t) => t.index), [0, 1, 2, 3]);
    expect(tracks[0].language, 'eng');
    expect(tracks[1].title, 'Forced');
    expect(tracks[2].language, 'ger');
    expect(tracks[2].isText, isFalse);
    expect(tracks[3].language, isNull);
  });

  // End to end with the real FFmpeg (skipped if it isn't installed).
  group('built-in tracks over HTTPS', () {
    late Fixture f;
    late String token;
    late HttpClient client;
    final server = PocketServer();
    String? ffmpeg;

    setUpAll(() async {
      ffmpeg = await findFfmpegTool('ffmpeg');
      if (ffmpeg == null) return;
      f = await Fixture.create();
      // A 2-second video with two subtitle tracks (English, French).
      final en = File(p.join(f.base.path, 'en.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,500\nHello there\n');
      final fr = File(p.join(f.base.path, 'fr.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,500\nBonjour\n');
      final r = await Process.run(ffmpeg!, [
        '-v', 'error', '-y', //
        '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=2',
        '-i', en.path, '-i', fr.path,
        '-map', '0', '-map', '1', '-map', '2',
        '-c:v', 'mpeg4', '-c:s', 'srt',
        '-metadata:s:s:0', 'language=eng',
        '-metadata:s:s:1', 'language=fre',
        '-metadata:s:s:1', 'title=French',
        p.join(f.share, 'movie.mkv'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      final identity = await PcIdentity.loadOrCreate(
        Directory(p.join(f.base.path, 'id')),
      );
      final devices = await DeviceStore.load(
        File(p.join(f.base.path, 'dev.json')),
      );
      (_, token) = await devices.add('Test');
      await server.start(
        folder: f.share,
        devices: devices,
        identity: identity,
        pairingWindow: () => null,
        thumbs: ThumbnailService(Directory(p.join(f.base.path, 'thumbs'))),
        subtitles: SubtitleService(Directory(p.join(f.base.path, 'subs'))),
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      client = pinnedHttpClient(identity.fingerprint);
    });
    tearDownAll(() async {
      if (ffmpeg == null) return;
      client.close(force: true);
      await server.stop();
      await f.delete();
    });

    Future<(int, String)> get(String path, Map<String, String> q) async {
      final req = await client.getUrl(
        Uri(
          scheme: 'https',
          host: '127.0.0.1',
          port: server.port,
          path: path,
          queryParameters: q,
        ),
      );
      req.headers.set(Api.authHeader, Api.bearer(token));
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    }

    test('lists the tracks with language and title', () async {
      if (ffmpeg == null) return markTestSkipped('FFmpeg not installed');
      final (status, body) = await get(Api.subtitles, {'path': 'movie.mkv'});
      expect(status, 200);
      final json = jsonDecode(body) as Map;
      expect(json['available'], isTrue);
      final tracks = json['tracks'] as List;
      expect(tracks.length, 2);
      expect(tracks[0]['language'], 'eng');
      expect(tracks[1]['title'], 'French');
      expect(tracks[1]['text'], isTrue);
    });

    test('extracts a track as WebVTT', () async {
      if (ffmpeg == null) return markTestSkipped('FFmpeg not installed');
      var (status, body) = await get(Api.subtitle, {
        'path': 'movie.mkv',
        'track': '1',
      });
      expect(status, 200);
      expect(body, startsWith('WEBVTT'));
      expect(body, contains('Bonjour'));
      // Second time comes from the cache.
      (status, body) = await get(Api.subtitle, {
        'path': 'movie.mkv',
        'track': '0',
      });
      expect(body, contains('Hello there'));
    });

    test('bad tracks and paths', () async {
      if (ffmpeg == null) return markTestSkipped('FFmpeg not installed');
      expect(
        (await get(Api.subtitle, {'path': 'movie.mkv', 'track': '9'})).$1,
        404,
      );
      expect(
        (await get(Api.subtitle, {'path': 'movie.mkv', 'track': '-1'})).$1,
        400,
      );
      expect(
        (await get(Api.subtitle, {'path': 'movie.mkv', 'track': 'x'})).$1,
        400,
      );
      expect(
        (await get(Api.subtitles, {'path': '../outside/secret.txt'})).$1,
        400,
      );
      final (_, body) = await get(Api.subtitles, {'path': 'a.txt'});
      expect((jsonDecode(body) as Map)['tracks'], isEmpty);
    });
  });
}
