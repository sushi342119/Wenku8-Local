import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart' show TextRange;

import 'catalog.dart';
import 'reader_content.dart';
import 'reader_underline.dart';
import 'library_state.dart' show ReadingPosition;

/// A caller supplies the same loaded display content used by its reader.
class ReaderAnnotationChapterSource {
  const ReaderAnnotationChapterSource({
    required this.chapterId,
    required this.title,
    required this.content,
  });
  final int chapterId;
  final String title;
  final ReaderContent content;
}

/// Loading context is optional and lazy: it never gates editing personal notes.
typedef ReaderAnnotationContextResolver =
    Future<ReaderAnnotationContext?> Function(
      List<ReaderUnderlineRange> ranges,
      ReadingPosition anchor,
    );

/// Exact book/chapter/paragraph identity accompanies every displayed character.
class ReaderAnnotationContext {
  ReaderAnnotationContext({
    required this.novelId,
    required List<ReaderAnnotationChapterSource> chapters,
    this.novel,
  }) : chapters = List.unmodifiable(chapters) {
    if (novelId <= 0 ||
        novel != null && novel!.id != novelId ||
        chapters.map((source) => source.chapterId).toSet().length !=
            chapters.length) {
      throw const FormatException('原文上下文与书籍不一致');
    }
  }

  final int novelId;
  final Novel? novel;
  final List<ReaderAnnotationChapterSource> chapters;
  ReaderAnnotationChapterSource _source(int id) =>
      chapters.where((s) => s.chapterId == id).firstOrNull ??
      (throw const FormatException('这部分原文尚未载入，批注仍可正常编辑'));

  /// Migrates endpoints through an explicit coordinate map, never quote search.
  List<ReaderUnderlineRange> normalize(List<ReaderUnderlineRange> ranges) => [
    for (final range in ranges) _normalize(range),
  ];

  /// Gives a position bookmark its exact paragraph without searching its quote.
  /// Source access is needed only when a visible text treatment is requested.
  ReaderAnnotationRangeChange paragraphAt(ReadingPosition anchor) {
    final source = _source(anchor.chapterId).content;
    var paragraph = anchor.paragraphIndex;
    if (paragraph == null) {
      throw const FormatException('这个位置没有精确段落坐标，请先在阅读器选择原文');
    }
    if (anchor.contentRevision != source.revision) {
      final map = source.coordinateMap;
      if (map != null && map.accepts(anchor.contentRevision)) {
        paragraph = map
            .resolve(
              paragraphs: source.paragraphs,
              paragraph: paragraph,
              offset: anchor.textOffset ?? 0,
              revision: anchor.contentRevision,
            )
            .paragraph;
      } else if (anchor.contentRevision.isNotEmpty || map != null) {
        throw const FormatException('原文版本已变化，请重新选择原文，批注仍可编辑');
      }
    }
    if (paragraph < 0 ||
        paragraph >= source.paragraphs.length ||
        !source.order.contains(paragraph)) {
      throw const FormatException('这段原文不可用或已隐藏，批注仍可编辑');
    }
    final text = source.paragraphs[paragraph];
    if (text.isEmpty || readerIllustrationUrl(text) != null) {
      throw const FormatException('这个位置不是文字段落，请先选择原文');
    }
    final range = ReaderUnderlineRange(
      chapterId: anchor.chapterId,
      startParagraph: paragraph,
      startOffset: 0,
      endParagraph: paragraph,
      endOffset: text.length,
      contentRevision: source.revision,
    );
    // The source range stays complete; only the list excerpt is bounded.
    return ReaderAnnotationRangeChange._(
      novelId,
      List.unmodifiable([range]),
      text.substring(0, _floorBoundary(text, math.min(12000, text.length))),
    );
  }

