import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'discovery.dart';
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

/// The user cancelled an upload.
class UploadCancelled implements Exception {
  const UploadCancelled();
}

/// Lets the UI stop an upload that is in progress.
class UploadCancel {
  HttpClientRequest? _request;
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    _request?.abort(const UploadCancelled());
  }
}

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

  late final HttpClient _streamHttp = pinnedHttpClient(pairing.fingerprint);

  void close() {
    _http.close(force: true);
    _streamHttp.close(force: true);
  }

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

  Future<String>? _connecting;

  /// Finds a working address of the PC. Several screens may ask at once;
  /// they share one search.
  Future<String> connect() {
    final h = _host;
    if (h != null) return Future.value(h);
    return _connecting ??= _findHost().whenComplete(() => _connecting = null);
  }

  /// Forget the current address (e.g. after the PC got a new one), so the
  /// next request searches again.
  void forgetHost() => _host = null;

  /// 1. the address that worked last time; 2. the network, where the PC
  /// announces itself (finds it after an address change); 3. every other
  /// address it ever had. The network search starts right away, in parallel.
  Future<String> _findHost() async {
    final search = discoverPcAddresses(pairing.pcId)
      ..then((found) => debugPrint('PocketDrive discovery found: $found'));
    final last = pairing.lastHost;
    if (last != null && await _probe(last)) return _use(last);
    for (final h in await search) {
      if (await _probe(h)) {
        if (!pairing.hosts.contains(h)) pairing.hosts.add(h);
        return _use(h);
      }
    }
    for (final h in pairing.hosts) {
      if (h != last && await _probe(h)) return _use(h);
    }
    throw const PcUnreachable();
  }

  String _use(String h) {
    _host = h;
    if (h != pairing.lastHost) onHostChanged?.call(h);
    return h;
  }

  /// Is our PC (right certificate, right id, accepts our token) at [h]?
  Future<bool> _probe(String h) async {
    try {
      final info = PcInfo.fromJson(
        await _send(
          _http,
          'GET',
          _uri(h, Api.info),
          token: pairing.token,
          timeout: const Duration(seconds: 2),
        ),
      );
      return info.pcId == pairing.pcId;
    } on NotPaired {
      rethrow;
    } on Object {
      return false;
    }
  }

  Future<PcInfo> info() async {
    final h = await connect();
    return PcInfo.fromJson(
      await _send(_http, 'GET', _uri(h, Api.info), token: pairing.token),
    );
  }

  Future<Listing> list(String path, {bool showHidden = false}) async {
    Future<Listing> attempt() async {
      final h = await connect();
      return Listing.fromJson(
        await _send(
          _http,
          'GET',
          _uri(h, Api.list, {'path': path, if (showHidden) 'hidden': '1'}),
          token: pairing.token,
        ),
      );
    }

    try {
      return await attempt();
    } on IOException {
      forgetHost(); // the PC may have a new address: look for it again
      return attempt();
    } on TimeoutException {
      forgetHost();
      return attempt();
    }
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

  /// Uploads [file] into [folder] as [name]. Reports progress as bytes sent.
  /// Returns the saved entry (its name may have ` (2)` added).
  Future<RemoteEntry> upload(
    String folder,
    String name,
    File file, {
    DateTime? modified,
    void Function(int sent, int total)? onProgress,
    UploadCancel? cancel,
  }) async {
    final h = await connect();
    final total = await file.length();
    final req = await _streamHttp
        .postUrl(
          _uri(h, Api.upload, {
            'path': folder,
            'name': name,
            if (modified != null)
              'modified': '${modified.millisecondsSinceEpoch}',
          }),
        )
        .timeout(_timeout);
    cancel?._request = req;
    if (cancel?.cancelled ?? false) req.abort(const UploadCancelled());
    req.headers.set(Api.authHeader, Api.bearer(pairing.token));
    req.headers.contentType = ContentType.binary;
    req.contentLength = total;
    var sent = 0;
    try {
      await req.addStream(
        file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent, total);
          return chunk;
        }),
      );
      final res = await req.close();
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
      return RemoteEntry.fromJson(
        (jsonDecode(text) as Map).cast<String, Object?>(),
      );
    } on Object {
      if (cancel?.cancelled ?? false) throw const UploadCancelled();
      rethrow;
    } finally {
      cancel?._request = null;
    }
  }

  /// Moves [paths] into folder [to]. Returns how many moved, and the paths
  /// that failed with their error codes.
  Future<(int, Map<String, String>)> move(List<String> paths, String to) async {
    final h = await connect();
    final res = await _send(
      _http,
      'POST',
      _uri(h, Api.move, {'to': to}),
      token: pairing.token,
      body: {'paths': paths},
    );
    final failed = <String, String>{
      for (final f in res['failed'] as List)
        (f as Map)['path'] as String: f['error'] as String,
    };
    return ((res['moved'] as List).length, failed);
  }

  /// Sends [paths] to the PC's Recycle Bin. Returns how many went, and the
  /// paths that failed with their error codes.
  Future<(int, Map<String, String>)> delete(List<String> paths) async {
    final h = await connect();
    final res = await _send(
      _http,
      'POST',
      _uri(h, Api.delete),
      token: pairing.token,
      body: {'paths': paths},
      timeout: const Duration(seconds: 30),
    );
    final failed = <String, String>{
      for (final f in res['failed'] as List)
        (f as Map)['path'] as String: f['error'] as String,
    };
    return ((res['deleted'] as List).length, failed);
  }

  /// Hides (or shows again) a folder in the app. Nothing changes in Windows.
  Future<void> setHidden(String path, bool hidden) async {
    final h = await connect();
    await _send(
      _http,
      'POST',
      _uri(h, Api.hide, {'path': path, 'hidden': hidden ? '1' : '0'}),
      token: pairing.token,
    );
  }

  /// Creates folder [name] inside [parent] on the PC.
  Future<RemoteEntry> mkdir(String parent, String name) async {
    final h = await connect();
    return RemoteEntry.fromJson(
      await _send(
        _http,
        'POST',
        _uri(h, Api.mkdir, {'path': parent, 'name': name}),
        token: pairing.token,
      ),
    );
  }

  /// Starts downloading a file (or part of it, with a `Range` header) and
  /// returns the response unread, for streaming. Uses its own connection
  /// pool so videos don't wait behind thumbnail requests.
  Future<HttpClientResponse> openFile(
    String path, {
    String? range,
    String method = 'GET',
  }) async {
    final h = await connect();
    final req = await _streamHttp
        .openUrl(method, _uri(h, Api.file, {'path': path}))
        .timeout(_timeout);
    req.headers.set(Api.authHeader, Api.bearer(pairing.token));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close().timeout(_timeout);
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
    Duration timeout = _timeout,
  }) async {
    final req = await http.openUrl(method, uri).timeout(timeout);
    if (token != null) req.headers.set(Api.authHeader, Api.bearer(token));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(timeout);
    final text = await utf8.decodeStream(res).timeout(timeout);
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
