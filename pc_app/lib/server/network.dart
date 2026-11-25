import 'dart:io';

/// True for addresses on this PC or a home/local network: loopback,
/// link-local, the private IPv4 ranges and IPv6 unique-local addresses.
bool isLocalNetworkAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }
  if (a.type == InternetAddressType.IPv6) {
    // IPv4-mapped (::ffff:a.b.c.d)
    final mapped =
        b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) {
      return isLocalNetworkAddress(
        InternetAddress.fromRawAddress(b.sublist(12)),
      );
    }
    return (b[0] & 0xfe) == 0xfc; // fc00::/7
  }
  return false;
}

/// This PC's IPv4 addresses on local networks, most likely Wi-Fi/Ethernet
/// first (virtual adapters for WSL, Hyper-V, VPNs etc. last).
Future<List<String>> localIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  final scored = <(int, String)>[];
  for (final nic in interfaces) {
    final name = nic.name.toLowerCase();
    final virtual = [
      'vethernet',
      'virtual',
      'vmware',
      'vbox',
      'hyper-v',
      'wsl',
      'docker',
      'tailscale',
      'zerotier',
      'vpn',
      'loopback',
    ].any(name.contains);
    for (final addr in nic.addresses) {
      if (addr.isLoopback || !isLocalNetworkAddress(addr)) continue;
      final b = addr.rawAddress;
      var score = virtual ? 10 : 0;
      if (b[0] == 172) score += 5; // commonly virtual switches
      if (name.contains('wi-fi') || name.contains('wlan')) score -= 1;
      scored.add((score, addr.address));
    }
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final s in scored) s.$2];
}
