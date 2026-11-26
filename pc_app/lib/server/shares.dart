import 'package:path/path.dart' as p;

import 'path_jail.dart';

/// One shared folder, as the phone sees it.
class Share {
  Share(this.name, this.jail);

  /// Name shown on the phone (the folder's own name, made unique).
  final String name;
  final PathJail jail;
}

/// A client path routed to the share it belongs to.
class Routed {
  const Routed(this.share, this.rel);
  final Share share;

  /// Path inside [share] (`''` = the shared folder itself).
  final String rel;

  /// Turns a path inside this share back into the phone's path.
  String client(String inner) {
    final prefix = share.name;
    if (prefix.isEmpty) return inner;
    return inner.isEmpty ? prefix : '$prefix/$inner';
  }
}

/// The folders this PC shares.
///
/// With one folder, the phone's paths are relative to it, exactly like
/// before. With several, the phone's top level lists the folders by name,
/// and every path starts with one of those names (`Photos/2024/a.jpg`).
/// Each folder keeps its own [PathJail], so nothing can escape any of them.
class Shares {
  Shares._(this.all);

  final List<Share> all;

  /// True when the phone's top level is the list of shared folders.
  bool get isMulti => all.length > 1;

  static Future<Shares> open(List<String> folders) async {
    if (folders.isEmpty) throw ArgumentError('no folders to share');
    final jails = [for (final f in folders) await PathJail.open(f)];
    if (jails.length == 1) return Shares._([Share('', jails.single)]);
    final used = <String>{};
    final shares = <Share>[];
    for (final jail in jails) {
      final base = _safeName(p.basename(jail.root));
      var name = base;
      for (var i = 2; used.contains(name.toLowerCase()); i++) {
        name = '$base ($i)';
      }
      used.add(name.toLowerCase());
      shares.add(Share(name, jail));
    }
    return Shares._(shares);
  }

  /// Finds the share a client path belongs to. Throws [PathRejected] for the
  /// top level when several folders are shared (it isn't a real folder) and
  /// [PathNotFound] for an unknown share name.
  Routed route(String rel) {
    if (!isMulti) return Routed(all.single, rel);
    if (rel.isEmpty) throw const PathRejected('top level of several shares');
    final slash = rel.indexOf('/');
    final first = slash < 0 ? rel : rel.substring(0, slash);
    final rest = slash < 0 ? '' : rel.substring(slash + 1);
    if (slash >= 0 && rest.isEmpty) throw const PathRejected('empty segment');
    for (final s in all) {
      if (s.name.toLowerCase() == first.toLowerCase()) return Routed(s, rest);
    }
    throw const PathNotFound();
  }
}

/// A name the phone can use as a path segment.
String _safeName(String name) {
  try {
    PathJail.checkName(name);
    return name;
  } on PathRejected {
    final cleaned = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    try {
      PathJail.checkName(cleaned);
      return cleaned;
    } on PathRejected {
      return 'Folder';
    }
  }
}
