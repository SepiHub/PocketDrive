import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'byte_range.dart';
import 'path_jail.dart';

/// Builds the HTTP handler for one shared folder.
Handler buildHandler(PathJail jail, {void Function(String)? log}) {
  final router = Router()
    ..get(Api.list, (Request r) => _list(jail, r))
    ..get(Api.file, (Request r) => _file(jail, r));
  return const Pipeline()
      .addMiddleware(_errorMiddleware(log ?? (_) {}))
      .addHandler(router.call);
}

String _pathParam(Request r) => r.url.queryParameters['path'] ?? '';

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Response _error(int status, String code) => _json(status, {'error': code});

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
          } on FileSystemException catch (e) {
            log('File error on ${request.url}: ${e.message}');
            return _error(403, ApiError.unreadable);
          } catch (e, st) {
            log('Error on ${request.url}: $e\n$st');
            return _error(500, ApiError.internal);
          }
        };

/// Runs the HTTP server for one shared folder.
class PocketServer {
  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  InternetAddress? get address => _server?.address;

  /// Until pairing exists (stage 2) the server only listens on this PC
  /// (loopback), so nothing on the network can reach it.
  Future<void> start({
    required String folder,
    InternetAddress? address,
    int port = Api.defaultPort,
    void Function(String)? log,
  }) async {
    await stop();
    final jail = await PathJail.open(folder);
    final server = await shelf_io.serve(
      buildHandler(jail, log: log),
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    server.autoCompress = false;
    _server = server;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
