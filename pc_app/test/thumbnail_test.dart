import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/identity.dart';
import 'package:pocketdrive_pc/server/devices.dart';
import 'package:pocketdrive_pc/server/file_server.dart';
import 'package:pocketdrive_pc/server/thumbnails.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late ThumbnailService thumbs;

  setUpAll(() async {
    f = await Fixture.create();
    thumbs = ThumbnailService(Directory(p.join(f.base.path, 'thumbs')));
  });
  tearDownAll(() => f.delete());

  test('sizes snap up to the next rendered size', () {
    expect(ThumbnailService.snapSize(null), 256);
    expect(ThumbnailService.snapSize(1), 128);
    expect(ThumbnailService.snapSize(300), 512);
    expect(ThumbnailService.snapSize(99999), 2048);
  });

  test('a photo gets a JPEG that fits the requested size', () async {
    final file = await thumbs.thumbnail(p.join(f.share, 'photo.jpg'), 256);
    expect(file, isNotNull);
    final t = img.decodeJpg(await file!.readAsBytes())!;
    expect(t.width, lessThanOrEqualTo(256));
    expect(t.height, lessThanOrEqualTo(256));
    expect(t.width, greaterThan(t.height)); // landscape kept
  });

  test('the second request is served from the disk cache', () async {
    final path = p.join(f.share, 'photo.jpg');
    final first = await thumbs.thumbnail(path, 512);
    final again = await thumbs.thumbnail(path, 512);
    expect(again!.path, first!.path);
  });

  test('the shell engine works directly (Windows thumbnail provider)', () {
    final jpeg = makeThumbnailJpeg(p.join(f.share, 'photo.jpg'), 128);
    expect(jpeg, isNotNull);
  });

  test('a text file has no thumbnail', () async {
    expect(await thumbs.thumbnail(p.join(f.share, 'a.txt'), 256), isNull);
  });

  group('over HTTPS', () {
    final server = PocketServer();
    late HttpClient client;
    late String token;

    setUpAll(() async {
      final identity =
          await PcIdentity.loadOrCreate(Directory(p.join(f.base.path, 'id')));
      final devices =
          await DeviceStore.load(File(p.join(f.base.path, 'dev.json')));
      (_, token) = await devices.add('Test');
      await server.start(
        folder: f.share,
        devices: devices,
        identity: identity,
        pairingWindow: () => null,
        thumbs: thumbs,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      client = pinnedHttpClient(identity.fingerprint);
    });
    tearDownAll(() async {
      client.close(force: true);
      await server.stop();
    });

    Future<(int, List<int>, String?)> get(String q, {bool auth = true}) async {
      final req = await client
          .getUrl(Uri.parse('https://127.0.0.1:${server.port}$q'));
      if (auth) req.headers.set(Api.authHeader, Api.bearer(token));
      final res = await req.close();
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, bytes, res.headers.contentType?.mimeType);
    }

    test('returns a JPEG', () async {
      final (status, bytes, type) =
          await get('${Api.thumb}?path=photo.jpg&size=256');
      expect(status, 200);
      expect(type, 'image/jpeg');
      expect(img.decodeJpg(Uint8List.fromList(bytes)), isNotNull);
    });

    test('no thumbnail, folders, traversal and no token', () async {
      var r = await get('${Api.thumb}?path=a.txt');
      expect(r.$1, 404);
      expect(jsonDecode(utf8.decode(r.$2)), {'error': ApiError.noThumbnail});
      expect((await get('${Api.thumb}?path=sub')).$1, 400);
      expect((await get('${Api.thumb}?path=escape%2Fsecret.txt')).$1, 400);
      expect((await get('${Api.thumb}?path=..%2Foutside%2Fsecret.txt')).$1,
          400);
      expect((await get('${Api.thumb}?path=photo.jpg', auth: false)).$1, 401);
    });
  });
}
