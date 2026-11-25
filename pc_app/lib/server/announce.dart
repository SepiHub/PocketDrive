import 'dart:convert';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// Announces the PC on the local network (mDNS / DNS-SD) so the phone can
/// find it even when its address changes. The announcement only says "a
/// PocketDrive PC with this id is here, on this port": no secrets, and
/// connecting still needs the pinned certificate and a device token.
class Announcer {
  Registration? _registration;

  Future<void> start({
    required String pcId,
    required String pcName,
    required int port,
    void Function(String)? log,
  }) async {
    await stop();
    try {
      _registration = await register(
        Service(
          name: 'PocketDrive on $pcName',
          type: Api.serviceType,
          port: port,
          txt: {Api.serviceTxtId: Uint8List.fromList(utf8.encode(pcId))},
        ),
      );
      log?.call('Announced on the network as ${Api.serviceType}');
    } on Object catch (e) {
      // Not fatal: the phone falls back to the addresses it already knows.
      log?.call('Could not announce on the network: $e');
    }
  }

  Future<void> stop() async {
    final r = _registration;
    _registration = null;
    if (r != null) {
      try {
        await unregister(r);
      } on Object {
        // already gone
      }
    }
  }
}
