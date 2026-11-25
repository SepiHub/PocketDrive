import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// Looks for a newer PocketDrive on GitHub (at start, then every few hours)
/// and installs it on request: downloads the installer, runs it silently,
/// and quits so it can replace the files. The installer starts the new
/// version when it's done.
class PcUpdater extends ChangeNotifier {
  PcUpdater({required this.quit});

  /// Stops sharing and exits the app.
  final Future<void> Function() quit;

  ReleaseInfo? available;
  double? progress; // 0..1 while downloading
  bool checking = false;
  bool upToDate = false;
  String? error;
  Timer? _timer;

  bool get installing => progress != null;

  void start() {
    if (!isReleaseBuild) return;
    unawaited(check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  Future<void> check() async {
    if (!isReleaseBuild || checking || installing) return;
    checking = true;
    error = null;
    notifyListeners();
    final info = await checkForUpdate();
    checking = false;
    if (info != null && info.assetEndingWith('.exe') != null) {
      available = info;
    }
    upToDate = available == null;
    notifyListeners();
  }

  Future<void> install() async {
    final info = available;
    final asset = info?.assetEndingWith('.exe');
    if (info == null || asset == null || installing) return;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final dir = Directory(
        p.join(Directory.systemTemp.path, 'PocketDrive-update'),
      );
      final setup = await downloadAsset(
        asset,
        File(p.join(dir.path, 'PocketDrive-Setup-${info.version}.exe')),
        onProgress: (got, total) {
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        },
      );
      await Process.start(setup.path, const [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
      await quit();
    } on Object catch (e) {
      progress = null;
      error = 'Update failed: $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
