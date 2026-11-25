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

/// The endpoint is tested with a stand-in Recycle Bin (it records what it
/// was given and removes it), so test runs don't fill the real one.
void main() {
  late Fixture f;
  late String token;
  late HttpClient client;
  final server = PocketServer();
  final recycled = <String>[];

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
      recycler: (paths) async {
        for (final path in paths) {
          recycled.add(path);
          await FileSystemEntity.isDirectory(path)
              ? await Directory(path).delete(recursive: true)
              : await File(path).delete();
        }
      },
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

  Future<(int, Map<String, Object?>)> delete(
    List<String> paths, {
    bool auth = true,
  }) async {
    final req = await client.postUrl(
      Uri(
        scheme: 'https',
        host: '127.0.0.1',
        port: server.port,
        path: Api.delete,
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

  test('deletes files and folders (to the Recycle Bin)', () async {
    File(share('d1.jpg')).writeAsStringSync('1');
    Directory(share('old/inner')).createSync(recursive: true);
    final (status, json) = await delete(['d1.jpg', 'old']);
    expect(status, 200);
    expect(json['deleted'], ['d1.jpg', 'old']);
    expect(File(share('d1.jpg')).existsSync(), isFalse);
    expect(Directory(share('old')).existsSync(), isFalse);
    expect(recycled.map(p.basename), containsAll(['d1.jpg', 'old']));
  });

  test('refuses escapes, links, the root and hidden files', () async {
    recycled.clear();
    final (status, json) = await delete([
      '',
      '..',
      '../outside/secret.txt',
      'escape',
      'escape/secret.txt',
      'inner',
      '.hidden',
      'nope.txt',
    ]);
    expect(status, 200);
    expect(json['deleted'], isEmpty);
    expect((json['failed'] as List).length, 8);
    expect(recycled, isEmpty, reason: 'nothing reached the Recycle Bin');
    expect(File(p.join(f.outside, 'secret.txt')).existsSync(), isTrue);
    expect(File(share('.hidden')).existsSync(), isTrue);
    expect(Directory(share('sub')).existsSync(), isTrue);
  });

  test('without a token nothing is deleted', () async {
    File(share('keep.txt')).writeAsStringSync('k');
    final req = await client.postUrl(
      Uri(
        scheme: 'https',
        host: '127.0.0.1',
        port: server.port,
        path: Api.delete,
      ),
    );
    final body = utf8.encode(
      jsonEncode({
        'paths': ['keep.txt'],
      }),
    );
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401);
    expect(File(share('keep.txt')).existsSync(), isTrue);
  });
}
