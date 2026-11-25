import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What the phone remembers about its PC. Kept in Android's encrypted
/// storage (backed by the Android Keystore), since it includes the token.
class PcPairing {
  PcPairing({
    required this.pcId,
    required this.pcName,
    required this.hosts,
    required this.port,
    required this.fingerprint,
    required this.token,
    this.lastHost,
  });

  final String pcId;
  final String pcName;
  final List<String> hosts;
  final int port;

  /// Pinned certificate fingerprint of the PC.
  final String fingerprint;
  final String token;

  /// The address that worked last time; tried first.
  String? lastHost;

  Map<String, Object?> toJson() => {
        'pcId': pcId,
        'pcName': pcName,
        'hosts': hosts,
        'port': port,
        'fingerprint': fingerprint,
        'token': token,
        'lastHost': lastHost,
      };

  factory PcPairing.fromJson(Map<String, Object?> j) => PcPairing(
        pcId: j['pcId'] as String,
        pcName: j['pcName'] as String,
        hosts: [for (final h in j['hosts'] as List) h as String],
        port: j['port'] as int,
        fingerprint: j['fingerprint'] as String,
        token: j['token'] as String,
        lastHost: j['lastHost'] as String?,
      );
}

class PairingStore {
  static const _key = 'pc_pairing';
  final _storage = const FlutterSecureStorage();

  Future<PcPairing?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return PcPairing.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  Future<void> save(PcPairing pairing) =>
      _storage.write(key: _key, value: jsonEncode(pairing.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
