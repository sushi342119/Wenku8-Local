/// Rendering treatment for a saved exact-text bookmark.
enum ReaderMarkStyle {
  underline('划线'),
  highlight('高亮'),
  outline('边框'),
  none('无样式');

  const ReaderMarkStyle(this.label);
  final String label;
}

/// A small shared palette; ink follows the reader's current paper contrast.
enum ReaderMarkColor {
  ink('原色', null),
  amber('琥珀', 0xFFC69A32),
  mint('薄荷', 0xFF4A9C83),
  blue('湖蓝', 0xFF5289BB),
  rose('蔷薇', 0xFFC87386),
  violet('紫藤', 0xFF9773B7);

  const ReaderMarkColor(this.label, this.argb);
  final String label;
  final int? argb;
}

/// Editable metadata lives in the same per-book record as its source anchor.
class ReaderAnnotationData {
  const ReaderAnnotationData({
    this.style = ReaderMarkStyle.underline,
    this.color = ReaderMarkColor.ink,
    this.note = '',
    this.updatedAt = 0,
  });

  static const maxNoteLength = 100000;
  final ReaderMarkStyle style;
  final ReaderMarkColor color;
  final String note;
  final int updatedAt;
  bool get isEmpty =>
      (style == ReaderMarkStyle.underline || style == ReaderMarkStyle.none) &&
      color == ReaderMarkColor.ink &&
      note.isEmpty &&
      updatedAt == 0;

  ReaderAnnotationData at(int value) => ReaderAnnotationData(
    style: style,
    color: color,
    note: note,
    updatedAt: value,
  );

  Map<String, Object> toJson() => {
    'style': style.name,
    'color': color.name,
    if (note.isNotEmpty) 'note': note,
    'updatedAt': updatedAt,
  };

