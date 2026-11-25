import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

/// Tests over real HTTP on the loopback address, so URL decoding, headers
/// and streaming are exercised exactly as the phone will see them.
void main() {
  late Fixture f;
  final server = PocketServer();
  final client = HttpClient();

  setUpAll(() async {
    f = await Fixture.create();
    await server.start(folder: f.share, port: 0);
  });
  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    await f.delete();
  });

  Future<({int status, Map<String, String> headers, String body})> get(
    String pathAndQuery, {
    Map<String, String> headers = const {},
  }) async {
    // Uri.parse keeps our percent-encoding exactly as written.
    final uri = Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery');
    final req = await client.getUrl(uri);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (status: res.statusCode, headers: h, body: body);
  }

  test('listens on loopback only', () {
    expect(server.address!.isLoopback, isTrue);
  });

  test('lists the shared folder', () async {
    final r = await get('${Api.list}?path=');
    expect(r.status, 200);
    final listing = Listing.fromJson(jsonDecode(r.body) as Map<String, Object?>);
    expect(listing.entries.map((e) => e.name), contains('a.txt'));
    expect(listing.entries.map((e) => e.name), isNot(contains('escape')));
  });

  test('downloads a file', () async {
    final r = await get('${Api.file}?path=a.txt');
    expect(r.status, 200);
    expect(r.body, 'hello world');
    expect(r.headers['accept-ranges'], 'bytes');
    expect(r.headers['content-length'], '11');
    expect(r.headers['content-type'], startsWith('text/plain'));
  });

  test('serves byte ranges', () async {
    var r = await get('${Api.file}?path=a.txt', headers: {'range': 'bytes=0-4'});
    expect(r.status, 206);
    expect(r.body, 'hello');
    expect(r.headers['content-range'], 'bytes 0-4/11');

    r = await get('${Api.file}?path=a.txt', headers: {'range': 'bytes=6-'});
    expect(r.body, 'world');

    r = await get('${Api.file}?path=a.txt', headers: {'range': 'bytes=50-'});
    expect(r.status, 416);
    expect(r.headers['content-range'], 'bytes */11');
  });

  group('traversal attempts over HTTP get 400 and no file content', () {
    for (final q in [
      '..%2Foutside%2Fsecret.txt',
      '..%5Coutside%5Csecret.txt',
      '%2E%2E/outside/secret.txt',
      'escape%2Fsecret.txt',
      'C%3A%2FWindows%2Fwin.ini',
      '%5C%5Clocalhost%5Cc%24%5CWindows%5Cwin.ini',
      'a.txt%3A%3A%24DATA',
      'sub%2F..%2F..%2Foutside%2Fsecret.txt',
    ]) {
      test(q, () async {
        for (final endpoint in [Api.file, Api.list]) {
          final r = await get('$endpoint?path=$q');
          expect(r.status, 400, reason: '$endpoint $q');
          expect(r.body, isNot(contains('SECRET')));
          expect(jsonDecode(r.body), {'error': ApiError.badPath});
        }
      });
    }
  });

  test('traversal in the URL path itself is not routed', () async {
    final r = await get('/api/../outside/secret.txt');
    expect(r.body, isNot(contains('SECRET')));
    expect(r.status, 404);
  });

  test('missing file and wrong types', () async {
    expect((await get('${Api.file}?path=nope.txt')).status, 404);
    expect((await get('${Api.file}?path=sub')).status, 400);
    expect((await get('${Api.list}?path=a.txt')).status, 400);
    expect((await get('/api/unknown')).status, 404);
  });
}
