import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'config.dart';
import 'desktop.dart';
import 'identity.dart';
import 'pairing_dialog.dart';
import 'server/devices.dart';
import 'server/file_server.dart';
import 'server/announce.dart';
import 'server/hidden_folders.dart';
import 'server/network.dart';
import 'server/thumbnails.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _server = PocketServer();
  final _announcer = Announcer();
  late final _shell = DesktopShell(
    onToggleSharing: () =>
        unawaited(_server.isRunning ? _stopServer() : _startServer()),
    onQuit: _quit,
  );
  bool _startAtLogin = false;
  final _paired = StreamController<PairedDevice>.broadcast();
  final _thumbs = ThumbnailService(
    Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? AppConfig.dataDir.path,
        'PocketDrive',
        'thumbs',
      ),
    ),
  );
  AppConfig? _config;
  PcIdentity? _identity;
  DeviceStore? _devices;
  HiddenFolders? _hidden;
  StreamSubscription<void>? _devicesSub;
  PairingWindow? _pairing;
  String? _error;
  String _status = 'Starting…';
  bool _busy = false;

  bool get _ready => _config != null && _identity != null && _devices != null;

  @override
  void initState() {
    super.initState();
    _shell.init();
    unawaited(
      StartAtLogin.isEnabled().then((on) {
        if (mounted) setState(() => _startAtLogin = on);
      }),
    );
    unawaited(_init());
  }

  /// Fully exits (the window's close button only hides to the tray).
  Future<void> _quit() async {
    await _announcer.stop();
    await _server.stop();
    _shell.dispose();
    exit(0);
  }

  Future<void> _init() async {
    try {
      final config = await AppConfig.load();
      setState(() {
        _config = config;
        _status =
            'Preparing this PC\'s security certificate '
            '(first start only, a few seconds)…';
      });
      final identity = await PcIdentity.loadOrCreate(
        Directory(p.join(AppConfig.dataDir.path, 'identity')),
      );
      final devices = await DeviceStore.load(
        File(p.join(AppConfig.dataDir.path, 'devices.json')),
      );
      _hidden = await HiddenFolders.load(
        File(p.join(AppConfig.dataDir.path, 'hidden.json')),
      );
      _devicesSub = devices.changes.listen((_) {
        if (mounted) setState(() {});
      });
      setState(() {
        _identity = identity;
        _devices = devices;
      });
      if (config.sharedFolder != null) await _startServer();
    } on Object catch (e) {
      setState(() => _error = 'Could not start: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_announcer.stop());
    unawaited(_server.stop());
    unawaited(_devicesSub?.cancel());
    unawaited(_paired.close());
    super.dispose();
  }

  Future<void> _chooseFolder() async {
    final picked = await getDirectoryPath(
      confirmButtonText: 'Share this folder',
      initialDirectory: _config?.sharedFolder,
    );
    if (picked == null) return;
    final problem = checkShareableFolder(picked);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    _config!.sharedFolder = picked;
    await _config!.save();
    await _startServer();
  }

  Future<void> _startServer() async {
    final folder = _config?.sharedFolder;
    if (folder == null || !_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _server.start(
        folder: folder,
        devices: _devices!,
        identity: _identity!,
        pairingWindow: () => _pairing,
        thumbs: _thumbs,
        hidden: _hidden,
        onPaired: _paired.add,
        log: debugPrint,
      );
    } on SocketException catch (e) {
      _error =
          'Could not start the server (is PocketDrive already running?): '
          '${e.osError?.message ?? e.message}';
    } on Object catch (e) {
      _error = 'Could not start the server: $e';
    }
    if (_server.isRunning) {
      await _announcer.start(
        pcId: _identity!.pcId,
        pcName: _identity!.pcName,
        port: _server.port!,
        log: debugPrint,
      );
    }
    _shell.updateSharing(sharing: _server.isRunning);
    setState(() => _busy = false);
  }

  Future<void> _stopServer() async {
    await _announcer.stop();
    await _server.stop();
    _shell.updateSharing(sharing: false);
    setState(() {});
  }

  Future<void> _pairPhone() async {
    final hosts = await localIpv4Addresses();
    if (hosts.isEmpty) {
      setState(() => _error = 'This PC doesn\'t seem to be on a network.');
      return;
    }
    final window = PairingWindow();
    _pairing = window;
    final qr = PairingQr(
      pcId: _identity!.pcId,
      pcName: _identity!.pcName,
      hosts: hosts,
      port: _server.port!,
      code: window.code,
      fingerprint: _identity!.fingerprint,
    );
    if (!mounted) return;
    final device = await showDialog<PairedDevice>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          PairingDialog(window: window, qr: qr, paired: _paired.stream),
    );
    window.close();
    _pairing = null;
    if (device != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Paired with ${device.name}')));
    }
  }

  Future<void> _revoke(PairedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text(
          'It will no longer be able to connect. '
          'You can pair it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok ?? false) await _devices!.revoke(d.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _config;
    if (!_ready || config == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('PocketDrive')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error == null) const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_error ?? _status, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }
    final devices = _devices!.devices;
    return Scaffold(
      appBar: AppBar(title: Text('PocketDrive — ${_identity!.pcName}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: const Text('Shared folder'),
              subtitle: Text(config.sharedFolder ?? 'None chosen yet'),
              trailing: FilledButton.tonal(
                onPressed: _busy ? null : _chooseFolder,
                child: Text(
                  config.sharedFolder == null ? 'Choose folder…' : 'Change…',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(
                _server.isRunning ? Icons.lock : Icons.cloud_off,
                color: _server.isRunning ? Colors.green : null,
              ),
              title: Text(
                _server.isRunning ? 'Sharing (encrypted)' : 'Not sharing',
              ),
              subtitle: Text(
                _server.isRunning
                    ? 'Paired phones on your home network can connect '
                          '(port ${_server.port}).'
                    : config.sharedFolder == null
                    ? 'Choose a folder to start sharing.'
                    : 'Stopped.',
              ),
              trailing: config.sharedFolder == null
                  ? null
                  : OutlinedButton(
                      onPressed: _busy
                          ? null
                          : (_server.isRunning ? _stopServer : _startServer),
                      child: Text(_server.isRunning ? 'Stop' : 'Start'),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.power_settings_new),
              title: const Text('Start with Windows'),
              subtitle: const Text(
                'Starts in the tray when you sign in. Closing this window '
                'keeps PocketDrive running in the tray; quit from the tray '
                'icon.',
              ),
              value: _startAtLogin,
              onChanged: (on) async {
                await StartAtLogin.setEnabled(on);
                final now = await StartAtLogin.isEnabled();
                if (mounted) setState(() => _startAtLogin = now);
              },
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                title: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Paired phones', style: theme.textTheme.titleMedium),
              const Spacer(),
              FilledButton.icon(
                onPressed: _server.isRunning ? _pairPhone : null,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Pair a phone'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('No phones yet.', style: theme.textTheme.bodyMedium),
            ),
          for (final d in devices)
            Card(
              child: ListTile(
                leading: const Icon(Icons.smartphone),
                title: Text(d.name),
                subtitle: Text(
                  'Paired ${_date(d.pairedAt)}'
                  '${d.lastSeen == null ? '' : ' · last seen ${_date(d.lastSeen!)}'}',
                ),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _revoke(d),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _date(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
