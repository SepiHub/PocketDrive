import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/config.dart';
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_pc/server/thumbnails.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

/// Several shared folders: the phone's top level lists them, and every path
/// starts with a folder's name.
void main() {
  late Fixture f;
  late String token;
  late HttpClient client;
  late String music;
  late String twin; // another folder also called "share"
  final recycled = <String>[];
  final server = PocketServer();

  setUpAll(() async {
    f = await Fixture.create();
    music = p.join(f.base.path, 'Music');
    twin = p.join(f.base.path, 'other', 'share');
    await Directory(music).create();
    await File(p.join(music, 'song.mp3')).writeAsString('la la');
    await Directory(twin).create(recursive: true);
    await File(p.join(twin, 'twin.txt')).writeAsString('twin');
    final identity = await PcIdentity.loadOrCreate(
      Directory(p.join(f.base.path, 'id')),
    );
    final devices = await DeviceStore.load(
      File(p.join(f.base.path, 'dev.json')),
    );
    (_, token) = await devices.add('Test');
    await server.start(
      folders: [f.share, music, twin],
      devices: devices,
      identity: identity,
      pairingWindow: () => null,
      thumbs: ThumbnailService(Directory(p.join(f.base.path, 'thumbs'))),
      recycler: (paths) async {
        recycled.addAll(paths);
        for (final x in paths) {
          await File(x).delete();
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

  Future<(int, String)> call(
    String method,
    String path,
    Map<String, String> query, [
    Object? body,
  ]) async {
    final uri = Uri(
      scheme: 'https',
      host: '127.0.0.1',
      port: server.port,
      path: path,
      queryParameters: query,
    );
    final req = await client.openUrl(method, uri);
    req.headers.set(Api.authHeader, Api.bearer(token));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    return (res.statusCode, await utf8.decodeStream(res));
  }

  Future<Listing> list(String path) async {
    final (status, text) = await call('GET', Api.list, {'path': path});
    expect(status, 200, reason: text);
    return Listing.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
  }

  test('top level lists the shared folders, with unique names', () async {
    final top = await list('');
    expect(top.isShareList, isTrue);
    expect(
      [for (final e in top.entries) e.name],
      ['share', 'Music', 'share (2)'],
    );
    expect(top.entries.every((e) => e.isDir), isTrue);
    expect(top.entries[1].fileCount, 1);
  });

  test('paths go into the right folder', () async {
    final m = await list('Music');
    expect(m.isShareList, isFalse);
    expect(m.path, 'Music');
    expect([for (final e in m.entries) e.name], ['song.mp3']);
    expect(
      [for (final e in (await list('share (2)')).entries) e.name],
      ['twin.txt'],
    );
    expect(
      [for (final e in (await list('SHARE/sub')).entries) e.name],
      ['b.txt'],
    );
    final (status, text) = await call('GET', Api.file, {'path': 'share/a.txt'});
    expect(status, 200);
    expect(text, 'hello world');
  });

  test('unknown folders and the top level itself are refused', () async {
    expect((await call('GET', Api.list, {'path': 'Nope'})).$1, 404);
    expect((await call('GET', Api.file, {'path': ''})).$1, 400);
    expect((await call('POST', Api.mkdir, {'path': '', 'name': 'x'})).$1, 400);
    expect(
      (await call('GET', Api.file, {'path': 'Music/../share/a.txt'})).$1,
      400,
    );
    expect(
      (await call('GET', Api.file, {'path': 'share/escape/secret.txt'})).$1,
      400,
    );
    // A shared folder itself can't be hidden, moved or deleted.
    expect((await call('POST', Api.hide, {'path': 'Music'})).$1, 400);
    final (_, del) = await call('POST', Api.delete, {}, {
      'paths': ['Music'],
    });
    expect((jsonDecode(del) as Map)['deleted'], isEmpty);
    expect(Directory(music).existsSync(), isTrue);
  });

  test('upload, mkdir and delete work inside a folder', () async {
    final (s1, _) = await call('POST', Api.mkdir, {
      'path': 'Music',
      'name': 'Albums',
    });
    expect(s1, 200);
    expect(Directory(p.join(music, 'Albums')).existsSync(), isTrue);

    File(p.join(music, 'old.mp3')).writeAsStringSync('x');
    final (s2, text) = await call('POST', Api.delete, {}, {
      'paths': ['Music/old.mp3', 'Nope/x.txt'],
    });
    expect(s2, 200);
    final json = jsonDecode(text) as Map;
    expect(json['deleted'], ['Music/old.mp3']);
    expect((json['failed'] as List).single['path'], 'Nope/x.txt');
    expect(recycled.single, p.join(music, 'old.mp3'));
  });

  test('moves stay inside one folder', () async {
    File(p.join(music, 'mv.mp3')).writeAsStringSync('m');
    final (_, ok) = await call(
      'POST',
      Api.move,
      {'to': 'Music/Albums'},
      {
        'paths': ['Music/mv.mp3'],
      },
    );
    final okJson = jsonDecode(ok) as Map;
    expect(okJson['failed'], isEmpty);
    expect((okJson['moved'] as List).single['from'], 'Music/mv.mp3');
    expect(File(p.join(music, 'Albums', 'mv.mp3')).existsSync(), isTrue);

    final (_, cross) = await call(
      'POST',
      Api.move,
      {'to': 'share'},
      {
        'paths': ['Music/Albums/mv.mp3'],
      },
    );
    final crossJson = jsonDecode(cross) as Map;
    expect(crossJson['moved'], isEmpty);
    expect((crossJson['failed'] as List).single['error'], 'other_share');
    expect(File(p.join(music, 'Albums', 'mv.mp3')).existsSync(), isTrue);

    // Nothing can be moved to the top level.
    final (status, _) = await call(
      'POST',
      Api.move,
      {'to': ''},
      {
        'paths': ['Music/Albums/mv.mp3'],
      },
    );
    expect(status, 400);
  });

  test('a folder can only be shared once, and not inside another', () {
    final shared = [f.share, music];
    expect(checkShareableFolder(music, shared), contains('already shared'));
    expect(
      checkShareableFolder(p.join(f.share, 'sub'), shared),
      contains('inside one you already share'),
    );
    expect(
      checkShareableFolder(f.base.path, shared),
      contains('contains one you already share'),
    );
    expect(checkShareableFolder(twin, shared), isNull);
  });
}
