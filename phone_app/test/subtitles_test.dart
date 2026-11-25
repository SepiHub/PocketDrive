import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_phone/pc_client.dart';
import 'package:pocketdrive_phone/video_page.dart';

void main() {
  group('built-in tracks', () {
    const tracks = [
      EmbeddedTrack(index: 0, codec: 'ass', isText: true, language: 'jpn'),
      EmbeddedTrack(
        index: 1,
        codec: 'ass',
        isText: true,
        language: 'eng',
        title: 'Signs & Songs',
      ),
      EmbeddedTrack(index: 2, codec: 'ass', isText: true, language: 'eng'),
      EmbeddedTrack(
        index: 3,
        codec: 'hdmv_pgs_subtitle',
        isText: false,
        language: 'fre',
      ),
      EmbeddedTrack(index: 4, codec: 'subrip', isText: true, language: 'ger'),
    ];

    test('default: phone language, full subtitles before signs/forced', () {
      expect(defaultEmbeddedTrack(tracks, 'en')!.index, 2);
      expect(defaultEmbeddedTrack(tracks, 'de')!.index, 4);
      // No match: first full text track.
      expect(defaultEmbeddedTrack(tracks, 'ko')!.index, 0);
      // Picture-based tracks are never picked.
      expect(defaultEmbeddedTrack([tracks[3]], 'fr'), isNull);
    });

    test('labels', () {
      expect(embeddedTrackLabel(tracks[1]), 'English (Signs & Songs)');
      expect(embeddedTrackLabel(tracks[4]), 'German');
      expect(
        embeddedTrackLabel(
          const EmbeddedTrack(index: 6, codec: 'subrip', isText: true),
        ),
        'Track 7',
      );
    });

    test('styling is stripped from caption text', () {
      expect(plainCaption(r'{\an8}<i>Hello</i>'), 'Hello');
      expect(plainCaption('<b>Two</b>\nlines'), 'Two\nlines');
    });
  });

  const files = [
    'Movie.srt',
    'Movie.en.srt',
    'movie.English.vtt',
    'Movie 2.srt',
    'Other.srt',
    'Movies.srt',
  ];

  test('subtitle files match their video by name, ignoring case', () {
    expect(subtitlesFor('Movie.mp4', files), [
      'Movie.en.srt',
      'Movie.srt',
      'movie.English.vtt',
    ]);
    expect(subtitlesFor('Movie 2.mkv', files), ['Movie 2.srt']);
    expect(subtitlesFor('Nothing.mp4', files), isEmpty);
  });

  test('labels', () {
    expect(subtitleLabel('Movie.mp4', 'Movie.srt'), 'Default');
    expect(subtitleLabel('Movie.mp4', 'Movie.en.srt'), 'en');
    expect(subtitleLabel('Movie.mp4', 'movie.English.vtt'), 'English');
  });

  test('which files are subtitles', () {
    expect(isSubtitleFile('a.SRT'), isTrue);
    expect(isSubtitleFile('a.vtt'), isTrue);
    expect(isSubtitleFile('a.txt'), isFalse);
  });
}
