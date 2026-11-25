import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'config.dart';
import 'server/file_server.dart';

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
          colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
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
  AppConfig? _config;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final config = await AppConfig.load();
    setState(() => _config = config);
    if (config.sharedFolder != null) await _startServer();
  }

  @override
  void dispose() {
    unawaited(_server.stop());
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
    if (folder == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _server.start(folder: folder, log: debugPrint);
    } on Object catch (e) {
      _error = 'Could not start the server: $e';
    }
    setState(() => _busy = false);
  }

  Future<void> _stopServer() async {
    await _server.stop();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('PocketDrive')),
      body: config == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const Text('Shared folder'),
                    subtitle: Text(config.sharedFolder ?? 'None chosen yet'),
                    trailing: FilledButton.tonal(
                      onPressed: _busy ? null : _chooseFolder,
                      child: Text(config.sharedFolder == null
                          ? 'Choose folder…'
                          : 'Change…'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: Icon(
                      _server.isRunning ? Icons.cloud_done : Icons.cloud_off,
                      color: _server.isRunning ? Colors.green : null,
                    ),
                    title: Text(_server.isRunning
                        ? 'Server running'
                        : 'Server stopped'),
                    subtitle: Text(_server.isRunning
                        ? 'http://127.0.0.1:${_server.port}  (this PC only for now)'
                        : config.sharedFolder == null
                            ? 'Choose a folder to start sharing.'
                            : 'Not sharing.'),
                    trailing: config.sharedFolder == null
                        ? null
                        : OutlinedButton(
                            onPressed: _busy
                                ? null
                                : (_server.isRunning
                                    ? _stopServer
                                    : _startServer),
                            child: Text(_server.isRunning ? 'Stop' : 'Start'),
                          ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer),
                      title: Text(_error!,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer)),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Your phone can\'t connect yet. Pairing with a QR code '
                  'comes in the next stage.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
