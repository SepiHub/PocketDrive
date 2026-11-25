import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'browser_page.dart';
import 'discovery.dart';
import 'app_settings.dart';
import 'pairing_store.dart';
import 'pc_client.dart';
import 'scan_page.dart';
import 'session.dart';
import 'thumbnails.dart';
import 'upload_queue.dart';
import 'video_relay.dart';

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
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
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
  AppSettings? _settings;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final pairing = await _store.load();
    final settings = await AppSettings.load();
    setState(() {
      _pairing = pairing;
      _settings = settings;
      _loaded = true;
    });
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
      settings: _settings!,
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
      _error =
          "Couldn't reach ${qr.pcName}. Check that the phone is on the "
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
          Text(
            'Pair with your PC',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Text(
            '1. On your PC, open PocketDrive and click '
            '"Pair a phone".\n'
            '2. Tap the button below and point the camera at the code.',
          ),
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
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The paired PC: owns the connection and shows its shared folder.
class PcPage extends StatefulWidget {
  const PcPage({
    super.key,
    required this.pairing,
    required this.settings,
    required this.onUnpair,
    required this.onHostChanged,
  });

  final PcPairing pairing;
  final AppSettings settings;
  final Future<void> Function() onUnpair;
  final void Function(String) onHostChanged;

  @override
  State<PcPage> createState() => _PcPageState();
}

class _PcPageState extends State<PcPage> {
  late final PcClient _client = PcClient(
    widget.pairing,
    onHostChanged: widget.onHostChanged,
  );
  late final ThumbnailCache _thumbs = ThumbnailCache(_client);
  late final VideoRelay _relay = VideoRelay(
    (path, range, method) =>
        _client.openFile(path, range: range, method: method),
  );
  late final UploadQueue _uploads = UploadQueue(_client);
  late final PcSession _session = PcSession(
    client: _client,
    thumbs: _thumbs,
    relay: _relay,
    uploads: _uploads,
    settings: widget.settings,
  );

  @override
  void dispose() {
    _uploads.dispose();
    unawaited(_relay.close());
    _client.close();
    super.dispose();
  }

  /// Searches the Wi-Fi for the paired PC and reconnects to it.
  Future<void> _findPc() async {
    final messenger = ScaffoldMessenger.of(context)
      ..showSnackBar(const SnackBar(content: Text('Looking for your PC…')));
    final found = await discoverPcAddresses(widget.pairing.pcId);
    messenger.hideCurrentSnackBar();
    if (found.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Didn't find your PC on this Wi-Fi. Is PocketDrive "
            'running there, and is the phone on the same network?',
          ),
        ),
      );
      return;
    }
    _client.forgetHost();
    for (final h in found) {
      if (!widget.pairing.hosts.contains(h)) widget.pairing.hosts.add(h);
    }
    widget.onHostChanged(found.first);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Found ${widget.pairing.pcName} at ${found.join(', ')}'),
      ),
    );
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok ?? false) await widget.onUnpair();
  }

  @override
  Widget build(BuildContext context) {
    return BrowserPage(
      session: _session,
      path: '',
      onNotPaired: () {
        Navigator.of(context).popUntil((r) => r.isFirst);
        unawaited(widget.onUnpair());
      },
      menu: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'unpair') {
            unawaited(_confirmUnpair());
          } else if (v == 'find') {
            unawaited(_findPc());
          } else {
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(settings: widget.settings),
                ),
              ),
            );
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'find', child: Text('Find my PC')),
          PopupMenuItem(value: 'settings', child: Text('Settings')),
          PopupMenuItem(value: 'unpair', child: Text('Forget this PC')),
        ],
      ),
    );
  }
}
