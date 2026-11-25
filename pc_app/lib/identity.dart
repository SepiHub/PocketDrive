import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// This PC's lasting identity: a random id and a self-signed TLS
/// certificate. Created on first run; the phone pins the certificate's
/// fingerprint at pairing, so it must never change silently.
class PcIdentity {
  PcIdentity._({
    required this.pcId,
    required this.certPem,
    required this.keyPem,
  }) : fingerprint = certFingerprint(derFromPem(certPem));

  final String pcId;
  final String certPem;
  final String keyPem;
  final String fingerprint;

  String get pcName => Platform.localHostname;

  SecurityContext securityContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Loads the identity from [dir], creating it the first time.
  static Future<PcIdentity> loadOrCreate(Directory dir) async {
    final idFile = File(p.join(dir.path, 'pc_id.txt'));
    final certFile = File(p.join(dir.path, 'cert.pem'));
    final keyFile = File(p.join(dir.path, 'key.pem'));
    if (await idFile.exists() &&
        await certFile.exists() &&
        await keyFile.exists()) {
      return PcIdentity._(
        pcId: (await idFile.readAsString()).trim(),
        certPem: await certFile.readAsString(),
        keyPem: await keyFile.readAsString(),
      );
    }
    await dir.create(recursive: true);
    final pcId = randomToken(16);
    // RSA key generation takes a few seconds, keep it off the UI thread.
    final (cert, key) = await Isolate.run(() => _generateCertificate(pcId));
    await keyFile.writeAsString(key, flush: true);
    await certFile.writeAsString(cert, flush: true);
    await idFile.writeAsString(pcId, flush: true);
    return PcIdentity._(pcId: pcId, certPem: cert, keyPem: key);
  }
}

(String, String) _generateCertificate(String pcId) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final priv = pair.privateKey as RSAPrivateKey;
  final pub = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'PocketDrive $pcId', 'O': 'PocketDrive'}, priv, pub);
  // The phone pins this exact certificate, so a long lifetime is fine.
  final serial = BigInt.parse(randomHex(16), radix: 16).toString();
  final cert = X509Utils.generateSelfSignedCertificate(
    priv,
    csr,
    3650,
    serialNumber: serial,
    notBefore: DateTime.now().toUtc().subtract(const Duration(days: 1)),
  );
  return (cert, CryptoUtils.encodeRSAPrivateKeyToPem(priv));
}

final _random = Random.secure();

/// Random [bytes] bytes, base64url without padding.
String randomToken(int bytes) => base64Url
    .encode([for (var i = 0; i < bytes; i++) _random.nextInt(256)])
    .replaceAll('=', '');

String randomHex(int bytes) => [
      for (var i = 0; i < bytes; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0')
    ].join();