  factory ReaderAnnotationData.fromJson(Object? raw) {
    if (raw == null) return const ReaderAnnotationData();
    if (raw is! Map ||
        raw['style'] is! String ||
        raw['color'] is! String ||
        (raw['note'] != null && raw['note'] is! String) ||
        (raw['note'] as String? ?? '').length > maxNoteLength ||
        raw['updatedAt'] is! int ||
        raw['updatedAt'] < 0 ||
        raw['updatedAt'] > 1000000000000000) {
      throw const FormatException('批注格式有误');
    }
    final style = ReaderMarkStyle.values
        .where((value) => value.name == raw['style'])
        .firstOrNull;
    final color = ReaderMarkColor.values
        .where((value) => value.name == raw['color'])
        .firstOrNull;
    if (style == null || color == null) {
      throw const FormatException('标记样式或颜色无效');
    }
    return ReaderAnnotationData(
      style: style,
      color: color,
      note: raw['note'] as String? ?? '',
      updatedAt: raw['updatedAt'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderAnnotationData &&
      style == other.style &&
      color == other.color &&
      note == other.note &&
      updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(style, color, note, updatedAt);
}

/// One indexed source range with its appearance, without font/layout state.
class ReaderAnnotationRange {
  const ReaderAnnotationRange(this.range, this.style, this.color);
  final ReaderUnderlineRange range;
  final ReaderMarkStyle style;
  final ReaderMarkColor color;

  @override
  bool operator ==(Object other) =>
      other is ReaderAnnotationRange &&
      range == other.range &&
      style == other.style &&
      color == other.color;
  @override
  int get hashCode => Object.hash(range, style, color);
}

/// A saved range clipped to the currently materialized paragraph fragment.
class ReaderTextMark {
  const ReaderTextMark(this.start, this.end, this.style, this.color);
  final int start, end;
  final ReaderMarkStyle style;
  final ReaderMarkColor color;
}

/// An underline in original paragraph coordinates, independent of pagination.
///
/// UTF-16 offsets are end-exclusive. Several ranges may share a chapter so a
/// selection that skips hidden text never underlines the skipped source text.
class ReaderUnderlineRange {
  const ReaderUnderlineRange({
    required this.chapterId,
    required this.startParagraph,
    required this.startOffset,
    required this.endParagraph,
    required this.endOffset,
    this.contentRevision = '',
  });

  final int chapterId;
  final int startParagraph;
  final int startOffset;
  final int endParagraph;
  final int endOffset;

  /// Coordinate-format revision for this chapter, including mixed-book series.
  final String contentRevision;

  bool get isValid =>
      chapterId > 0 &&
      chapterId <= 0x7fffffff &&
      startParagraph >= 0 &&
      endParagraph <= 1000000 &&
      startOffset >= 0 &&
      startOffset <= 100000000 &&
      endOffset >= 0 &&
      endOffset <= 100000000 &&
      (startParagraph < endParagraph ||
          startParagraph == endParagraph && startOffset < endOffset);

  /// Maps only chapter identity when combining volumes; text is not rewritten.
  ReaderUnderlineRange inChapter(int id) => ReaderUnderlineRange(
    chapterId: id,
    startParagraph: startParagraph,
    startOffset: startOffset,
    endParagraph: endParagraph,
    endOffset: endOffset,
    contentRevision: contentRevision,
  );

  /// Retains the source range while a coordinate migration updates its format.
  ReaderUnderlineRange withRevision(String revision) => ReaderUnderlineRange(
    chapterId: chapterId,
    startParagraph: startParagraph,
    startOffset: startOffset,
    endParagraph: endParagraph,
    endOffset: endOffset,
    contentRevision: revision,
  );

  Map<String, Object> toJson() => {
    'chapterId': chapterId,
    'startParagraph': startParagraph,
    'startOffset': startOffset,
    'endParagraph': endParagraph,
    'endOffset': endOffset,
    if (contentRevision.isNotEmpty) 'contentRevision': contentRevision,
  };

  factory ReaderUnderlineRange.fromJson(Object? raw) {
    final revision = raw is Map<Object?, Object?>
        ? raw['contentRevision']
        : null;
    if (revision != null && revision is! String) {
      throw const FormatException('划线坐标版本格式有误');
    }
    if (raw case {
      'chapterId': final int chapterId,
      'startParagraph': final int startParagraph,
      'startOffset': final int startOffset,
      'endParagraph': final int endParagraph,
      'endOffset': final int endOffset,
    }) {
      final range = ReaderUnderlineRange(
        chapterId: chapterId,
        startParagraph: startParagraph,
        startOffset: startOffset,
        endParagraph: endParagraph,
        endOffset: endOffset,
        contentRevision: revision as String? ?? '',
      );
      if (range.isValid) return range;
    }
    throw const FormatException('划线位置格式有误');
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderUnderlineRange &&
      chapterId == other.chapterId &&
      startParagraph == other.startParagraph &&
      startOffset == other.startOffset &&
      endParagraph == other.endParagraph &&
      endOffset == other.endOffset &&
      contentRevision == other.contentRevision;

  @override
  int get hashCode => Object.hash(
    chapterId,
    startParagraph,
    startOffset,
    endParagraph,
    endOffset,
    contentRevision,
  );
}

/// Validates stored annotation ranges without importing application state.
List<ReaderUnderlineRange> decodeReaderUnderlineRanges(
  Object? raw, {
  Map<Object?, Object?>? position,
}) {
  if (raw == null) return const [];
  if (raw is! List || raw.isEmpty || raw.length > 1000) {
    throw const FormatException('划线位置数量或格式有误');
  }
  final ranges = List<ReaderUnderlineRange>.unmodifiable(
    raw.map(ReaderUnderlineRange.fromJson),
  );
  if (!_consistentRevisions(ranges)) {
    throw const FormatException('同一章节的划线坐标版本不一致');
  }
  final first = ranges.first;
  if (position != null &&
      (position['chapterId'] != first.chapterId ||
          position['paragraphIndex'] != first.startParagraph ||
          position['textOffset'] != first.startOffset ||
          (position['contentRevision'] ?? '') != first.contentRevision)) {
    throw const FormatException('划线起点与书签位置不一致');
  }
  return ranges;
}

int _comparePoint(int aParagraph, int aOffset, int bParagraph, int bOffset) =>
    aParagraph == bParagraph
    ? aOffset.compareTo(bOffset)
    : aParagraph.compareTo(bParagraph);

bool _consistentRevisions(Iterable<ReaderUnderlineRange> ranges) {
  final revisions = <int, String>{};
  for (final range in ranges) {
    if (revisions.containsKey(range.chapterId) &&
        revisions[range.chapterId] != range.contentRevision) {
      return false;
    }
    revisions[range.chapterId] = range.contentRevision;
  }
  return true;
}

/// Removes duplicate/overlapping fragment boundaries, not unselected gaps.
List<ReaderUnderlineRange> canonicalReaderUnderlineRanges(
  Iterable<ReaderUnderlineRange> ranges, {
  Iterable<int>? chapterOrder,
}) {
  final input = ranges.toList();
  if (input.isEmpty ||
      input.length > 1000 ||
      input.any((r) => !r.isValid) ||
      !_consistentRevisions(input)) {
    throw const FormatException('划线位置数量或格式有误');
  }
  final indices = chapterOrder == null
      ? null
      : {for (final (index, id) in chapterOrder.indexed) id: index};
  input.sort((a, b) {
    final chapter = indices == null
        ? a.chapterId.compareTo(b.chapterId)
        : (indices[a.chapterId] ?? -1).compareTo(indices[b.chapterId] ?? -1);
    if (chapter != 0) return chapter;
    final start = _comparePoint(
      a.startParagraph,
      a.startOffset,
      b.startParagraph,
      b.startOffset,
    );
    return start != 0
        ? start
        : _comparePoint(
            a.endParagraph,
            a.endOffset,
            b.endParagraph,
            b.endOffset,
          );
  });
  final merged = <ReaderUnderlineRange>[];
  for (final range in input) {
    final last = merged.lastOrNull;
    if (last == null ||
        last.chapterId != range.chapterId ||
        last.contentRevision != range.contentRevision ||
        _comparePoint(
              last.endParagraph,
              last.endOffset,
              range.startParagraph,
              range.startOffset,
            ) <
            0) {
      merged.add(range);
      continue;
    }
    if (_comparePoint(
          range.endParagraph,
          range.endOffset,
          last.endParagraph,
          last.endOffset,
        ) >
        0) {
      merged[merged.length - 1] = ReaderUnderlineRange(
        chapterId: last.chapterId,
        startParagraph: last.startParagraph,
        startOffset: last.startOffset,
        endParagraph: range.endParagraph,
        endOffset: range.endOffset,
        contentRevision: last.contentRevision,
      );
    }
  }
  return List.unmodifiable(merged);
}
