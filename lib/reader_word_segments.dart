import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'reader_chinese_segments.dart';

/// Chinese words use bundled offline segmentation; other scripts use system
/// boundaries. Character mode always preserves full graphemes.
enum ReaderTextUnit { word, character }

typedef ReaderTextSegmentProvider =
    Future<List<TextRange>> Function(String text, {Locale? locale});

/// Default provider hook; the picker also accepts an explicit offline provider.
Future<List<TextRange>> readerTextWordSegments(
  String text, {
  Locale? locale,
  ReaderChineseSegmenter? chinese,
}) async {
  final system = readerTextUnitRanges(text, locale: locale);
  if (text.length > 4096 || _kana.hasMatch(text)) return system;
  final runs = <TextRange>[];
  var offset = 0, start = -1;
  for (final grapheme in text.characters) {
    final han = grapheme.length == 1 && _han.hasMatch(grapheme);
    if (han && start < 0) start = offset;
    if (!han && start >= 0) {
      runs.add(TextRange(start: start, end: offset));
      start = -1;
    }
    offset += grapheme.length;
  }
  if (start >= 0) runs.add(TextRange(start: start, end: offset));
  if (runs.isEmpty) return system;
  final words = await (chinese ?? ReaderChineseSegmenter.shared).cut(
    runs.map((range) => text.substring(range.start, range.end)).toList(),
  );
  final result = system
      .where(
        (range) =>
            !runs.any((run) => range.start < run.end && range.end > run.start),
      )
      .toList();
  for (var index = 0; index < runs.length; index++) {
    var cursor = runs[index].start;
    if (words[index].join() !=
        text.substring(runs[index].start, runs[index].end)) {
      throw const FormatException('离线分词结果与原文不一致，请按字选择');
    }
    for (final word in words[index]) {
      if (word.isNotEmpty) {
        result.add(TextRange(start: cursor, end: cursor + word.length));
      }
      cursor += word.length;
    }
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

final _han = RegExp(r'^[\u3400-\u9fff]$');
final _kana = RegExp(r'[\u3040-\u30ff\u31f0-\u31ff]');

/// The core owns each token once; the small context preserves edge word breaks.
class ReaderTextChunk {
  const ReaderTextChunk(this.core, this.context);
  final TextRange core, context;
}

/// Only chunk geometry crosses the preprocessing isolate, never widgets or UI.
class ReaderTextPickerDocument {
  const ReaderTextPickerDocument(this.chunks, this.initialRange);
  final List<ReaderTextChunk> chunks;
  final TextRange? initialRange;
  int chunkForOffset(int offset) {
    var low = 0, high = chunks.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (chunks[mid].core.end <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low.clamp(0, chunks.isEmpty ? 0 : chunks.length - 1);
  }
}

/// Pure-Dart preprocessing, suitable for compute() on long paragraph selections.
ReaderTextPickerDocument prepareReaderTextPicker((String, TextRange?) input) {
  final (text, initial) = input;
  if (text.length > 1024 * 1024) {
    throw const FormatException('这次选中的文字过长，请先缩小到需要的段落');
  }
  final boundaries = <int>[0];
  var offset = 0;
  for (final character in text.characters) {
    if (character.length > 4096) {
      throw const FormatException('单个组合字符过长，请缩小选区后重试');
    }
    offset += character.length;
    boundaries.add(offset);
  }
  final cores = <TextRange>[];
  var start = 0;
  for (var index = 1; index < boundaries.length; index++) {
    final end = boundaries[index];
    if (end - start >= 96 || end == text.length) {
      cores.add(TextRange(start: start, end: end));
      start = end;
    }
  }
  final chunks = <ReaderTextChunk>[];
  for (final core in cores) {
    chunks.add(
      ReaderTextChunk(
        core,
        TextRange(
          start: _floorBoundary(
            boundaries,
            (core.start - 32).clamp(0, text.length),
          ),
          end: _ceilBoundary(boundaries, (core.end + 32).clamp(0, text.length)),
        ),
      ),
    );
  }
  TextRange? normalized;
  if (initial != null &&
      initial.isValid &&
      !initial.isCollapsed &&
      text.isNotEmpty) {
    final start = initial.start.clamp(0, text.length),
        end = initial.end.clamp(0, text.length);
    if (end > start) {
      normalized = TextRange(
        start: _floorBoundary(boundaries, start),
        end: _ceilBoundary(boundaries, end),
      );
    }
  }
  return ReaderTextPickerDocument(List.unmodifiable(chunks), normalized);
}

/// Produces exact UTF-16 ranges for one bounded text window. Punctuation and
/// whitespace are not words; character mode still permits punctuation endpoints.
List<TextRange> readerTextUnitRanges(
  String text, {
  ReaderTextUnit unit = ReaderTextUnit.word,
  Locale? locale,
}) {
  if (text.isEmpty) return const [];
  final boundaries = <int>[0];
  var offset = 0;
  for (final character in text.characters) {
    offset += character.length;
    boundaries.add(offset);
  }
  final characters = <TextRange>[
    for (var index = 0; index + 1 < boundaries.length; index++)
      if (text
          .substring(boundaries[index], boundaries[index + 1])
          .trim()
          .isNotEmpty)
        TextRange(start: boundaries[index], end: boundaries[index + 1]),
  ];
  // An unusually large single grapheme must not force a giant native layout.
  if (unit == ReaderTextUnit.character || text.length > 4096) return characters;
  final painter = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontSize: 14)),
    textDirection: TextDirection.ltr,
    locale: locale,
  );
  try {
    painter.layout();
    final result = <TextRange>[];
    var cursor = 0;
    while (cursor < text.length) {
      final word = painter.getWordBoundary(TextPosition(offset: cursor));
      final end = _ceilBoundary(
        boundaries,
        word.end > cursor ? word.end : cursor + 1,
      );
      final start = _floorBoundary(
        boundaries,
        word.start.clamp(cursor, text.length),
      );
      final value = text.substring(start, end);
      if (_wordContent.hasMatch(value) || _hasEmoji(value)) {
        result.add(TextRange(start: start, end: end));
      }
      cursor = end;
    }
    return result;
  } finally {
    painter.dispose();
  }
}

/// Returns null for a sentence/paragraph, without laying out a large selection.
TextRange? readerSingleLookupRange(String text) {
  if (text.length > 512) return null;
  final ranges = readerTextUnitRanges(text);
  if (ranges.length != 1) return null;
  final range = ranges.single;
  if (text.substring(0, range.start).trim().isNotEmpty ||
      text.substring(range.end).trim().isNotEmpty ||
      text.substring(range.start, range.end).runes.take(129).length > 128) {
    return null;
  }
  return range;
}

final _wordContent = RegExp(r'[\p{L}\p{N}]', unicode: true);
bool _hasEmoji(String text) => text.runes.any(
  (rune) =>
      rune >= 0x1f000 && rune <= 0x1faff || rune >= 0x2600 && rune <= 0x27ff,
);

int _floorBoundary(List<int> values, int target) {
  var low = 0, high = values.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (values[mid] <= target) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return values[(low - 1).clamp(0, values.length - 1)];
}

int _ceilBoundary(List<int> values, int target) {
  var low = 0, high = values.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (values[mid] < target) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return values[low.clamp(0, values.length - 1)];
}
