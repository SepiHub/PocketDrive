import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

typedef Res = ({int status, Map<String, String> headers, String body});

/// Tests over real HTTPS on the loopback address, with the same pinned
/// client the phone uses.
void main() {
  late Fixture f;
  late PcIdentity identity;
  late DeviceStore devices;
  late String token;
  late HttpClient client;
  PairingWindow? window;
  final server = PocketServer();
  final paired = <PairedDevice>[];

  setUpAll(() async {
    f = await Fixture.create();
    identity =
        await PcIdentity.loadOrCreate(Directory(p.join(f.base.path, 'id')));
    devices = await DeviceStore.load(File(p.join(f.base.path, 'dev.json')));
    (_, token) = await devices.add('Test phone');
    await server.start(
      folder: f.share,
      devices: devices,
      identity: identity,
      pairingWindow: () => window,
      onPaired: paired.add,
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

  Uri url(String pathAndQuery) =>
      Uri.parse('https://127.0.0.1:${server.port}$pathAndQuery');

  Future<Res> send(
    String method,
    String pathAndQuery, {
    String? auth,
    bool noAuth = false,
    Map<String, String> headers = const {},
    String? body,
    HttpClient? using,
  }) async {
    final req = await (using ?? client).openUrl(method, url(pathAndQuery));
    if (!noAuth) req.headers.set(Api.authHeader, auth ?? Api.bearer(token));
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(body);
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (status: res.statusCode, headers: h, body: text);
  }

  Future<Res> get(String q, {Map<String, String> headers = const {}}) =>
      send('GET', q, headers: headers);

  Future<Res> pair(String code) => send('POST', Api.pair,
      noAuth: true,
      body: jsonEncode(PairRequest(code: code, deviceName: 'New phone')));

  group('files', () {
    test('lists the shared folder', () async {
      final r = await get('${Api.list}?path=');
      expect(r.status, 200);
      final listing =
          Listing.fromJson(jsonDecode(r.body) as Map<String, Object?>);
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
      var r = await get('${Api.file}?path=a.txt',
          headers: {'range': 'bytes=0-4'});
      expect(r.status, 206);
      expect(r.body, 'hello');
      expect(r.headers['content-range'], 'bytes 0-4/11');

      r = await get('${Api.file}?path=a.txt', headers: {'range': 'bytes=6-'});
      expect(r.body, 'world');

      r = await get('${Api.file}?path=a.txt', headers: {'range': 'bytes=50-'});
      expect(r.status, 416);
      expect(r.headers['content-range'], 'bytes */11');
    });

    group('traversal attempts get 400 and no file content', () {
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

    test('missing file and wrong types', () async {
      expect((await get('${Api.file}?path=nope.txt')).status, 404);
      expect((await get('${Api.file}?path=sub')).status, 400);
      expect((await get('${Api.list}?path=a.txt')).status, 400);
      expect((await get('/api/unknown')).status, 404);
    });
  });

  group('device token', () {
    test('info works with a valid token', () async {
      final r = await get(Api.info);
      expect(r.status, 200);
      expect(PcInfo.fromJson(jsonDecode(r.body) as Map<String, Object?>).pcId,
          identity.pcId);
    });

    test('missing, wrong or malformed tokens are refused everywhere',
        () async {
      for (final path in [Api.info, '${Api.list}?path=', '${Api.file}?path=a.txt', '/api/unknown']) {
        for (final auth in <String?>[
          null,
          Api.bearer('wrong'),
          Api.bearer(''),
          token, // without "Bearer "
          'Basic ${base64.encode(utf8.encode('a:b'))}',
          'Bearer ${token}x',
        ]) {
          final r = await send('GET', path, auth: auth, noAuth: auth == null);
          expect(r.status, 401, reason: '$path with $auth');
          expect(r.body, isNot(contains('hello')));
        }
      }
    });

    test('a revoked device is refused', () async {
      final (device, t2) = await devices.add('Old phone');
      expect((await send('GET', Api.info, auth: Api.bearer(t2))).status, 200);
      await devices.revoke(device.id);
      expect((await send('GET', Api.info, auth: Api.bearer(t2))).status, 401);
    });

    test('the PC stores only token hashes', () async {
      final saved =
          await File(p.join(f.base.path, 'dev.json')).readAsString();
      expect(saved, isNot(contains(token)));
      expect(saved, contains(hashToken(token)));
    });
  });

  group('pairing', () {
    tearDown(() => window = null);

    test('refused when no pairing window is open', () async {
      window = null;
      expect((await pair('anything')).status, 403);
    });

    test('correct code pairs once and the new token works', () async {
      window = PairingWindow();
      expect((await pair('wrong')).status, 403);
      final r = await pair(window!.code);
      expect(r.status, 200);
      final res = PairResponse.fromJson(jsonDecode(r.body) as Map<String, Object?>);
      expect(res.pcId, identity.pcId);
      expect(paired.last.name, 'New phone');
      expect(
          (await send('GET', Api.info, auth: Api.bearer(res.token))).status,
          200);
      // Single use.
      expect((await pair(window!.code)).status, 403);
    });

    test('too many wrong codes close the window', () async {
      window = PairingWindow();
      for (var i = 0; i < PairingWindow.maxFailedAttempts; i++) {
        expect((await pair('guess$i')).status, 403);
      }
      expect((await pair(window!.code)).status, 403);
    });

    test('expired code is refused', () async {
      window = PairingWindow(lifetime: Duration.zero);
      expect((await pair(window!.code)).status, 403);
    });

    test('bad request bodies', () async {
      window = PairingWindow();
      expect(
          (await send('POST', Api.pair, noAuth: true, body: 'not json'))
              .status,
          400);
      // Oversized: the server answers 400 before reading it all, which may
      // also show up as a dropped connection. Either way, nothing is paired.
      final big = HttpClient(
          context: SecurityContext(withTrustedRoots: false))
        ..badCertificateCallback = (c, h, p) => true;
      addTearDown(() => big.close(force: true));
      try {
        final r = await send('POST', Api.pair,
            noAuth: true, body: 'x' * 500000, using: big);
        expect(r.status, 400);
      } on IOException {
        // connection closed early: fine
      }
      expect(window!.isOpen, isTrue); // bad bodies don't burn the code
    });
  });

  group('TLS', () {
    test('a client pinned to another fingerprint cannot connect', () async {
      final other = pinnedHttpClient('A' * 43);
      addTearDown(() => other.close(force: true));
      await expectLater(send('GET', Api.info, using: other),
          throwsA(isA<HandshakeException>()));
    });

    test('a normal client does not trust the self-signed certificate',
        () async {
      final normal = HttpClient();
      addTearDown(() => normal.close(force: true));
      await expectLater(send('GET', Api.info, using: normal),
          throwsA(isA<HandshakeException>()));
    });

    test('plain HTTP is not served', () async {
      final plain = HttpClient();
      addTearDown(() => plain.close(force: true));
      final req =
          await plain.getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/info'));
      await expectLater(
          req.close().then((r) => r.drain<void>()), throwsA(anything));
    });

    test('identity is stable across restarts', () async {
      final again =
          await PcIdentity.loadOrCreate(Directory(p.join(f.base.path, 'id')));
      expect(again.fingerprint, identity.fingerprint);
      expect(again.pcId, identity.pcId);
    });
  });
}
