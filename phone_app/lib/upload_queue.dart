import 'dart:async';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'pc_client.dart';

enum UploadState { waiting, sending, done, failed, cancelled }

class UploadItem {
  UploadItem(this.folder, this.file, this.name, this.total);
  final String folder;
  final XFile file;
  String name;
  final int total;
  int sent = 0;
  UploadState state = UploadState.waiting;
  String? error;

  bool get finished =>
      state == UploadState.done ||
      state == UploadState.failed ||
      state == UploadState.cancelled;
}

/// Uploads files one after another and reports progress. Keeps the screen
/// on while uploading so Android doesn't pause the app halfway.
class UploadQueue extends ChangeNotifier {
  UploadQueue(this.client);

  final PcClient client;
  final List<UploadItem> items = [];
  final _folderChanged = StreamController<String>.broadcast();
  UploadCancel? _cancel;
  bool _running = false;
  DateTime _lastNotify = DateTime(0);

  /// Fires with a folder path whenever a file landed in it.
  Stream<String> get folderChanged => _folderChanged.stream;

  bool get busy => items.any((i) => !i.finished);
  int get doneCount => items.where((i) => i.state == UploadState.done).length;
  int get failedCount =>
      items.where((i) => i.state == UploadState.failed).length;
  int get totalBytes => items.fold(0, (s, i) => s + i.total);
  int get sentBytes => items.fold(
    0,
    (s, i) => s + (i.state == UploadState.done ? i.total : i.sent),
  );
  UploadItem? get current =>
      items.where((i) => i.state == UploadState.sending).firstOrNull;

  Future<void> add(String folder, List<XFile> files) async {
    for (final f in files) {
      items.add(UploadItem(folder, f, f.name, await f.length()));
    }
    notifyListeners();
    if (!_running) unawaited(_run());
  }

  Future<void> _run() async {
    _running = true;
    await WakelockPlus.enable();
    try {
      while (true) {
        final item = items
            .where((i) => i.state == UploadState.waiting)
            .firstOrNull;
        if (item == null) break;
        item.state = UploadState.sending;
        notifyListeners();
        final cancel = _cancel = UploadCancel();
        try {
          final entry = await client.upload(
            item.folder,
            item.name,
            File(item.file.path),
            onProgress: (sent, _) {
              item.sent = sent;
              _throttledNotify();
            },
            cancel: cancel,
          );
          item
            ..name = entry.name
            ..state = UploadState.done;
          _folderChanged.add(item.folder);
          await _deletePickerCopy(item.file);
        } on UploadCancelled {
          item.state = UploadState.cancelled;
        } on PcError catch (e) {
          item
            ..state = UploadState.failed
            ..error = e.code;
        } on Object catch (e) {
          item
            ..state = UploadState.failed
            ..error = '$e';
        }
        notifyListeners();
      }
    } finally {
      _cancel = null;
      _running = false;
      await WakelockPlus.disable();
      notifyListeners();
    }
  }

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds > 150) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  /// The gallery picker hands us copies in the app's cache; remove them once
  /// uploaded so they don't fill up the phone. (Never touches the originals.)
  Future<void> _deletePickerCopy(XFile f) async {
    try {
      final cache = (await getTemporaryDirectory()).parent.path;
      if (File(f.path).absolute.path.startsWith(cache)) {
        await File(f.path).delete();
      }
    } on Object {
      // not critical
    }
  }

  void cancelAll() {
    for (final i in items) {
      if (i.state == UploadState.waiting) i.state = UploadState.cancelled;
    }
    _cancel?.cancel();
    notifyListeners();
  }

  void clearFinished() {
    items.removeWhere((i) => i.finished);
    notifyListeners();
  }

  @override
  void dispose() {
    cancelAll();
    unawaited(_folderChanged.close());
    super.dispose();
  }
}

/// Progress card shown at the bottom of folder pages while uploading, and a
/// summary once done.
class UploadBanner extends StatelessWidget {
  const UploadBanner({super.key, required this.queue});
  final UploadQueue queue;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        if (queue.items.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final total = queue.items.length;
        final busy = queue.busy;
        final current = queue.current;
        final progress = queue.totalBytes == 0
            ? null
            : queue.sentBytes / queue.totalBytes;
        final failed = queue.failedCount;
        return Card(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      busy
                          ? Icons.cloud_upload_outlined
                          : failed > 0
                          ? Icons.error_outline
                          : Icons.cloud_done_outlined,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        busy
                            ? 'Uploading ${queue.doneCount + 1} of $total'
                                  '${current == null ? '' : ' · ${current.name}'}'
                            : 'Uploaded ${queue.doneCount} of $total'
                                  '${failed > 0 ? ' · $failed failed' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: busy ? queue.cancelAll : queue.clearFinished,
                      child: Text(busy ? 'Cancel' : 'Close'),
                    ),
                  ],
                ),
                if (busy) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress),
                ],
                if (!busy && failed > 0)
                  for (final i
                      in queue.items
                          .where((i) => i.state == UploadState.failed)
                          .take(3))
                    Text(
                      '${i.name}: ${i.error}',
                      style: theme.textTheme.bodySmall,
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}
