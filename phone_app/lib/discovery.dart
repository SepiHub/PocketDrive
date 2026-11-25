import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nsd/nsd.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// Looks on the Wi-Fi for the PC with id [pcId] (it announces itself via
/// mDNS) and returns its IPv4 addresses, or an empty list after [timeout].
///
/// Finding an address doesn't mean trusting it: the client still checks the
/// pinned certificate and the PC id before using it.
Future<List<String>> discoverPcAddresses(
  String pcId, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  Discovery? discovery;
  final found = <String>{};
  final done = Completer<void>();

  void consider(Service s) {
    final id = s.txt?[Api.serviceTxtId];
    if (id == null || utf8.decode(id, allowMalformed: true) != pcId) return;
    for (final a in s.addresses ?? const <InternetAddress>[]) {
      if (a.type == InternetAddressType.IPv4) found.add(a.address);
    }
    if (found.isNotEmpty && !done.isCompleted) done.complete();
  }

  try {
    discovery = await startDiscovery(
      Api.serviceType,
      ipLookupType: IpLookupType.v4,
    ).timeout(timeout);
    discovery.services.forEach(consider);
    discovery.addServiceListener((service, status) {
      if (status == ServiceStatus.found) consider(service);
    });
    await done.future.timeout(timeout, onTimeout: () {});
  } on Object {
    // Discovery unavailable (e.g. no Wi-Fi): fall back to known addresses.
  } finally {
    if (discovery != null) {
      try {
        await stopDiscovery(discovery);
      } on Object {
        // ignore
      }
    }
  }
  return found.toList();
}
