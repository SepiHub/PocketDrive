import 'pairing.dart';

/// HTTP endpoints of the PC server. Every `path` query parameter is relative
/// to the shared folder and uses `/` as separator; an empty path means the
/// shared folder itself.
abstract final class Api {
  static const int defaultPort = 8787;

  /// `GET ?path=` -> JSON [Listing].
  static const String list = '/api/list';

  /// `GET ?path=` -> file bytes. Supports a single HTTP `Range` (`bytes=a-b`).
  static const String file = '/api/file';

  /// `GET ?path=&size=` -> JPEG that fits in size x size (snapped up to
  /// 128, 256, 512, 1024 or 2048). 404 `no_thumbnail` if Windows can't
  /// preview the file.
  static const String thumb = '/api/thumb';

  /// `POST ?path=<folder>&name=<file name>&modified=<ms since epoch>` with
  /// the raw file bytes as body -> JSON [RemoteEntry] of the saved file
  /// (its name may get ` (2)` added; nothing is ever overwritten).
  static const String upload = '/api/upload';

  /// `POST ?path=<parent folder>&name=<new folder name>` -> JSON
  /// [RemoteEntry] of the new folder. 409 `exists` if the name is taken.
  static const String mkdir = '/api/mkdir';

  /// `POST ?to=<folder>` with JSON `{"paths": [...]}` -> JSON
  /// `{"moved": [{"from", "name"}], "failed": [{"path", "error"}]}`.
  /// Moved items keep their name unless taken (then ` (2)` is added).
  static const String move = '/api/move';

  /// `POST` [PairRequest] -> [PairResponse]. The only endpoint that needs no
  /// device token; works only while the PC shows a pairing QR code.
  static const String pair = '/api/pair';

  /// `GET` -> [PcInfo]. Cheap check that the token and PC are right.
  static const String info = '/api/info';

  /// Header carrying the device token: `Authorization: Bearer <token>`.
  static const String authHeader = 'authorization';
  static String bearer(String token) => 'Bearer $token';
}

/// Error codes the server puts in `{"error": "<code>"}` bodies.
abstract final class ApiError {
  static const String badPath = 'bad_path';
  static const String notFound = 'not_found';
  static const String notADirectory = 'not_a_directory';
  static const String notAFile = 'not_a_file';
  static const String unreadable = 'unreadable';
  static const String internal = 'internal';
  static const String unauthorized = 'unauthorized';
  static const String pairingClosed = 'pairing_closed';
  static const String badRequest = 'bad_request';
  static const String notLocalNetwork = 'not_local_network';
  static const String noThumbnail = 'no_thumbnail';
  static const String uploadIncomplete = 'upload_incomplete';
  static const String writeFailed = 'write_failed';
  static const String exists = 'exists';
}
