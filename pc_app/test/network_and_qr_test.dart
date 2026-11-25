import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_pc/server/network.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

void main() {
  test('local network addresses', () {
    for (final a in [
      '127.0.0.1',
      '10.0.0.229',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.20',
      '169.254.3.4',
      '::1',
      'fe80::1',
      'fd12::1',
      '::ffff:192.168.1.5',
    ]) {
      expect(isLocalNetworkAddress(InternetAddress(a)), isTrue, reason: a);
    }
  });

  test('internet addresses are not local', () {
    for (final a in [
      '8.8.8.8',
      '172.15.0.1',
      '172.32.0.1',
      '192.169.0.1',
      '11.0.0.1',
      '100.64.0.1',
      '2001:4860::8888',
      '::ffff:8.8.8.8',
    ]) {
      expect(isLocalNetworkAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });

  test('pairing QR round trip', () {
    const qr = PairingQr(
      pcId: 'pc1',
      pcName: 'DESKTOP',
      hosts: ['10.0.0.167'],
      port: 8787,
      code: 'c0de',
      fingerprint: 'fp',
    );
    final back = PairingQr.tryDecode(qr.encode())!;
    expect(back.pcId, 'pc1');
    expect(back.hosts, ['10.0.0.167']);
    expect(back.port, 8787);
    expect(back.code, 'c0de');
    expect(back.fingerprint, 'fp');
  });

  test('other QR codes are ignored', () {
    for (final t in [
      'https://example.com',
      '{}',
      '{"pd":2}',
      '{"pd":1,"hosts":[],"port":1}',
      '{"pd":1,"id":"a","name":"b","hosts":["x"],"port":99999,"code":"c","fp":"d"}',
    ]) {
      expect(PairingQr.tryDecode(t), isNull, reason: t);
    }
  });
}
