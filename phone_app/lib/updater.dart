import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// Checks GitHub for a newer PocketDrive when the app starts and offers it:
/// download the APK, then hand it to Android's installer (which asks you to
/// confirm). Your pairing and settings are kept across updates.
class PhoneUpdater extends ChangeNotifier {
  PhoneUpdater._();
  static final instance = PhoneUpdater._();

  static const _channel = MethodChannel('pocketdrive/update');

  /// Shows the "update available" banner from anywhere in the app.
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  ReleaseInfo? available;
  double? progress; // 0..1 while downloading
  bool checking = false;
  bool upToDate = false;
  String? error;
  bool _bannerShown = false;

  bool get downloading => progress != null;

  Future<void> check({bool showBanner = true}) async {
    if (!isReleaseBuild || checking || downloading) return;
    checking = true;
    error = null;
    notifyListeners();
    final info = await checkForUpdate();
    checking = false;
    if (info != null && info.assetEndingWith('.apk') != null) available = info;
    upToDate = available == null;
    notifyListeners();
    if (showBanner && available != null && !_bannerShown) _showBanner();
  }

  void _showBanner() {
    final m = messengerKey.currentState;
    final info = available;
    if (m == null || info == null) return;
    _bannerShown = true;
    m.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.system_update),
        content: Text('PocketDrive ${info.version} is available.'),
        actions: [
          TextButton(
            onPressed: m.hideCurrentMaterialBanner,
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              m.hideCurrentMaterialBanner();
              final ctx = messengerKey.currentContext;
              if (ctx != null) unawaited(update(ctx));
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  /// Downloads (with a progress dialog) and opens Android's installer.
  Future<void> update(BuildContext context) async {
    final info = available;
    final asset = info?.assetEndingWith('.apk');
    if (info == null || asset == null || downloading) return;

    if (!(await _channel.invokeMethod<bool>('canInstall') ?? false)) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow updates'),
          content: const Text(
            'Android needs your OK, once, for PocketDrive to install its own '
            'updates.\n\nOn the next screen, turn on "Allow from this '
            'source", then come back and tap Update again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (go ?? false) await _channel.invokeMethod<void>('allowInstalls');
      return;
    }

    progress = 0;
    error = null;
    notifyListeners();
    if (context.mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _DownloadDialog(updater: this, version: info.version),
        ),
      );
    }
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (await dir.exists()) await dir.delete(recursive: true); // old ones
      final apk = await downloadAsset(
        asset,
        File('${dir.path}/PocketDrive-${info.version}.apk'),
        onProgress: (got, total) {
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        },
      );
      progress = null;
      notifyListeners();
      await _channel.invokeMethod<void>('install', {'path': apk.path});
    } on Object catch (e) {
      progress = null;
      error = 'Update failed: $e';
      notifyListeners();
    }
  }
}

class _DownloadDialog extends StatelessWidget {
  const _DownloadDialog({required this.updater, required this.version});
  final PhoneUpdater updater;
  final String version;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        if (!updater.downloading) {
          // Finished (installer opened) or failed.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && updater.error == null) {
              Navigator.of(context).pop();
            }
          });
        }
        return AlertDialog(
          title: Text('Updating to $version'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (updater.error != null)
                Text(updater.error!)
              else ...[
                LinearProgressIndicator(value: updater.progress),
                const SizedBox(height: 12),
                const Text('Downloading…'),
              ],
            ],
          ),
          actions: [
            if (updater.error != null)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
          ],
        );
      },
    );
  }
}

/// "Version 1.0.0 · Check for updates" row for the Settings screen.
class UpdateTile extends StatelessWidget {
  const UpdateTile({super.key});

  @override
  Widget build(BuildContext context) {
    final u = PhoneUpdater.instance;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        if (!isReleaseBuild) {
          return const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Development build'),
            subtitle: Text('Updates are off for test builds.'),
          );
        }
        final info = u.available;
        return ListTile(
          leading: const Icon(Icons.system_update),
          title: Text('Version $appVersion'),
          subtitle: Text(
            u.checking
                ? 'Checking…'
                : info != null
                ? 'Version ${info.version} is available. Tap to update.'
                : u.upToDate
                ? 'Up to date. Tap to check again.'
                : 'Tap to check for updates.',
          ),
          onTap: u.checking
              ? null
              : () => info != null
                    ? u.update(context)
                    : u.check(showBanner: false),
        );
      },
    );
  }
}