  ReaderUnderlineRange _normalize(ReaderUnderlineRange range) {
    final source = _source(range.chapterId).content;
    var result = range;
    if (range.contentRevision != source.revision) {
      final map = source.coordinateMap;
      if (map != null && map.accepts(range.contentRevision)) {
        final start = map.resolve(
          paragraphs: source.paragraphs,
          paragraph: range.startParagraph,
          offset: range.startOffset,
          revision: range.contentRevision,
        );
        final end = map.resolve(
          paragraphs: source.paragraphs,
          paragraph: range.endParagraph,
          offset: range.endOffset,
          revision: range.contentRevision,
        );
        result = ReaderUnderlineRange(
          chapterId: range.chapterId,
          startParagraph: start.paragraph,
          startOffset: start.offset,
          endParagraph: end.paragraph,
          endOffset: end.offset,
          contentRevision: source.revision,
        );
      } else if (range.contentRevision.isEmpty &&
          source.coordinateMap == null) {
        // Old plain-text marks used the same paragraph coordinates without a tag.
        result = range.withRevision(source.revision);
      } else {
        throw const FormatException('原文版本已变化，请在阅读器重新选取范围');
      }
    }
    if (!result.isValid ||
        result.endParagraph >= source.paragraphs.length ||
        result.startOffset > source.paragraphs[result.startParagraph].length ||
        result.endOffset > source.paragraphs[result.endParagraph].length) {
      throw const FormatException('原文位置已变化，批注仍保留，请重新选择');
    }
    return result;
  }

  /// A multi-fragment mark edits one explicit fragment; the others stay intact.
  ReaderAnnotationProjection project({
    required List<ReaderUnderlineRange> ranges,
    required ReadingPosition anchor,
    int component = 0,
  }) {
    final normalized = normalize(ranges);
    if (component < 0 ||
        normalized.isNotEmpty && component >= normalized.length) {
      throw const FormatException('请先选择要调整的片段');
    }
    final selected = normalized.isEmpty ? null : normalized[component];
    final id = selected?.chapterId ?? anchor.chapterId;
    final source = _source(id);
    final paragraph = selected?.startParagraph ?? anchor.paragraphIndex;
    if (paragraph == null ||
        paragraph < 0 ||
        paragraph >= source.content.paragraphs.length) {
      throw const FormatException('这个位置书签没有精确文字坐标，请先在阅读器选中文字');
    }
    final start = selected?.startOffset ?? anchor.textOffset ?? 0;
    if (start > source.content.paragraphs[paragraph].length) {
      throw const FormatException('原文位置已变化，请在阅读器重新选择');
    }
    final active = <_SourcePiece>[];
    final ordered =
        <({ReaderAnnotationChapterSource chapter, int paragraph})>[];
    final chapterOrder = novel == null
        ? chapters
        : [
            for (final chapter in novel!.chapters)
              ...chapters.where((source) => source.chapterId == chapter.id),
          ];
    for (final chapter in chapterOrder) {
      for (final p in chapter.content.order) {
        final text = chapter.content.paragraphs[p];
        if (readerIllustrationUrl(text) == null && text.isNotEmpty) {
          ordered.add((chapter: chapter, paragraph: p));
        }
      }
    }
    for (final item in ordered) {
      if (item.chapter.chapterId != id) continue;
      final p = item.paragraph, text = item.chapter.content.paragraphs[p];
      if (selected == null) {
        if (p == paragraph) {
          active.add(_SourcePiece(item.chapter, p, start, start));
        }
      } else if (p >= selected.startParagraph && p <= selected.endParagraph) {
        final lo = p == selected.startParagraph ? selected.startOffset : 0;
        final hi = p == selected.endParagraph
            ? selected.endOffset
            : text.length;
        if (hi > lo) active.add(_SourcePiece(item.chapter, p, lo, hi));
      }
    }
    if (active.isEmpty) {
      throw const FormatException('这段原文当前被隐藏或不是文字，请先显示原文再调整');
    }
    List<_SourcePiece> pieces(int margin) => [
      for (final piece in active) piece.expanded(margin),
    ];
    var visible = pieces(256);
    if (visible.fold<int>(0, (sum, piece) => sum + piece.length) > 24000) {
      visible = pieces(0);
    }
    if (visible.fold<int>(0, (sum, piece) => sum + piece.length) > 24000) {
      throw const FormatException('这段选区过长，请在阅读器分段调整');
    }
    final first = ordered.indexWhere(
      (p) =>
          p.chapter.chapterId == active.first.chapter.chapterId &&
          p.paragraph == active.first.paragraph,
    );
    final last = ordered.indexWhere(
      (p) =>
          p.chapter.chapterId == active.last.chapter.chapterId &&
          p.paragraph == active.last.paragraph,
    );
    if (first > 0) {
      final item = ordered[first - 1],
          text = ordered[first - 1]
              .chapter
              .content
              .paragraphs[ordered[first - 1].paragraph];
      visible.insert(
        0,
        _SourcePiece(
          item.chapter,
          item.paragraph,
          _floorBoundary(text, math.max(0, text.length - 256)),
          text.length,
        ),
      );
    }
    if (last + 1 < ordered.length) {
      final item = ordered[last + 1],
          text = ordered[last + 1]
              .chapter
              .content
              .paragraphs[ordered[last + 1].paragraph];
      visible.add(
        _SourcePiece(
          item.chapter,
          item.paragraph,
          0,
          _ceilBoundary(text, math.min(256, text.length)),
        ),
      );
    }
    return ReaderAnnotationProjection._(
      this,
      normalized,
      component,
      selected,
      visible,
    );
  }

