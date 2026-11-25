import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// A temporary folder tree for tests:
///
/// ```
/// base/
///   outside/secret.txt         <- must never be reachable
///   share/                     <- the shared folder
///     a.txt                    "hello world"
///     sub/b.txt
///     photo.jpg                1200x800
///     .hidden, Thumbs.db, upload.mp4.partial
///     escape  -> junction to base/outside
///     inner   -> junction to share/sub (allowed)
///     link.txt   -> symlink to outside/secret.txt   (if symlinks work)
///     okLink.txt -> symlink to share/a.txt          (if symlinks work)
///   rootLink -> junction to share (sharing a folder through a junction)
/// ```
class Fixture {
  Fixture._(this.base);
  final Directory base;
  bool symlinksWork = false;

  String get share => p.join(base.path, 'share');
  String get outside => p.join(base.path, 'outside');
  String get rootLink => p.join(base.path, 'rootLink');

  static Future<Fixture> create() async {
    final base = await Directory.systemTemp.createTemp('pocketdrive_test_');
    final f = Fixture._(base);
    await Directory(p.join(f.share, 'sub')).create(recursive: true);
    await Directory(f.outside).create();
    await File(p.join(f.outside, 'secret.txt')).writeAsString('SECRET');
    await File(p.join(f.share, 'a.txt')).writeAsString('hello world');
    await File(p.join(f.share, 'sub', 'b.txt')).writeAsString('bee');
    // A 1200x800 photo with a gradient, for thumbnail tests.
    final photo = img.Image(width: 1200, height: 800);
    for (final px in photo) {
      px
        ..r = px.x * 255 ~/ 1200
        ..g = px.y * 255 ~/ 800
        ..b = 128;
    }
    await File(p.join(f.share, 'photo.jpg')).writeAsBytes(img.encodeJpg(photo));
    await File(p.join(f.share, '.hidden')).writeAsString('x');
    await File(p.join(f.share, 'Thumbs.db')).writeAsString('x');
    await File(p.join(f.share, 'upload.mp4.partial')).writeAsString('x');
    await _junction(p.join(f.share, 'escape'), f.outside);
    await _junction(p.join(f.share, 'inner'), p.join(f.share, 'sub'));
    await _junction(f.rootLink, f.share);
    try {
      await Link(p.join(f.share, 'link.txt'))
          .create(p.join(f.outside, 'secret.txt'));
      await Link(p.join(f.share, 'okLink.txt'))
          .create(p.join(f.share, 'a.txt'));
      f.symlinksWork = true;
    } on FileSystemException {
      // Needs Developer Mode or admin rights; those tests get skipped.
    }
    return f;
  }

  static Future<void> _junction(String link, String target) async {
    final r = await Process.run('cmd', ['/c', 'mklink', '/J', link, target]);
    if (r.exitCode != 0) {
      throw StateError('mklink /J failed: ${r.stdout} ${r.stderr}');
    }
  }

  Future<void> delete() async {
    // Remove links first so deleting never follows them.
    for (final l in ['escape', 'inner', 'link.txt', 'okLink.txt']) {
      final path = p.join(share, l);
      if (await FileSystemEntity.isLink(path) ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        await Process.run('cmd', ['/c', 'rmdir', path]);
        await Process.run('cmd', ['/c', 'del', '/q', path]);
      }
    }
    await Process.run('cmd', ['/c', 'rmdir', rootLink]);
    await base.delete(recursive: true);
  }
}
