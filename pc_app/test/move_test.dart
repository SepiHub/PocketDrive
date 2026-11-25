import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
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

  Future<(int, Map<String, Object?>)> move(
    List<String> paths,
    String to, {
    bool auth = true,
  }) async {
    final req = await client.postUrl(
      Uri(
        scheme: 'https',
        host: '127.0.0.1',
        port: server.port,
        path: Api.move,
        queryParameters: {'to': to},
      ),
    );
    if (auth) req.headers.set(Api.authHeader, Api.bearer(token));
    final body = utf8.encode(jsonEncode({'paths': paths}));
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, (jsonDecode(text) as Map).cast<String, Object?>());
  }

  String share(String rel) => p.joinAll([f.share, ...rel.split('/')]);

  test('moves files into a folder, keeping names', () async {
    File(share('m1.txt')).writeAsStringSync('1');
    File(share('m2.txt')).writeAsStringSync('2');
    final (status, json) = await move(['m1.txt', 'm2.txt'], 'sub');
    expect(status, 200);
    expect(json['failed'], isEmpty);
    expect(File(share('sub/m1.txt')).readAsStringSync(), '1');
    expect(File(share('m1.txt')).existsSync(), isFalse);
  });

  test('never overwrites: a clash gets (2)', () async {
    File(share('clash.txt')).writeAsStringSync('new');
    File(share('sub/clash.txt')).writeAsStringSync('old');
    final (_, json) = await move(['clash.txt'], 'sub');
    expect((json['moved'] as List).single, {
      'from': 'clash.txt',
      'name': 'clash (2).txt',
    });
    expect(File(share('sub/clash.txt')).readAsStringSync(), 'old');
  });

  test('moves folders, but never into themselves', () async {
    Directory(share('box/inner')).createSync(recursive: true);
    var (_, json) = await move(['box'], 'box/inner');
    expect((json['failed'] as List).single['error'], 'into_itself');
    expect(Directory(share('box')).existsSync(), isTrue);

    Directory(share('target')).createSync();
    (_, json) = await move(['box'], 'target');
    expect(json['failed'], isEmpty);
    expect(Directory(share('target/box/inner')).existsSync(), isTrue);
  });

  test('moving back up to the top works', () async {
    File(share('sub/up.txt')).writeAsStringSync('u');
    final (_, json) = await move(['sub/up.txt'], '');
    expect(json['failed'], isEmpty);
    expect(File(share('up.txt')).existsSync(), isTrue);
  });

  test('refuses escapes, links, the root and hidden files', () async {
    final (status, json) = await move([
      '',
      '..',
      '../outside/secret.txt',
      'escape',
      'escape/secret.txt',
      'inner',
      '.hidden',
      'nope.txt',
    ], 'sub');
    expect(status, 200);
    expect(json['moved'], isEmpty);
    expect((json['failed'] as List).length, 8);
    expect(File(p.join(f.outside, 'secret.txt')).existsSync(), isTrue);
    expect(Directory(share('escape')).existsSync(), isTrue);
  });

  test('bad targets and no token', () async {
    File(share('stay.txt')).writeAsStringSync('s');
    expect((await move(['stay.txt'], 'escape')).$1, 400);
    expect((await move(['stay.txt'], '..')).$1, 400);
    expect((await move(['stay.txt'], 'a.txt')).$1, 400);
    expect((await move(['stay.txt'], 'sub', auth: false)).$1, 401);
    expect(File(share('stay.txt')).existsSync(), isTrue);
    expect(File(p.join(f.outside, 'stay.txt')).existsSync(), isFalse);
  });
}
