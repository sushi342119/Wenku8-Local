import 'package:diff_match_patch/diff_match_patch.dart' as dmp;

/// A compact old-to-new UTF-16 coordinate map. No duplicate prose is retained.
/// Deleted annotation text lands beside its base text; equal text stays exact.
class ReaderCoordinateMap {
  const ReaderCoordinateMap(
    this.oldLengths,
    this.operations, {
    this.sourceRevision = '',
    this.previous,
  });
  final List<int> oldLengths;
  final List<List<int>> operations;
  final String sourceRevision;
  final ReaderCoordinateMap? previous;
  bool accepts(String revision) =>
      revision == sourceRevision ||
      (revision.isEmpty && previous == null) ||
      previous?.accepts(revision) == true;
  static ReaderCoordinateMap between(
    List<String> before,
    List<String> after, {
    String sourceRevision = '',
    ReaderCoordinateMap? previous,
  }) {
    final differences = dmp.diff(
      before.join('\n\n'),
      after.join('\n\n'),
      // Migration runs on a worker. A timed-out coarse replacement would make
      // every old bookmark land at one boundary, so finish the real mapping.
      timeout: 0,
    );
    return ReaderCoordinateMap(
      List.unmodifiable(before.map((p) => p.length)),
      List.unmodifiable([
        for (final e in differences) [e.operation, e.text.length],
      ]),
      sourceRevision: sourceRevision,
      previous: previous,
    );
  }

  Map<String, Object> toJson() => {
    'lengths': oldLengths,
    'ops': operations,
    if (sourceRevision.isNotEmpty) 'from': sourceRevision,
    if (previous != null) 'previous': previous!.toJson(),
  };
  factory ReaderCoordinateMap.fromJson(
    Object? raw,
    int targetLength, [
    int depth = 0,
  ]) {
    if (depth > 8 ||
        raw is! Map ||
        raw['lengths'] is! List ||
        raw['ops'] is! List ||
        raw['from'] != null && raw['from'] is! String) {
      throw const FormatException('旧版阅读定位数据有误');
    }
    final lengths = (raw['lengths'] as List).cast<int>();
    final ops = <List<int>>[];
    if (lengths.isEmpty ||
        lengths.any((n) => n < 0) ||
        lengths.length > 100000) {
      throw const FormatException('旧版段落定位数据有误');
    }
    var old = 0, next = 0;
    for (final entry in raw['ops']) {
      if (entry is! List ||
          entry.length != 2 ||
          entry[0] is! int ||
          ![-1, 0, 1].contains(entry[0]) ||
          entry[1] is! int ||
          entry[1] < 0) {
        throw const FormatException('旧版阅读定位数据有误');
      }
      if (entry[0] != 1) old += entry[1] as int;
      if (entry[0] != -1) next += entry[1] as int;
      ops.add(List<int>.from(entry));
    }
    if (old !=
            lengths.fold<int>(0, (a, b) => a + b) + (lengths.length - 1) * 2 ||
        next != targetLength) {
      throw const FormatException('原书与定位数据不一致');
    }
    return ReaderCoordinateMap(
      List.unmodifiable(lengths),
      List.unmodifiable(ops),
      sourceRevision: raw['from'] as String? ?? '',
      previous: raw['previous'] == null
          ? null
          : ReaderCoordinateMap.fromJson(raw['previous'], old, depth + 1),
    );
  }
  ({int paragraph, int offset, double fraction}) resolve({
    required List<String> paragraphs,
    int? paragraph,
    int? offset,
    double paragraphFraction = 0,
    double fraction = 0,
    String revision = '',
  }) {
    final origin = sourceRevision == revision || previous == null
        ? this
        : previous!._origin(revision);
    final oldTotal =
        origin.oldLengths.fold<int>(0, (a, b) => a + b) +
        (origin.oldLengths.length - 1) * 2;
    var target = (fraction.clamp(0, 1) * oldTotal).round();
    if (paragraph != null &&
        paragraph >= 0 &&
        paragraph < origin.oldLengths.length) {
      target =
          origin.oldLengths.take(paragraph).fold<int>(0, (a, b) => a + b + 2) +
          (offset ??
                  (paragraphFraction.clamp(0, 1) * origin.oldLengths[paragraph])
                      .round())
              .clamp(0, origin.oldLengths[paragraph]);
    }
    final mapped = _fromRevision(target, revision);
    var start = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      final length = paragraphs[i].length;
      if (mapped <= start + length || i == paragraphs.length - 1) {
        final at = (mapped - start).clamp(0, length);
        return (
          paragraph: i,
          offset: at,
          fraction: length == 0 ? 0 : at / length,
        );
      }
      start += length + 2;
    }
    return (paragraph: 0, offset: 0, fraction: 0);
  }

  ReaderCoordinateMap _origin(String revision) =>
      sourceRevision == revision || previous == null
      ? this
      : previous!._origin(revision);
  int _fromRevision(int target, String revision) {
    if (sourceRevision != revision && previous != null) {
      target = previous!._fromRevision(target, revision);
    }
    var old = 0, next = 0;
    for (final op in operations) {
      if (op[0] == 1) {
        next += op[1];
        continue;
      }
      if (target < old + op[1]) {
        return next + (op[0] == 0 ? target - old : 0);
      }
      old += op[1];
      if (op[0] == 0) next += op[1];
    }
    return next;
  }
}
