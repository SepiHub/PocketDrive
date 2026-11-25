/// HTTP endpoints of the PC server. Every `path` query parameter is relative
/// to the shared folder and uses `/` as separator; an empty path means the
/// shared folder itself.
abstract final class Api {
  static const int defaultPort = 8787;

  /// `GET ?path=` -> JSON [Listing].
  static const String list = '/api/list';

  /// `GET ?path=` -> file bytes. Supports a single HTTP `Range` (`bytes=a-b`).
  static const String file = '/api/file';

  /// `GET ?path=&size=` -> JPEG thumbnail (stage 3).
  static const String thumb = '/api/thumb';

  /// `POST ?path=` -> upload into a folder (stage 5).
  static const String upload = '/api/upload';

  /// `POST` -> exchange a one-time pairing code for a device token (stage 2).
  static const String pair = '/api/pair';
}

/// Error codes the server puts in `{"error": "<code>"}` bodies.
abstract final class ApiError {
  static const String badPath = 'bad_path';
  static const String notFound = 'not_found';
  static const String notADirectory = 'not_a_directory';
  static const String notAFile = 'not_a_file';
  static const String unreadable = 'unreadable';
  static const String internal = 'internal';
}