  String _quote(List<ReaderUnderlineRange> ranges) {
    final parts = <String>[];
    var size = 0;
    for (final range in ranges) {
      final source = _source(range.chapterId).content;
      for (var p = range.startParagraph; p <= range.endParagraph; p++) {
        final text = source.paragraphs[p];
        if (readerIllustrationUrl(text) != null) continue;
        final start = p == range.startParagraph ? range.startOffset : 0;
        final end = p == range.endParagraph ? range.endOffset : text.length;
        if (end <= start) continue;
        final part = text.substring(start, end);
        size += part.length + (parts.isEmpty ? 0 : 2);
        if (size > 12000) throw const FormatException('摘录过长，请选择不超过 12000 字的内容');
        parts.add(part);
      }
    }
    return parts.join('\n\n');
  }
}

/// Only this mapped result can be offered as a bookmark geometry replacement.
class ReaderAnnotationRangeChange {
  const ReaderAnnotationRangeChange._(this.novelId, this.ranges, this.quote);
  final int novelId;
  final List<ReaderUnderlineRange> ranges;
  final String quote;
}

/// Maps a bounded visible-text window back to source ranges. Separators and
/// hidden paragraphs have no selectable source mapping and cannot be guessed.
class ReaderAnnotationProjection {
  ReaderAnnotationProjection._(
    this.context,
    this.originalRanges,
    this.component,
    this.selectedRange,
    List<_SourcePiece> pieces,
  ) {
    final text = StringBuffer();
    final mapped = <ReaderAnnotationTextSegment>[];
    for (final piece in pieces) {
      if (piece.length <= 0) continue;
      if (text.isNotEmpty) text.write('\n\n');
      final start = text.length;
      text.write(piece.text);
      mapped.add(ReaderAnnotationTextSegment._(piece, start, text.length));
    }
    this.text = text.toString();
    segments = List.unmodifiable(mapped);
    final selected = <TextRange>[];
    final range = selectedRange;
    if (range != null) {
      for (final segment in segments) {
        final piece = segment._piece;
        if (piece.chapter.chapterId != range.chapterId ||
            piece.paragraph < range.startParagraph ||
            piece.paragraph > range.endParagraph) {
          continue;
        }
        final lo = math.max(
          piece.start,
          piece.paragraph == range.startParagraph ? range.startOffset : 0,
        );
        final hi = math.min(
          piece.end,
          piece.paragraph == range.endParagraph ? range.endOffset : piece.end,
        );
        if (hi > lo) {
          selected.add(
            TextRange(
              start: segment.start + lo - piece.start,
              end: segment.start + hi - piece.start,
            ),
          );
        }
      }
    }
    initialRange = selected.isEmpty
        ? null
        : TextRange(start: selected.first.start, end: selected.last.end);
  }

  final ReaderAnnotationContext context;
  final List<ReaderUnderlineRange> originalRanges;
  final int component;
  final ReaderUnderlineRange? selectedRange;
  late final String text;
  late final List<ReaderAnnotationTextSegment> segments;
  late final TextRange? initialRange;
  String get scopeLabel => '所选片段与相邻段落；隐藏文字和其他片段保持不变';

