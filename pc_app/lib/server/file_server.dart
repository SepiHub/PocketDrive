import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../identity.dart';
import 'byte_range.dart';
import 'devices.dart';
import 'network.dart';
import 'move.dart';
import 'path_jail.dart';
import 'recycle.dart';
import 'thumbnails.dart';
import 'uploads.dart';

/// Everything the request handlers need.
class ServerContext {
  ServerContext({
    required this.jail,
    required this.devices,
    required this.identity,
    required this.pairingWindow,
    required this.thumbs,
    this.recycler = recycleToBin,
    this.onPaired,
    void Function(String)? log,
  }) : log = log ?? ((_) {});

  final PathJail jail;
  final DeviceStore devices;
  final PcIdentity identity;
  final ThumbnailService thumbs;
  final Recycler recycler;

  /// The currently open pairing window, if any.
  final PairingWindow? Function() pairingWindow;
  final void Function(PairedDevice)? onPaired;
  final void Function(String) log;
}

/// Builds the HTTP handler.
///
/// Order of checks on every request: errors are caught -> the client must be
/// on a local network -> it must carry a valid device token (except for
/// `/api/pair`) -> the route runs, and every file path goes through the jail.
Handler buildHandler(ServerContext c) {
  final router = Router()
    ..post(Api.pair, (Request r) => _pair(c, r))
    ..get(
      Api.info,
      (Request r) => _json(
        200,
        PcInfo(pcId: c.identity.pcId, pcName: c.identity.pcName).toJson(),
      ),
    )
    ..get(Api.list, (Request r) => _list(c.jail, r))
    ..get(Api.file, (Request r) => _file(c.jail, r))
    ..get(Api.thumb, (Request r) => _thumb(c, r))
    ..post(Api.upload, (Request r) => _upload(c, r))
    ..post(Api.delete, (Request r) async {
      final body = await _readSmallBody(r, 1 << 20);
      if (body == null) return _error(400, ApiError.badRequest);
      final List<String> paths;
      try {
        paths = [
          for (final x
              in (jsonDecode(utf8.decode(body)) as Map)['paths'] as List)
            x as String,
        ];
      } on Object {
        return _error(400, ApiError.badRequest);
      }
      final result = await deleteEntries(c.jail, paths, recycler: c.recycler);
      c.log(
        'Moved ${(result['deleted'] as List).length} item(s) to the Recycle Bin',
      );
      return _json(200, result);
    })
    ..post(Api.move, (Request r) async {
      final body = await _readSmallBody(r, 1 << 20);
      if (body == null) return _error(400, ApiError.badRequest);
      final List<String> paths;
      try {
        paths = [
          for (final x
              in (jsonDecode(utf8.decode(body)) as Map)['paths'] as List)
            x as String,
        ];
      } on Object {
        return _error(400, ApiError.badRequest);
      }
      final result = await moveEntries(
        c.jail,
        paths,
        r.url.queryParameters['to'] ?? '',
      );
      c.log('Moved ${(result['moved'] as List).length} item(s)');
      return _json(200, result);
    })
    ..post(Api.mkdir, (Request r) async {
      final name = r.url.queryParameters['name'];
      if (name == null) return _error(400, ApiError.badRequest);
      final entry = await createFolder(c.jail, _pathParam(r), name);
      c.log('Created folder ${entry.name}');
      return _json(200, entry.toJson());
    });
  return const Pipeline()
      .addMiddleware(_errorMiddleware(c.log))
      .addMiddleware(_localNetworkOnly(c.log))
      .addMiddleware(_requireDeviceToken(c.devices))
      .addHandler(router.call);
}

String _pathParam(Request r) => r.url.queryParameters['path'] ?? '';

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Response _error(int status, String code) => _json(status, {'error': code});

const _maxPairBody = 4096;

/// Reads a request body of at most [max] bytes; null if it's bigger.
Future<List<int>?> _readSmallBody(Request r, int max) async {
  if ((r.contentLength ?? 0) > max) return null;
  final bytes = <int>[];
  await for (final chunk in r.read()) {
    bytes.addAll(chunk);
    if (bytes.length > max) return null;
  }
  return bytes;
}

