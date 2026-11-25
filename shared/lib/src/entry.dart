enum EntryType { dir, file }

enum MediaKind { image, video, other }

const _imageExtensions = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'dng',
};
const _videoExtensions = {
  'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', '3gp', 'wmv', 'mts', 'm2ts',
};

/// Guesses the media kind from a file name's extension.
MediaKind mediaKindForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return MediaKind.other;
  final ext = name.substring(dot + 1).toLowerCase();
  if (_imageExtensions.contains(ext)) return MediaKind.image;
  if (_videoExtensions.contains(ext)) return MediaKind.video;
  return MediaKind.other;
}

/// One file or folder inside a listed folder.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.type,
    required this.size,
    required this.modified,
    required this.kind,
  });

  final String name;
  final EntryType type;

  /// Size in bytes; 0 for folders.
  final int size;
  final DateTime modified;
  final MediaKind kind;

  bool get isDir => type == EntryType.dir;

  Map<String, Object?> toJson() => {
        'name': name,
        'type': type.name,
        'size': size,
        'modified': modified.millisecondsSinceEpoch,
        'kind': kind.name,
      };

  factory RemoteEntry.fromJson(Map<String, Object?> json) => RemoteEntry(
        name: json['name'] as String,
        type: EntryType.values.byName(json['type'] as String),
        size: (json['size'] as num).toInt(),
        modified: DateTime.fromMillisecondsSinceEpoch(
            (json['modified'] as num).toInt()),
        kind: MediaKind.values.byName(json['kind'] as String),
      );
}

/// Response of [Api.list].
class Listing {
  const Listing({required this.path, required this.entries});

  /// The listed folder, relative to the shared folder (`''` = top).
  final String path;
  final List<RemoteEntry> entries;

  Map<String, Object?> toJson() => {
        'path': path,
        'entries': [for (final e in entries) e.toJson()],
      };

  factory Listing.fromJson(Map<String, Object?> json) => Listing(
        path: json['path'] as String,
        entries: [
          for (final e in json['entries'] as List)
            RemoteEntry.fromJson((e as Map).cast<String, Object?>()),
        ],
      );
}
