import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

void main() {
  test('version parsing and comparison', () {
    expect(parseVersion('v1.2.3'), [1, 2, 3]);
    expect(parseVersion('1.10.0'), [1, 10, 0]);
    expect(parseVersion('dev'), isNull);
    expect(parseVersion('1.2'), isNull);
    expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
    expect(isNewerVersion('1.10.0', '1.9.9'), isTrue);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('0.9.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0.1', 'dev'), isFalse);
  });

  test('reads a GitHub release', () {
    final r = ReleaseInfo.fromJson({
      'tag_name': 'v1.2.0',
      'body': 'notes',
      'assets': [
        {
          'name': 'PocketDrive-Setup-1.2.0.exe',
          'browser_download_url': 'https://github.com/x/y/a.exe',
          'size': 10,
          'digest': 'sha256:ABCD',
        },
        {
          'name': 'evil.apk',
          'browser_download_url': 'http://example.com/evil.apk',
        },
      ],
    })!;
    expect(r.version, '1.2.0');
    expect(r.assetEndingWith('.exe')!.sha256, 'abcd');
    expect(r.assetEndingWith('.apk'), isNull); // not https: ignored
    expect(ReleaseInfo.fromJson({'tag_name': 'v2.0.0', 'draft': true}), isNull);
  });
}
