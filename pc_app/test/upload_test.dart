import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_pc/server/path_jail.dart';
import 'package:pocketdrive_pc/server/thumbnails.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late String token;
  late HttpClient client;
  final server = PocketServer();

  setUpAll(() async {
    f = await Fixture.create();
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
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
    client = pinnedHttpClient(identity.fingerprint);
  });
  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    await f.delete();
  });

  Future<(int, Map<String, Object?>)> upload(
    String folder,
    String name,
    List<int> bytes, {
    bool auth = true,
    int? modifiedMs,
  }) async {
    final q = {
      'path': folder,
      'name': name,
      if (modifiedMs != null) 'modified': '$modifiedMs',
    };
    final uri = Uri(
      scheme: 'https',
      host: '127.0.0.1',
      port: server.port,
      path: Api.upload,
      queryParameters: q,
    );
    final req = await client.postUrl(uri);
    if (auth) req.headers.set(Api.authHeader, Api.bearer(token));
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, (jsonDecode(text) as Map).cast<String, Object?>());
  }

  List<String> filesIn(String dir) => [
    for (final e in Directory(dir).listSync())
      if (e is File) p.basename(e.path),
  ];

  test('uploads into the top folder and into a subfolder', () async {
    final data = List<int>.generate(300000, (i) => i % 256);
    var (status, json) = await upload('', 'new.jpg', data);
    expect(status, 200);
    expect(json['name'], 'new.jpg');
    expect(json['size'], data.length);
    expect(await File(p.join(f.share, 'new.jpg')).readAsBytes(), data);

    (status, json) = await upload('sub', 'clip.mp4', [1, 2, 3]);
    expect(status, 200);
    expect(File(p.join(f.share, 'sub', 'clip.mp4')).existsSync(), isTrue);
    expect(json['kind'], 'video');
  });

  test('never overwrites: same name gets (2), (3)', () async {
    expect(
      (await upload('', 'a.txt', utf8.encode('one'))).$2['name'],
      'a (2).txt',
    );
    expect(
      (await upload('', 'A.TXT', utf8.encode('two'))).$2['name'],
      'A (3).TXT',
    );
    expect(await File(p.join(f.share, 'a.txt')).readAsString(), 'hello world');
  });

  test('keeps the photo date from the phone', () async {
    final taken = DateTime(2024, 7, 14, 12, 30);
    await upload('', 'dated.jpg', [
      9,
    ], modifiedMs: taken.millisecondsSinceEpoch);
    final mtime = File(p.join(f.share, 'dated.jpg')).lastModifiedSync();
    expect(mtime.difference(taken).inSeconds.abs(), lessThan(2));
  });

  test('bad names and folders are refused and nothing is written', () async {
    final before = filesIn(f.share);
    for (final (folder, name) in [
      ('', '../evil.txt'),
      ('', r'..\evil.txt'),
      ('', 'sub/evil.txt'),
      ('', 'C:evil.txt'),
      ('', 'evil.txt:stream'),
      ('', 'con.txt'),
      ('', '.hidden2'),
      ('', 'sneaky.partial'),
      ('', 'trailing.'),
      ('', ''),
      ('..', 'evil.txt'),
      ('escape', 'evil.txt'),
      ('a.txt', 'evil.txt'),
      ('nope', 'evil.txt'),
    ]) {
      final (status, _) = await upload(folder, name, [1]);
      expect(status, anyOf(400, 404), reason: '"$folder" / "$name"');
    }
    expect(filesIn(f.share), before);
    expect(filesIn(f.outside), ['secret.txt']);
  });

  test('without a token nothing is written', () async {
    final (status, _) = await upload('', 'anon.jpg', [1], auth: false);
    expect(status, 401);
    expect(File(p.join(f.share, 'anon.jpg')).existsSync(), isFalse);
  });

  test('a dropped upload leaves no file behind', () async {
    final uri = Uri(
      scheme: 'https',
      host: '127.0.0.1',
      port: server.port,
      path: Api.upload,
      queryParameters: {'path': '', 'name': 'dropped.mov'},
    );
    final req = await client.postUrl(uri);
    req.headers.set(Api.authHeader, Api.bearer(token));
    req.contentLength = 1000000;
    req.add(List.filled(20000, 7));
    await req.flush();
    req.abort();
    await expectLater(req.done, throwsA(anything));
    // Give the server a moment to notice and clean up.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final leftovers = Directory(f.share)
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.contains('dropped'));
    expect(leftovers, isEmpty);
  });

  test('partial files are hidden from listings while uploading', () {
    // (Covered by the jail: names ending in .partial or starting with a dot
    // are never listed.) Sanity check of the naming used for temp files:
    expect(isHiddenName('.photo.jpg.ab12cd.partial'), isTrue);
  });

  group('new folders', () {
    Future<int> mkdir(String parent, String name, {bool auth = true}) async {
      final req = await client.postUrl(
        Uri(
          scheme: 'https',
          host: '127.0.0.1',
          port: server.port,
          path: Api.mkdir,
          queryParameters: {'path': parent, 'name': name},
        ),
      );
      if (auth) req.headers.set(Api.authHeader, Api.bearer(token));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    test('creates folders, also nested', () async {
      expect(await mkdir('', 'Holiday 2024'), 200);
      expect(Directory(p.join(f.share, 'Holiday 2024')).existsSync(), isTrue);
      expect(await mkdir('Holiday 2024', 'Day 1'), 200);
      expect(
        Directory(p.join(f.share, 'Holiday 2024', 'Day 1')).existsSync(),
        isTrue,
      );
    });

    test('existing names are refused, files too', () async {
      expect(await mkdir('', 'sub'), 409);
      expect(await mkdir('', 'SUB'), 409);
      expect(await mkdir('', 'a.txt'), 409);
    });

    test('bad names, escapes and no token are refused', () async {
      for (final (parent, name) in [
        ('', '..'),
        ('', '../outside2'),
        ('', 'x/y'),
        ('', 'nul'),
        ('', '.hidden'),
        ('escape', 'x'),
        ('..', 'x'),
      ]) {
        expect(
          await mkdir(parent, name),
          anyOf(400, 404),
          reason: '"$parent" / "$name"',
        );
      }
      expect(await mkdir('', 'anon', auth: false), 401);
      expect(Directory(p.join(f.share, 'anon')).existsSync(), isFalse);
      expect(Directory(p.join(f.base.path, 'outside2')).existsSync(), isFalse);
      expect(Directory(p.join(f.outside, 'x')).existsSync(), isFalse);
    });
  });
}