  /// Replaces only mapped source text; unseen old portions are preserved.
  ReaderAnnotationRangeChange apply(TextRange selection) {
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.end > text.length) {
      throw const FormatException('请选择需要标记的原文');
    }
    final picked = <ReaderUnderlineRange>[];
    final coverage = <ReaderUnderlineRange>[];
    for (final segment in segments) {
      final piece = segment._piece;
      coverage.add(piece.range(piece.start, piece.end));
      final lo = math.max(selection.start, segment.start),
          hi = math.min(selection.end, segment.end);
      if (hi <= lo) continue;
      final start = piece.start + lo - segment.start,
          end = piece.start + hi - segment.start;
      final source = piece.chapter.content.paragraphs[piece.paragraph];
      if (_floorBoundary(source, start) != start ||
          _ceilBoundary(source, end) != end) {
        throw const FormatException('请选择完整的文字或表情');
      }
      picked.add(piece.range(start, end));
    }
    if (picked.isEmpty) throw const FormatException('段落分隔不属于原文选区，请选择文字');
    var preserved = selectedRange == null
        ? <ReaderUnderlineRange>[]
        : [selectedRange!];
    for (final cut in coverage) {
      preserved = [for (final part in preserved) ..._subtract(part, cut)];
    }
    preserved = preserved
        .where((range) => context._quote([range]).isNotEmpty)
        .toList();
    final ranges = canonicalReaderUnderlineRanges(
      [
        for (final (index, range) in originalRanges.indexed)
          if (index != component) range,
        ...preserved,
        ...picked,
      ],
      chapterOrder:
          context.novel?.chapters.map((c) => c.id) ??
          context.chapters.map((c) => c.chapterId),
    );
    return ReaderAnnotationRangeChange._(
      context.novelId,
      ranges,
      context._quote(ranges),
    );
  }
}

/// Inspectable UTF-16 projection segment; neither prose search nor title matching
/// participates in its conversion back to the original chapter.
class ReaderAnnotationTextSegment {
  const ReaderAnnotationTextSegment._(this._piece, this.start, this.end);
  final _SourcePiece _piece;
  final int start, end;
  int get chapterId => _piece.chapter.chapterId;
  int get paragraph => _piece.paragraph;
  int get sourceStart => _piece.start;
  int get sourceEnd => _piece.end;
}

class _SourcePiece {
  const _SourcePiece(this.chapter, this.paragraph, this.start, this.end);
  final ReaderAnnotationChapterSource chapter;
  final int paragraph, start, end;
  int get length => end - start;
  String get text =>
      chapter.content.paragraphs[paragraph].substring(start, end);
  _SourcePiece expanded(int margin) {
    final text = chapter.content.paragraphs[paragraph];
    return _SourcePiece(
      chapter,
      paragraph,
      _floorBoundary(text, math.max(0, start - margin)),
      _ceilBoundary(text, math.min(text.length, end + margin)),
    );
  }

  ReaderUnderlineRange range(int lower, int upper) => ReaderUnderlineRange(
    chapterId: chapter.chapterId,
    startParagraph: paragraph,
    startOffset: lower,
    endParagraph: paragraph,
    endOffset: upper,
    contentRevision: chapter.content.revision,
  );
}

int _floorBoundary(String text, int offset) {
  var at = 0;
  for (final character in text.characters) {
    final next = at + character.length;
    if (next > offset) return at;
    at = next;
  }
  return text.length;
}

int _ceilBoundary(String text, int offset) {
  var at = 0;
  for (final character in text.characters) {
    if (at >= offset) return at;
    at += character.length;
  }
  return text.length;
}

int _point(int paragraph, int offset, int otherParagraph, int otherOffset) =>
    paragraph == otherParagraph
    ? offset.compareTo(otherOffset)
    : paragraph.compareTo(otherParagraph);

List<ReaderUnderlineRange> _subtract(
  ReaderUnderlineRange part,
  ReaderUnderlineRange cut,
) {
  if (part.chapterId != cut.chapterId ||
      _point(
            part.endParagraph,
            part.endOffset,
            cut.startParagraph,
            cut.startOffset,
          ) <=
          0 ||
      _point(
            cut.endParagraph,
            cut.endOffset,
            part.startParagraph,
            part.startOffset,
          ) <=
          0) {
    return [part];
  }
  return [
    if (_point(
          part.startParagraph,
          part.startOffset,
          cut.startParagraph,
          cut.startOffset,
        ) <
        0)
      ReaderUnderlineRange(
        chapterId: part.chapterId,
        startParagraph: part.startParagraph,
        startOffset: part.startOffset,
        endParagraph: cut.startParagraph,
        endOffset: cut.startOffset,
        contentRevision: part.contentRevision,
      ),
    if (_point(
          cut.endParagraph,
          cut.endOffset,
          part.endParagraph,
          part.endOffset,
        ) <
        0)
      ReaderUnderlineRange(
        chapterId: part.chapterId,
        startParagraph: cut.endParagraph,
        startOffset: cut.endOffset,
        endParagraph: part.endParagraph,
        endOffset: part.endOffset,
        contentRevision: part.contentRevision,
      ),
  ];
}
