import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'pairing_store.dart';
import 'pc_client.dart';
import 'scan_page.dart';

void main() {
  runApp(const PocketDriveApp());
}

class PocketDriveApp extends StatelessWidget {
  const PocketDriveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketDrive',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme:
          ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      home: const RootPage(),
    );
  }
}

/// Shows the setup screen until paired, then the PC screen.
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  final _store = PairingStore();
  PcPairing? _pairing;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_store.load().then((p) => setState(() {
          _pairing = p;
          _loaded = true;
        })));
  }

  Future<void> _onPaired(PcPairing p) async {
    await _store.save(p);
    setState(() => _pairing = p);
  }

  Future<void> _unpair() async {
    await _store.clear();
    setState(() => _pairing = null);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final p = _pairing;
    if (p == null) return SetupPage(onPaired: _onPaired);
    return PcPage(
      key: ValueKey(p.pcId + p.token),
      pairing: p,
      onUnpair: _unpair,
      onHostChanged: (h) {
        p.lastHost = h;
        unawaited(_store.save(p));
      },
    );
  }
}

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.onPaired});
  final Future<void> Function(PcPairing) onPaired;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  bool _busy = false;
  String? _error;

  Future<void> _scan() async {
    final qr = await Navigator.of(context)
        .push<PairingQr>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (qr == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final name = '${_capitalize(info.manufacturer)} ${info.model}';
      final pairing = await PcClient.pair(qr, name);
      await widget.onPaired(pairing);
      return;
    } on PcError catch (e) {
      _error = e.code == ApiError.pairingClosed
          ? 'That code has expired or was already used. On your PC, close '
              'the pairing window, click "Pair a phone" again and rescan.'
          : 'The PC refused pairing ($e).';
    } on PcUnreachable {
      _error = "Couldn't reach ${qr.pcName}. Check that the phone is on the "
          'same Wi-Fi as the PC, and that Windows Firewall allows '
          'PocketDrive on private networks.';
    } on Object catch (e) {
      _error = 'Pairing failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('PocketDrive')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.computer, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Pair with your PC',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          const Text('1. On your PC, open PocketDrive and click '
              '"Pair a phone".\n'
              '2. Tap the button below and point the camera at the code.'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(_busy ? 'Pairing…' : 'Scan QR code'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 24),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!,
                    style:
                        TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Stage 2 placeholder: proves the paired connection works by showing the
/// top of the shared folder. Real browsing comes in stage 3.
class PcPage extends StatefulWidget {
  const PcPage({
    super.key,
    required this.pairing,
    required this.onUnpair,
    required this.onHostChanged,
  });

  final PcPairing pairing;
  final Future<void> Function() onUnpair;
  final void Function(String) onHostChanged;

  @override
  State<PcPage> createState() => _PcPageState();
}

class _PcPageState extends State<PcPage> {
  late final PcClient _client =
      PcClient(widget.pairing, onHostChanged: widget.onHostChanged);
  Listing? _listing;
  String? _error;
  bool _notPaired = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _listing = await _client.list('');
    } on NotPaired {
      _notPaired = true;
      _error = '${widget.pairing.pcName} no longer accepts this phone '
          '(it was removed on the PC). Pair again.';
    } on PcUnreachable {
      _error = "Can't reach ${widget.pairing.pcName}. Is it on, is "
          'PocketDrive running there, and is the phone on the same Wi-Fi?';
    } on Object catch (e) {
      _error = 'Something went wrong: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _confirmUnpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this PC?'),
        content: const Text('You can pair again by scanning a new code.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (ok ?? false) await widget.onUnpair();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listing = _listing;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pairing.pcName),
        actions: [
          IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (_) => _confirmUnpair(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'unpair', child: Text('Forget this PC')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ListView(padding: const EdgeInsets.all(24), children: [
                  Text(_error!, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 16),
                  if (_notPaired)
                    FilledButton(
                        onPressed: widget.onUnpair,
                        child: const Text('Pair again'))
                  else
                    FilledButton(
                        onPressed: _load, child: const Text('Try again')),
                ])
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(children: [
                    ListTile(
                      leading: const Icon(Icons.lock, color: Colors.green),
                      title: const Text('Connected securely'),
                      subtitle: Text('${_client.host}:${widget.pairing.port}'
                          ' · ${listing!.entries.length} items in the '
                          'shared folder'),
                    ),
                    const Divider(),
                    for (final e in listing.entries)
                      ListTile(
                        leading: Icon(e.isDir
                            ? Icons.folder
                            : switch (e.kind) {
                                MediaKind.image => Icons.image_outlined,
                                MediaKind.video => Icons.movie_outlined,
                                MediaKind.other =>
                                  Icons.insert_drive_file_outlined,
                              }),
                        title: Text(e.name),
                      ),
                  ]),
                ),
    );
  }
}
