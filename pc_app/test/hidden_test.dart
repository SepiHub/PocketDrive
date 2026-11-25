import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_pc/server/hidden_folders.dart';
import 'package:pocketdrive_pc/server/thumbnails.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late String token;
  late HttpClient client;
  late HiddenFolders hidden;
  late File hiddenFile;
  final server = PocketServer();

  setUpAll(() async {
    f = await Fixture.create();
    Directory(p.join(f.share, 'Private', 'Deeper')).createSync(recursive: true);
    Directory(p.join(f.share, 'Target')).createSync();
    final identity = await PcIdentity.loadOrCreate(
      Directory(p.join(f.base.path, 'id')),
    );
    final devices = await DeviceStore.load(
      File(p.join(f.base.path, 'dev.json')),
    );
    (_, token) = await devices.add('Test');
    hiddenFile = File(p.join(f.base.path, 'hidden.json'));
    hidden = await HiddenFolders.load(hiddenFile);
    await server.start(
      folder: f.share,
      devices: devices,
      identity: identity,
      pairingWindow: () => null,
      thumbs: ThumbnailService(Directory(p.join(f.base.path, 'thumbs'))),
      hidden: hidden,
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

  Future<(int, String)> call(
    String method,
    String path,
    Map<String, String> query, {
    Object? body,
    bool auth = true,
  }) async {
    final req = await client.openUrl(
      method,
      Uri(
        scheme: 'https',
        host: '127.0.0.1',
        port: server.port,
        path: path,
        queryParameters: query,
      ),
    );
    if (auth) req.headers.set(Api.authHeader, Api.bearer(token));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    return (res.statusCode, await utf8.decodeStream(res));
  }

  Future<List<RemoteEntry>> list(String path, {bool showHidden = false}) async {
    final (status, body) = await call('GET', Api.list, {
      'path': path,
      if (showHidden) 'hidden': '1',
    });
    expect(status, 200);
    return Listing.fromJson(jsonDecode(body) as Map<String, Object?>).entries;
  }

  Future<int> hide(String path, {bool on = true, bool auth = true}) async =>
      (await call('POST', Api.hide, {
        'path': path,
        'hidden': on ? '1' : '0',
      }, auth: auth)).$1;

  test('a hidden folder is left out unless asked for', () async {
    expect(await hide('Private'), 200);
    expect((await list('')).map((e) => e.name), isNot(contains('Private')));
    final all = await list('', showHidden: true);
    expect(all.firstWhere((e) => e.name == 'Private').hidden, isTrue);
    expect(all.firstWhere((e) => e.name == 'sub').hidden, isFalse);
    // Still reachable directly (it's tidy, not locked).
    expect((await list('Private')).map((e) => e.name), contains('Deeper'));
    // Nothing changed in Windows.
    expect(Directory(p.join(f.share, 'Private')).existsSync(), isTrue);
  });

  test('hiding is case-insensitive and saved on the PC', () async {
    expect((await list('')).map((e) => e.name), isNot(contains('Private')));
    // Reloaded from disk, and matched without case like Windows does.
    final reloaded = await HiddenFolders.load(hiddenFile);
    final real = await Directory(f.share).resolveSymbolicLinks();
    expect(reloaded.isHidden(real, 'PRIVATE'), isTrue);
    expect(reloaded.isHidden(real, 'sub'), isFalse);
  });

  test('unhide brings it back', () async {
    expect(await hide('Private', on: false), 200);
    expect((await list('')).map((e) => e.name), contains('Private'));
  });

  test('a moved hidden folder stays hidden', () async {
    expect(await hide('Private/Deeper'), 200);
    final (status, _) = await call(
      'POST',
      Api.move,
      {'to': 'Target'},
      body: {
        'paths': ['Private/Deeper'],
      },
    );
    expect(status, 200);
    expect(
      (await list('Target')).map((e) => e.name),
      isNot(contains('Deeper')),
    );
    expect((await list('Target', showHidden: true)).single.hidden, isTrue);
  });

  test('only real folders inside the share can be hidden', () async {
    for (final path in ['', '..', 'a.txt', 'escape', 'nope', '../outside']) {
      expect(await hide(path), anyOf(400, 404), reason: path);
    }
    expect(await hide('sub', auth: false), 401);
    expect((await list('')).map((e) => e.name), contains('sub'));
  });
}
