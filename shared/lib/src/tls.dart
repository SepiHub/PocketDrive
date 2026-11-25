import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 of a certificate's DER bytes, base64url without padding.
String certFingerprint(List<int> der) =>
    base64Url.encode(sha256.convert(der).bytes).replaceAll('=', '');

/// DER bytes of the first certificate in a PEM string.
List<int> derFromPem(String pem) {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) throw const FormatException('No certificate in PEM');
  return base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
}

/// An HTTP client that only talks to the server whose certificate has
/// [fingerprint] (certificate pinning).
///
/// No certificate authorities are trusted at all, so every certificate goes
/// through the pin check — even one a public CA signed.
HttpClient pinnedHttpClient(String fingerprint) {
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 30);
  client.badCertificateCallback = (cert, host, port) =>
      constantTimeEquals(certFingerprint(cert.der), fingerprint);
  return client;
}

/// Compares two strings without leaking where they differ through timing.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}
