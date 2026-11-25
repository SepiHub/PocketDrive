/// A single HTTP byte range, both ends inclusive.
class ByteRange {
  const ByteRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'ByteRange($start-$end)';
}

/// The range is valid syntax but lies outside the file (HTTP 416).
class RangeNotSatisfiable implements Exception {
  const RangeNotSatisfiable();
}

final _rangePattern = RegExp(r'^bytes=(\d*)-(\d*)$');

/// Parses a `Range` header for a file of [size] bytes.
///
/// Returns `null` when the whole file should be sent: no header, a header we
/// don't understand, or several ranges (allowed by RFC 9110). Video players
/// only ever ask for one range.
ByteRange? parseRange(String? header, int size) {
  if (header == null) return null;
  final m = _rangePattern.firstMatch(header.trim());
  if (m == null) return null;
  final first = m.group(1)!;
  final last = m.group(2)!;
  if (first.isEmpty && last.isEmpty) return null;

  if (first.isEmpty) {
    // "bytes=-500": the last 500 bytes.
    final suffix = int.tryParse(last);
    if (suffix == null) return null;
    if (suffix == 0 || size == 0) throw const RangeNotSatisfiable();
    final start = suffix >= size ? 0 : size - suffix;
    return ByteRange(start, size - 1);
  }

  final start = int.tryParse(first);
  if (start == null) return null;
  final int? end = last.isEmpty ? null : int.tryParse(last);
  if (last.isNotEmpty && (end == null || end < start)) {
    return null; // invalid, ignore the header
  }
  if (start >= size) throw const RangeNotSatisfiable();
  return ByteRange(start, end == null || end >= size ? size - 1 : end);
}
