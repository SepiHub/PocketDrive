import 'dart:convert';

/// What the PC's pairing QR code contains.
///
/// Holds everything the phone needs to find the PC and to trust it: the PC's
/// addresses, a one-time pairing code and the fingerprint of the PC's TLS
/// certificate (so the phone can detect an impostor).
class PairingQr {
  const PairingQr({
    required this.pcId,
    required this.pcName,
    required this.hosts,
    required this.port,
    required this.code,
    required this.fingerprint,
  });

  static const int version = 1;

  final String pcId;
  final String pcName;

  /// IPv4 addresses of the PC on its local networks, best guess first.
  final List<String> hosts;
  final int port;

  /// One-time pairing code (expires after a few minutes).
  final String code;

  /// [certFingerprint] of the PC's certificate.
  final String fingerprint;

  String encode() => jsonEncode({
    'pd': version,
    'id': pcId,
    'name': pcName,
    'hosts': hosts,
    'port': port,
    'code': code,
    'fp': fingerprint,
  });

  /// Returns null if [text] isn't a PocketDrive pairing code.
  static PairingQr? tryDecode(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['pd'] != version) return null;
      final hosts = j['hosts'];
      if (hosts is! List || hosts.isEmpty) return null;
      final port = j['port'];
      if (port is! int || port <= 0 || port > 65535) return null;
      return PairingQr(
        pcId: j['id'] as String,
        pcName: j['name'] as String,
        hosts: [for (final h in hosts) h as String],
        port: port,
        code: j['code'] as String,
        fingerprint: j['fp'] as String,
      );
    } on Object {
      return null;
    }
  }
}

/// Body of `POST /api/pair`.
class PairRequest {
  const PairRequest({required this.code, required this.deviceName});
  final String code;
  final String deviceName;

  Map<String, Object?> toJson() => {'code': code, 'deviceName': deviceName};

  factory PairRequest.fromJson(Map<String, Object?> j) => PairRequest(
    code: j['code'] as String,
    deviceName: j['deviceName'] as String,
  );
}

/// Response of `POST /api/pair`.
class PairResponse {
  const PairResponse({
    required this.token,
    required this.deviceId,
    required this.pcId,
    required this.pcName,
  });

  /// Secret device token; send as `Authorization: Bearer <token>`.
  final String token;
  final String deviceId;
  final String pcId;
  final String pcName;

  Map<String, Object?> toJson() => {
    'token': token,
    'deviceId': deviceId,
    'pcId': pcId,
    'pcName': pcName,
  };

  factory PairResponse.fromJson(Map<String, Object?> j) => PairResponse(
    token: j['token'] as String,
    deviceId: j['deviceId'] as String,
    pcId: j['pcId'] as String,
    pcName: j['pcName'] as String,
  );
}

/// Response of `GET /api/info`.
class PcInfo {
  const PcInfo({required this.pcId, required this.pcName});
  final String pcId;
  final String pcName;

  Map<String, Object?> toJson() => {'pcId': pcId, 'pcName': pcName};

  factory PcInfo.fromJson(Map<String, Object?> j) =>
      PcInfo(pcId: j['pcId'] as String, pcName: j['pcName'] as String);
}
