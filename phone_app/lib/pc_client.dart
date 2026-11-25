import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'pairing_store.dart';

/// None of the PC's addresses answered.
class PcUnreachable implements Exception {
  const PcUnreachable();
}

/// The PC no longer accepts our token (removed on the PC).
class NotPaired implements Exception {
  const NotPaired();
}

/// The PC answered with an error.
class PcError implements Exception {
  const PcError(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => 'PC error $status ($code)';
}

const _timeout = Duration(seconds: 5);

/// Talks to the paired PC over HTTPS, trusting only its pinned certificate.
class PcClient {
  PcClient(this.pairing, {this.onHostChanged})
      : _http = pinnedHttpClient(pairing.fingerprint)
          // A grid asks for many thumbnails at once; don't flood the PC.
          ..maxConnectionsPerHost = 6;

  final PcPairing pairing;
  final void Function(String host)? onHostChanged;
  final HttpClient _http;
  String? _host;

  String? get host => _host;

  void close() => _http.close(force: true);

  /// Pairs with the PC from a scanned QR code. Tries each address in turn;
  /// a PC with the wrong certificate is refused before the code is sent.
  static Future<PcPairing> pair(PairingQr qr, String deviceName) async {
    final http = pinnedHttpClient(qr.fingerprint);
    try {
      Object? lastError;
      for (final host in qr.hosts) {
        try {
          final res = await _send(
            http,
            'POST',
            Uri(scheme: 'https', host: host, port: qr.port, path: Api.pair),
            body: PairRequest(code: qr.code, deviceName: deviceName).toJson(),
          );
          final r = PairResponse.fromJson(res);
          if (r.pcId != qr.pcId) throw const PcError(0, 'wrong_pc');
          return PcPairing(
            pcId: r.pcId,
            pcName: r.pcName,
            hosts: qr.hosts,
            port: qr.port,
            fingerprint: qr.fingerprint,
            token: r.token,
            lastHost: host,
          );
        } on PcError {
          rethrow; // the PC answered; trying other addresses won't help
        } on Object catch (e) {
          lastError = e;
        }
      }
      throw lastError is PcError ? lastError : const PcUnreachable();
    } finally {
      http.close(force: true);
    }
  }

  /// Finds a working address of the PC (last one first).
  Future<String> connect() async {
    if (_host != null) return _host!;
    final candidates = {
      if (pairing.lastHost != null) pairing.lastHost!,
      ...pairing.hosts,
    };
    for (final h in candidates) {
      try {
        final info = PcInfo.fromJson(await _send(_http, 'GET', _uri(h, Api.info),
            token: pairing.token));
        if (info.pcId != pairing.pcId) continue;
        _host = h;
        if (h != pairing.lastHost) onHostChanged?.call(h);
        return h;
      } on NotPaired {
        rethrow;
      } on Object {
        continue;
      }
    }
    throw const PcUnreachable();
  }

  Future<PcInfo> info() async {
    final h = await connect();
    return PcInfo.fromJson(
        await _send(_http, 'GET', _uri(h, Api.info), token: pairing.token));
  }

  Future<Listing> list(String path) async {
    final h = await connect();
    return Listing.fromJson(await _send(
        _http, 'GET', _uri(h, Api.list, {'path': path}),
        token: pairing.token));
  }

  /// JPEG thumbnail bytes, or null if the PC has no preview for this file.
  Future<Uint8List?> thumbnail(String path, int size) async {
    final h = await connect();
    final req = await _http
        .getUrl(_uri(h, Api.thumb, {'path': path, 'size': '$size'}))
        .timeout(_timeout);
    req.headers.set(Api.authHeader, Api.bearer(pairing.token));
    final res = await req.close().timeout(_timeout);
    // Big previews of large photos can take a while to render on the PC.
    final bytes = await res
        .fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode == 401) throw const NotPaired();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw PcError(res.statusCode, 'thumb');
    return bytes.takeBytes();
  }

  Uri _uri(String host, String path, [Map<String, String>? query]) => Uri(
        scheme: 'https',
        host: host,
        port: pairing.port,
        path: path,
        queryParameters: query,
      );

  static Future<Map<String, Object?>> _send(
    HttpClient http,
    String method,
    Uri uri, {
    String? token,
    Object? body,
  }) async {
    final req = await http.openUrl(method, uri).timeout(_timeout);
    if (token != null) req.headers.set(Api.authHeader, Api.bearer(token));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(_timeout);
    final text = await utf8.decodeStream(res).timeout(_timeout);
    if (res.statusCode == 401) throw const NotPaired();
    if (res.statusCode != 200) {
      var code = 'http_${res.statusCode}';
      try {
        code = (jsonDecode(text) as Map)['error'] as String;
      } on Object {
        // not JSON
      }
      throw PcError(res.statusCode, code);
    }
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }
}
