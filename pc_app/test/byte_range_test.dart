import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_pc/server/byte_range.dart';

void main() {
  const size = 1000;

  test('no header means whole file', () {
    expect(parseRange(null, size), isNull);
  });

  test('closed, open-ended and suffix ranges', () {
    expect(parseRange('bytes=0-99', size), const ByteRange(0, 99));
    expect(parseRange('bytes=500-', size), const ByteRange(500, 999));
    expect(parseRange('bytes=-100', size), const ByteRange(900, 999));
  });

  test('end past the file is clipped', () {
    expect(parseRange('bytes=900-5000', size), const ByteRange(900, 999));
    expect(parseRange('bytes=-5000', size), const ByteRange(0, 999));
  });

  test('ranges outside the file are not satisfiable', () {
    expect(() => parseRange('bytes=1000-', size),
        throwsA(isA<RangeNotSatisfiable>()));
    expect(() => parseRange('bytes=-0', size),
        throwsA(isA<RangeNotSatisfiable>()));
    expect(() => parseRange('bytes=0-', 0),
        throwsA(isA<RangeNotSatisfiable>()));
  });

  test('garbage and multiple ranges fall back to the whole file', () {
    for (final h in [
      'bytes=abc',
      'bytes=-',
      'items=0-5',
      'bytes=5-1',
      'bytes=0-1,5-6',
      'bytes=99999999999999999999999-',
    ]) {
      expect(parseRange(h, size), isNull, reason: h);
    }
  });
}
