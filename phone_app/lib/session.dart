import 'app_settings.dart';
import 'pc_client.dart';
import 'thumbnails.dart';
import 'upload_queue.dart';
import 'video_relay.dart';

/// Everything that belongs to the connection with the paired PC, shared by
/// all screens.
class PcSession {
  PcSession({
    required this.client,
    required this.thumbs,
    required this.relay,
    required this.uploads,
    required this.settings,
  });

  final PcClient client;
  final ThumbnailCache thumbs;
  final VideoRelay relay;
  final UploadQueue uploads;
  final AppSettings settings;
}
