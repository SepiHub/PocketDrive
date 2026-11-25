import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketdrive_pc/server/path_jail.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late PathJail jail;

  setUpAll(() async {
    f = await Fixture.create();
    jail = await PathJail.open(f.share);
  });
  tearDownAll(() => f.delete());

  group('path syntax is rejected', () {
    const bad = {
      'parent': '..',
      'parent then file': '../outside/secret.txt',
      'parent in the middle': 'sub/../../outside/secret.txt',
      'dot segment': './a.txt',
      'leading slash': '/a.txt',
      'double slash': 'sub//b.txt',
      'trailing slash': 'sub/',
      'backslash separator': r'sub\b.txt',
      'backslash parent': r'..\outside\secret.txt',
      'drive letter': 'C:/Windows/win.ini',
      'drive letter backslash': r'C:\Windows\win.ini',
      'UNC path': r'\\localhost\c$\Windows',
      'device path': r'\\?\C:\Windows',
      'alternate data stream': 'a.txt:secret',
      'default data stream': 'a.txt::\$DATA',
      'device name': 'NUL',
      'device name with extension': 'con.txt',
      'device name superscript': 'COM¹',
      'trailing dot': 'a.txt.',
      'trailing space': 'a.txt ',
      'wildcard': 'a*.txt',
      'null byte': 'a.txt\u0000.jpg',
    };
    for (final MapEntry(key: name, value: path) in bad.entries) {
      test(name, () {
        expect(() => jail.resolveExisting(path), throwsA(isA<PathRejected>()));
      });
    }
  });

  group('links that leave the folder are blocked', () {
    test('junction to an outside folder', () async {
      await expectLater(
          jail.resolveExisting('escape'), throwsA(isA<PathRejected>()));
      await expectLater(jail.resolveExisting('escape/secret.txt'),
          throwsA(isA<PathRejected>()));
      await expectLater(jail.list('escape'), throwsA(isA<PathRejected>()));
    });

    test('file symlink to an outside file', () async {
      await expectLater(
          jail.resolveExisting('link.txt'), throwsA(isA<PathRejected>()));
    }, skip: !_symlinksWork() ? 'symlinks need Developer Mode' : false);
  });

  group('allowed paths', () {
    test('the shared folder itself', () async {
      expect(await jail.resolveExisting(''), jail.root);
    });

    test('a file and a nested file', () async {
      expect(await jail.resolveExisting('a.txt'), p.join(jail.root, 'a.txt'));
      expect(await jail.resolveExisting('sub/b.txt'),
          p.join(jail.root, 'sub', 'b.txt'));
    });

    test('different letter case (Windows ignores case)', () async {
      final real = await jail.resolveExisting('SUB/B.TXT');
      expect(jail.contains(real), isTrue);
    });

    test('junction that stays inside resolves to its real target', () async {
      expect(await jail.resolveExisting('inner/b.txt'),
          p.join(jail.root, 'sub', 'b.txt'));
    });

    test('symlink that stays inside', () async {
      expect(await jail.resolveExisting('okLink.txt'),
          p.join(jail.root, 'a.txt'));
    }, skip: !_symlinksWork() ? 'symlinks need Developer Mode' : false);

    test('missing file is not found, not an error', () async {
      await expectLater(
          jail.resolveExisting('nope.txt'), throwsA(isA<PathNotFound>()));
    });

    test('sharing a folder through a junction still jails correctly',
        () async {
      final viaLink = await PathJail.open(f.rootLink);
      expect(viaLink.root, jail.root);
      await expectLater(viaLink.resolveExisting('escape/secret.txt'),
          throwsA(isA<PathRejected>()));
      expect(await viaLink.resolveExisting('a.txt'),
          p.join(jail.root, 'a.txt'));
    });
  });

  group('listing', () {
    test('shows normal entries, hides links out, hidden and partial files',
        () async {
      final names = [for (final e in await jail.list('')) e.name];
      expect(names, containsAllInOrder(['inner', 'sub', 'a.txt']));
      expect(names, isNot(contains('escape')));
      expect(names, isNot(contains('link.txt')));
      expect(names, isNot(contains('.hidden')));
      expect(names, isNot(contains('Thumbs.db')));
      expect(names, isNot(contains('upload.mp4.partial')));
    });

    test('folders come first and have size 0', () async {
      final entries = await jail.list('');
      expect(entries.first.isDir, isTrue);
      expect(entries.firstWhere((e) => e.name == 'a.txt').size, 11);
    });

    test('listing a file is refused', () async {
      await expectLater(jail.list('a.txt'), throwsA(isA<NotADirectory>()));
    });
  });
}

/// Whether this machine can create symlinks (decided before tests are
/// registered, so `skip` can use it).
bool _symlinksWork() {
  final dir = Directory.systemTemp.createTempSync('pocketdrive_symcheck_');
  try {
    Link(p.join(dir.path, 'l')).createSync(dir.path);
    return true;
  } on FileSystemException {
    return false;
  } finally {
    try {
      Link(p.join(dir.path, 'l')).deleteSync();
    } on FileSystemException {
      // wasn't created
    }
    dir.deleteSync();
  }
}
