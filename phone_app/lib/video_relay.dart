import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// Opens a file on the PC: (path, Range header or null, method) -> response.
typedef FileOpener = Future<HttpClientResponse> Function(
  String path,
  String? range,
  String method,
);

/// A tiny HTTP server on the phone itself (127.0.0.1) that feeds videos to
/// Android's video player.
///
/// Why: the system player can't do our certificate pinning or send the device
/// token, so it can't talk to the PC directly. It talks to this relay
/// instead, and the relay forwards each request (including the `Range`
/// header used for seeking) over the pinned, authenticated HTTPS connection.
///
/// Safety: it only listens on the phone's loopback address, so nothing on
/// the network can reach it. Other apps on the phone could, so every URL
/// contains a random secret that only this app knows; without it the relay
/// answers 404. It only ever serves files (no listing, no uploads).
class VideoRelay {
  VideoRelay(this._open);

  final FileOpener _open;
  final String _secret = _randomSecret();
  HttpServer? _server;
  Future<HttpServer>? _starting;

  static String _randomSecret() {
    final r = Random.secure();
    return base64Url
        .encode([for (var i = 0; i < 24; i++) r.nextInt(256)])
        .replaceAll('=', '');
  }

  /// Address the relay listens on (for tests).
  InternetAddress? get address => _server?.address;

  /// A URL the video player can stream [path] from.
  Future<Uri> urlFor(String path) async {
    final server = await (_starting ??= _start());
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/$_secret/file',
      queryParameters: {'path': path},
    );
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => unawaited(_handle(req)));
    return _server = server;
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final segments = req.uri.pathSegments;
      final ok =
          segments.length == 2 &&
          constantTimeEquals(segments[0], _secret) &&
          segments[1] == 'file' &&
          (req.method == 'GET' || req.method == 'HEAD');
      final path = req.uri.queryParameters['path'];
      if (!ok || path == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final upstream = await _open(
        path,
        req.headers.value(HttpHeaders.rangeHeader),
        req.method,
      );
      res.statusCode = upstream.statusCode;
      for (final h in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final v = upstream.headers.value(h);
        if (v != null) res.headers.set(h, v);
      }
      // We pass the PC's content-length through as-is.
      res.headers.chunkedTransferEncoding = false;
      if (upstream.contentLength >= 0) {
        res.contentLength = upstream.contentLength;
      }
      // When the player seeks it drops this request; pipe() then fails and
      // cancels the PC download too, so we don't keep streaming for nothing.
      await upstream.pipe(res);
    } on Object {
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } on Object {
        // Response already started or the player hung up: nothing to do.
      }
    }
  }
}
