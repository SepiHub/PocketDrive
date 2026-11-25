import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_phone/video_relay.dart';

/// The relay is tested against a fake "PC" that serves one 1 MB file with
/// byte ranges, like the real server does.
void main() {
  late HttpServer fakePc;
  late VideoRelay relay;
  final upstreamClient = HttpClient();
  final client = HttpClient();
  final data = List<int>.generate(1 << 20, (i) => i % 251);
  final requestedPaths = <String>[];

  setUpAll(() async {
    fakePc = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakePc.listen((req) async {
      requestedPaths.add(req.uri.queryParameters['path'] ?? '');
      final res = req.response
        ..headers.contentType = ContentType('video', 'mp4')
        ..headers.set('accept-ranges', 'bytes');
      final m = RegExp(r'bytes=(\d+)-(\d*)')
          .firstMatch(req.headers.value('range') ?? '');
      if (m == null) {
        res.contentLength = data.length;
        res.add(data);
      } else {
        final start = int.parse(m.group(1)!);
        final end = m.group(2)!.isEmpty
            ? data.length - 1
            : int.parse(m.group(2)!);
        res
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $start-$end/${data.length}')
          ..contentLength = end - start + 1
          ..add(data.sublist(start, end + 1));
      }
      await res.close();
    });
    relay = VideoRelay((path, range, method) async {
      final req = await upstreamClient.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${fakePc.port}/api/file?path=$path'),
      );
      if (range != null) req.headers.set('range', range);
      return req.close();
    });
  });

  tearDownAll(() async {
    await relay.close();
    await fakePc.close(force: true);
    upstreamClient.close(force: true);
    client.close(force: true);
  });

  Future<(int, Map<String, String>, List<int>)> get(
    Uri url, {
    String? range,
  }) async {
    final req = await client.getUrl(url);
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (res.statusCode, h, body);
  }

  test('only listens on the phone itself', () async {
    final url = await relay.urlFor('v.mp4');
    expect(url.host, '127.0.0.1');
    expect(relay.address!.isLoopback, isTrue);
  });

  test('streams the whole file', () async {
    final (status, headers, body) = await get(await relay.urlFor('v.mp4'));
    expect(status, 200);
    expect(body, data);
    expect(headers['content-type'], 'video/mp4');
    expect(headers['accept-ranges'], 'bytes');
  });

  test('passes seeks (ranges) through', () async {
    final (status, headers, body) = await get(
      await relay.urlFor('folder/v.mp4'),
      range: 'bytes=500000-500099',
    );
    expect(status, 206);
    expect(body, data.sublist(500000, 500100));
    expect(headers['content-range'], 'bytes 500000-500099/${data.length}');
    expect(requestedPaths.last, 'folder/v.mp4');
  });

  test('requests without the secret get nothing', () async {
    final good = await relay.urlFor('v.mp4');
    final before = requestedPaths.length;
    for (final path in [
      '/file',
      '/wrongsecret/file',
      '/${good.pathSegments[0]}x/file',
      '/${good.pathSegments[0]}/list',
      '/${good.pathSegments[0]}/file/extra',
    ]) {
      final url = good.replace(path: path);
      final (status, _, body) = await get(url);
      expect(status, 404, reason: path);
      expect(body, isEmpty);
    }
    expect(requestedPaths.length, before, reason: 'nothing reached the PC');
  });

  test('a player that hangs up mid-stream does not break the relay', () async {
    final url = await relay.urlFor('v.mp4');
    final req = await client.getUrl(url);
    final res = await req.close();
    await res.first; // read one chunk, then drop the connection
    final again = await get(url, range: 'bytes=0-9');
    expect(again.$1, 206);
    expect(utf8.decode(again.$3, allowMalformed: true).length, 10);
  });
}