Future<Response> _pair(ServerContext c, Request r) async {
  final window = c.pairingWindow();
  if (window == null || !window.isOpen) {
    return _error(403, ApiError.pairingClosed);
  }
  final body = await _readSmallBody(r, _maxPairBody);
  if (body == null) return _error(400, ApiError.badRequest);
  final PairRequest req;
  try {
    req = PairRequest.fromJson(
      (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>(),
    );
  } on Object {
    return _error(400, ApiError.badRequest);
  }
  if (!window.tryConsume(req.code)) {
    c.log('Wrong pairing code from ${_remote(r)?.remoteAddress.address}');
    return _error(403, ApiError.pairingClosed);
  }
  var name = req.deviceName.replaceAll(RegExp(r'[\x00-\x1F]'), '').trim();
  if (name.length > 64) name = name.substring(0, 64);
  final (device, token) = await c.devices.add(name);
  c.log('Paired ${device.name} (${device.id})');
  c.onPaired?.call(device);
  return _json(
    200,
    PairResponse(
      token: token,
      deviceId: device.id,
      pcId: c.identity.pcId,
      pcName: c.identity.pcName,
    ).toJson(),
  );
}

Future<Response> _list(PathJail jail, Request r) async {
  final rel = _pathParam(r);
  final entries = await jail.list(rel);
  return _json(200, Listing(path: rel, entries: entries).toJson());
}

Future<Response> _file(PathJail jail, Request r) async {
  final real = await jail.resolveExisting(_pathParam(r));
  final file = File(real);
  if (!await file.exists()) return _error(400, ApiError.notAFile);
  final stat = await file.stat();
  final size = stat.size;

  final headers = <String, String>{
    'content-type': lookupMimeType(real) ?? 'application/octet-stream',
    'accept-ranges': 'bytes',
    'last-modified': HttpDate.format(stat.modified),
    'cache-control': 'private, no-cache',
    // If a browser ever opens a shared .html/.svg, it must not run scripts.
    'x-content-type-options': 'nosniff',
    'content-security-policy': 'sandbox',
  };

  final ByteRange? range;
  try {
    range = parseRange(r.headers['range'], size);
  } on RangeNotSatisfiable {
    return Response(416, headers: {'content-range': 'bytes */$size'});
  }

  if (range == null) {
    return Response.ok(
      file.openRead(),
      headers: {...headers, 'content-length': '$size'},
    );
  }
  return Response(
    206,
    body: file.openRead(range.start, range.end + 1),
    headers: {
      ...headers,
      'content-length': '${range.length}',
      'content-range': 'bytes ${range.start}-${range.end}/$size',
    },
  );
}

Future<Response> _upload(ServerContext c, Request r) async {
  final q = r.url.queryParameters;
  final name = q['name'];
  if (name == null) return _error(400, ApiError.badRequest);
  final modifiedMs = int.tryParse(q['modified'] ?? '');
  final entry = await receiveUpload(
    c.jail,
    _pathParam(r),
    name,
    r.read(),
    expectedLength: r.contentLength,
    modified: modifiedMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(modifiedMs),
  );
  c.log('Uploaded ${entry.name} (${entry.size} bytes)');
  return _json(200, entry.toJson());
}

Future<Response> _thumb(ServerContext c, Request r) async {
  final real = await c.jail.resolveExisting(_pathParam(r));
  if (!await FileSystemEntity.isFile(real)) {
    return _error(400, ApiError.notAFile);
  }
  final size = ThumbnailService.snapSize(
    int.tryParse(r.url.queryParameters['size'] ?? ''),
  );
  final thumb = await c.thumbs.thumbnail(real, size);
  if (thumb == null) return _error(404, ApiError.noThumbnail);
  return Response.ok(
    thumb.openRead(),
    headers: {
      'content-type': 'image/jpeg',
      'content-length': '${await thumb.length()}',
      'cache-control': 'private, max-age=604800',
    },
  );
}

HttpConnectionInfo? _remote(Request r) =>
    r.context['shelf.io.connection_info'] as HttpConnectionInfo?;

/// Refuses clients that aren't on this PC or a local network. (When remote
/// access comes, this is the one place to relax.)
Middleware _localNetworkOnly(void Function(String) log) =>
    (inner) => (request) {
      final remote = _remote(request)?.remoteAddress;
      if (remote == null || !isLocalNetworkAddress(remote)) {
        log('Refused non-local client ${remote?.address}');
        return _error(403, ApiError.notLocalNetwork);
      }
      return inner(request);
    };

/// Every request except pairing must carry a paired device's token.
Middleware _requireDeviceToken(DeviceStore devices) =>
    (inner) => (request) {
      if ('/${request.url.path}' == Api.pair) return inner(request);
      final header = request.headers[Api.authHeader] ?? '';
      const prefix = 'Bearer ';
      final device = header.startsWith(prefix)
          ? devices.findByToken(header.substring(prefix.length).trim())
          : null;
      if (device == null) {
        return _json(401, {'error': ApiError.unauthorized});
      }
      devices.touch(device);
      return inner(request.change(context: {'device': device}));
    };

/// Turns our exceptions into short JSON errors. Details go to the log only,
/// so a client never learns anything about the PC's folders.
Middleware _errorMiddleware(void Function(String) log) =>
    (inner) => (request) async {
      try {
        return await inner(request);
      } on PathRejected catch (e) {
        log('Rejected ${request.url}: ${e.reason}');
        return _error(400, ApiError.badPath);
      } on PathNotFound {
        return _error(404, ApiError.notFound);
      } on NotADirectory {
        return _error(400, ApiError.notADirectory);
      } on AlreadyExists {
        return _error(409, ApiError.exists);
      } on UploadIncomplete {
        return _error(400, ApiError.uploadIncomplete);
      } on UploadWriteFailed catch (e) {
        log('Upload write failed: ${e.reason}');
        return _error(507, ApiError.writeFailed);
      } on FileSystemException catch (e) {
        log('File error on ${request.url}: ${e.message}');
        return _error(403, ApiError.unreadable);
      } catch (e, st) {
        log('Error on ${request.url}: $e\n$st');
        return _error(500, ApiError.internal);
      }
    };

/// Runs the HTTPS server for one shared folder.
class PocketServer {
  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  InternetAddress? get address => _server?.address;

  /// Listens on all of this PC's IPv4 addresses by default. Windows Firewall
  /// asks once whether to allow that.
  Future<void> start({
    required String folder,
    required DeviceStore devices,
    required PcIdentity identity,
    required PairingWindow? Function() pairingWindow,
    required ThumbnailService thumbs,
    Recycler recycler = recycleToBin,
    void Function(PairedDevice)? onPaired,
    InternetAddress? address,
    int port = Api.defaultPort,
    void Function(String)? log,
  }) async {
    await stop();
    final jail = await PathJail.open(folder);
    final handler = buildHandler(
      ServerContext(
        jail: jail,
        devices: devices,
        identity: identity,
        pairingWindow: pairingWindow,
        thumbs: thumbs,
        recycler: recycler,
        onPaired: onPaired,
        log: log,
      ),
    );
    final server = await shelf_io.serve(
      handler,
      address ?? InternetAddress.anyIPv4,
      port,
      securityContext: identity.securityContext(),
    );
    server.autoCompress = false;
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
