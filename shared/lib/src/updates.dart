import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Releases live on GitHub; both apps check the latest one and update from it.
const releaseRepo = 'SepiHub/PocketDrive';

/// This build's version, set by tools/release.ps1 (`--dart-define`).
/// Builds made with plain `flutter run` are "dev" and never offer updates.
const appVersion = String.fromEnvironment('PD_VERSION', defaultValue: 'dev');

bool get isReleaseBuild => parseVersion(appVersion) != null;

/// "1.2.3" or "v1.2.3" → [1, 2, 3]; anything else → null.
List<int>? parseVersion(String v) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

/// Whether [candidate] is a newer version than [current].
bool isNewerVersion(String candidate, String current) {
  final a = parseVersion(candidate);
  final b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size, this.sha256);
  final String name;
  final Uri url;
  final int size;

  /// Hex SHA-256 GitHub computed for the upload, when it reports one.
  final String? sha256;
}

class ReleaseInfo {
  const ReleaseInfo(this.version, this.notes, this.assets);
  final String version; // "1.2.3"
  final String notes;
  final List<ReleaseAsset> assets;

  ReleaseAsset? assetEndingWith(String suffix) {
    for (final a in assets) {
      if (a.name.toLowerCase().endsWith(suffix)) return a;
    }
    return null;
  }

  static ReleaseInfo? fromJson(Map<String, dynamic> j) {
    final tag = j['tag_name'];
    if (tag is! String || parseVersion(tag) == null) return null;
    if (j['draft'] == true || j['prerelease'] == true) return null;
    final assets = <ReleaseAsset>[];
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is! Map) continue;
      final url = Uri.tryParse('${a['browser_download_url']}');
      if (url == null || url.scheme != 'https') continue;
      final digest = a['digest'];
      assets.add(
        ReleaseAsset(
          '${a['name']}',
          url,
          (a['size'] as num?)?.toInt() ?? 0,
          digest is String && digest.startsWith('sha256:')
              ? digest.substring(7).toLowerCase()
              : null,
        ),
      );
    }
    final v = parseVersion(tag)!;
    return ReleaseInfo(v.join('.'), '${j['body'] ?? ''}', assets);
  }
}

/// Asks GitHub for the latest release. Returns it only if it is newer than
/// this build; null when up to date, offline, or a dev build.
Future<ReleaseInfo?> checkForUpdate({String current = appVersion}) async {
  if (parseVersion(current) == null) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(
      Uri.https('api.github.com', '/repos/$releaseRepo/releases/latest'),
    );
    req.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'PocketDrive-updater');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final body = await res.transform(utf8.decoder).join();
    final info = ReleaseInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    if (info == null || !isNewerVersion(info.version, current)) return null;
    return info;
  } on Object {
    return null; // offline or GitHub unreachable: try again later
  } finally {
    client.close(force: true);
  }
}

/// Downloads [asset] to [target] (via a .partial file), reporting progress,
/// and checks it against GitHub's SHA-256 when one is given.
Future<File> downloadAsset(
  ReleaseAsset asset,
  File target, {
  void Function(int received, int total)? onProgress,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final partial = File('${target.path}.partial');
  try {
    await target.parent.create(recursive: true);
    final req = await client.getUrl(asset.url);
    req.headers.set(HttpHeaders.userAgentHeader, 'PocketDrive-updater');
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('Download failed (${res.statusCode})');
    }
    final total = res.contentLength > 0 ? res.contentLength : asset.size;
    final sink = partial.openWrite();
    final hashOut = _DigestSink();
    final hasher = sha256.startChunkedConversion(hashOut);
    var received = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    final expected = asset.sha256;
    if (expected != null && hashOut.value.toString() != expected) {
      throw const FileSystemException('Download was corrupted, try again');
    }
    if (await target.exists()) await target.delete();
    return await partial.rename(target.path);
  } on Object {
    try {
      if (await partial.exists()) await partial.delete();
    } on Object {
      // ignore
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
