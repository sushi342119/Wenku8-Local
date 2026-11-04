import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:characters/characters.dart';
import 'reader_coordinate_map.dart';
import 'reader_block_spacing.dart';
import 'reader_languages.dart';

class ReaderRuby {
  const ReaderRuby(this.start, this.end, this.text);
  final int start, end;
  final String text;
  Map<String, Object> toJson() => {'start': start, 'end': end, 'text': text};
}

class ReaderNoteReference {
  const ReaderNoteReference(this.start, this.end, this.id);
  final int start, end;
  final String id;
  Map<String, Object> toJson() => {'start': start, 'end': end, 'id': id};
}

class ReaderEmphasis {
  const ReaderEmphasis(this.start, this.end, this.mask);
  final int start, end, mask;
  Map<String, int> toJson() => {'start': start, 'end': end, 'mask': mask};
}

/// Paragraph-sized annotation indexes. Plain paragraphs do not need one, and a
/// vertical layout shares this data across its lazily materialized pages.
class ReaderRichParagraphIndex {
  ReaderRichParagraphIndex(ReaderRichParagraph paragraph)
    : _emphasis = _ReaderEmphasisIndex(paragraph.emphasis),
      _ruby = _ReaderRangeIndex([
        for (final ruby in paragraph.ruby)
          (ruby.start, ruby.end, _ReaderRubyParts(ruby)),
      ]),
      _references = _ReaderRangeIndex([
        for (final note in paragraph.references)
          (note.start, note.end, note.id),
      ]);

  final _ReaderEmphasisIndex _emphasis;
  final _ReaderRangeIndex<_ReaderRubyParts> _ruby;
  final _ReaderRangeIndex<String> _references;

  int emphasisAt(int offset) => _emphasis.at(offset);

  String rubyAt(int start, int end) =>
      _ruby.overlapping(start, end).map((ruby) => ruby.part(start, end)).join();

  String? noteAt(int start, int end) =>
      _references.firstOverlapping(start, end);

  @visibleForTesting
  int get debugRangeVisits => _ruby.debugVisits + _references.debugVisits;
  @visibleForTesting
  int get debugEmphasisComparisons => _emphasis.debugComparisons;
}

class _ReaderEmphasisIndex {
  _ReaderEmphasisIndex(List<ReaderEmphasis> runs) {
    final events = <(int, int, int)>[
      for (final run in runs)
        if (run.start < run.end) ...[
          (run.start, run.mask, 1),
          (run.end, run.mask, -1),
        ],
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final active = <int, int>{};
    var i = 0, mask = 0;
    while (i < events.length) {
      final offset = events[i].$1;
      do {
        final (_, flag, change) = events[i++];
        final count = (active[flag] ?? 0) + change;
        if (count == 0) {
          active.remove(flag);
        } else {
          active[flag] = count;
        }
      } while (i < events.length && events[i].$1 == offset);
      // EPUB has three flags (eight possible masks). Count complete masks so
      // ending one overlapping run never clears a flag still used by another.
      var next = 0;
      for (final flag in active.keys) {
        next |= flag;
      }
      if (next != mask) {
        _offsets.add(offset);
        _masks.add(next);
        mask = next;
      }
    }
  }

  final _offsets = <int>[], _masks = <int>[];
  int debugComparisons = 0;

  int at(int offset) {
    var low = 0, high = _offsets.length;
    while (low < high) {
      assert(() {
        debugComparisons++;
        return true;
      }());
      final middle = (low + high) ~/ 2;
      if (_offsets[middle] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? 0 : _masks[low - 1];
  }
}

/// A balanced interval index skips whole subtrees that cannot overlap a glyph.
/// Results retain source order, including overlapping ruby and note references.
class _ReaderRangeIndex<T> {
  _ReaderRangeIndex(List<(int, int, T)> ranges)
    : _ranges =
          [
            for (var i = 0; i < ranges.length; i++)
              (ranges[i].$1, ranges[i].$2, i, ranges[i].$3),
          ]..sort((a, b) {
            final start = a.$1.compareTo(b.$1);
            return start == 0 ? a.$3.compareTo(b.$3) : start;
          }),
      _maxEnd = List.filled(ranges.length, 0),
      _minOrder = List.filled(ranges.length, 0) {
    _measure(0, _ranges.length);
  }

  final List<(int, int, int, T)> _ranges;
  final List<int> _maxEnd, _minOrder;
  int debugVisits = 0;

  (int, int)? _measure(int first, int end) {
    if (first == end) return null;
    final middle = (first + end) ~/ 2;
    var maximum = _ranges[middle].$2;
    var order = _ranges[middle].$3;
    final left = _measure(first, middle);
    final right = _measure(middle + 1, end);
    if (left != null) {
      if (left.$1 > maximum) maximum = left.$1;
      if (left.$2 < order) order = left.$2;
    }
    if (right != null) {
      if (right.$1 > maximum) maximum = right.$1;
      if (right.$2 < order) order = right.$2;
    }
    _maxEnd[middle] = maximum;
    _minOrder[middle] = order;
    return (maximum, order);
  }

  T? firstOverlapping(int start, int end) {
    var bestOrder = _ranges.length;
    T? found;
    void visit(int first, int last) {
      if (first == last) return;
      final middle = (first + last) ~/ 2;
      assert(() {
        debugVisits++;
        return true;
      }());
      if (_maxEnd[middle] <= start || _minOrder[middle] >= bestOrder) return;
      final range = _ranges[middle];
      if (range.$1 < end && range.$2 > start && range.$3 < bestOrder) {
        bestOrder = range.$3;
        found = range.$4;
      }
      // Find the earliest source reference first; overlapping notes do not
      // require collecting or sorting every match just to use the first one.
      final leftOrder = first == middle
          ? _ranges.length
          : _minOrder[(first + middle) ~/ 2];
      final rightOrder = middle + 1 == last || range.$1 >= end
          ? _ranges.length
          : _minOrder[(middle + 1 + last) ~/ 2];
      if (leftOrder <= rightOrder) {
        visit(first, middle);
        if (range.$1 < end) visit(middle + 1, last);
      } else {
        visit(middle + 1, last);
        visit(first, middle);
      }
    }

    visit(0, _ranges.length);
    return found;
  }

  List<T> overlapping(int start, int end) {
    if (_ranges.isEmpty) return const [];
    final found = <(int, int, int, T)>[];
    void visit(int first, int last) {
      if (first == last) return;
      final middle = (first + last) ~/ 2;
      assert(() {
        debugVisits++;
        return true;
      }());
      if (_maxEnd[middle] <= start) return;
      final range = _ranges[middle];
      visit(first, middle);
      if (range.$1 >= end) return;
      if (range.$2 > start) found.add(range);
      visit(middle + 1, last);
    }

    visit(0, _ranges.length);
    if (found.length > 1) found.sort((a, b) => a.$3.compareTo(b.$3));
    return [for (final range in found) range.$4];
  }
}

class _ReaderRubyParts {
  _ReaderRubyParts(this.ruby) : letters = ruby.text.characters.toList();
  final ReaderRuby ruby;
  final List<String> letters;
  String part(int start, int end) =>
      ReaderRichParagraph._rubyPart(ruby, start, end, letters);
}

class ReaderRichParagraph {
  const ReaderRichParagraph({
    this.alignment = '',
    this.writing = '',
    this.rule = false,
    this.ruby = const [],
    this.references = const [],
    this.emphasis = const [],
    this.breakBefore = false,
    this.breakAfter = false,
    this.spacing = const ReaderBlockSpacing(),
    this.language = '',
    this.opacity = 1,
  });
  final String alignment, writing;
  final bool rule;
  final List<ReaderRuby> ruby;
  final List<ReaderNoteReference> references;
  final List<ReaderEmphasis> emphasis;
  final bool breakBefore, breakAfter;
  final ReaderBlockSpacing spacing;
  final String language;
  final double opacity;
  ReaderRichParagraph withReferences(List<ReaderNoteReference> value) =>
      ReaderRichParagraph(
        alignment: alignment,
        writing: writing,
        rule: rule,
        ruby: ruby,
        references: value,
        emphasis: emphasis,
        breakBefore: breakBefore,
        breakAfter: breakAfter,
        spacing: spacing,
        language: language,
        opacity: opacity,
      );
  ReaderRichParagraph withBreaks({bool before = false, bool after = false}) =>
      ReaderRichParagraph(
        alignment: alignment,
        writing: writing,
        rule: rule,
        ruby: ruby,
        references: references,
        emphasis: emphasis,
        breakBefore: breakBefore || before,
        breakAfter: breakAfter || after,
        spacing: spacing,
        language: language,
        opacity: opacity,
      );
  ReaderRichParagraph withSpacing(ReaderBlockSpacing value) =>
      ReaderRichParagraph(
        alignment: alignment,
        writing: writing,
        rule: rule,
        ruby: ruby,
        references: references,
        emphasis: emphasis,
        breakBefore: breakBefore,
        breakAfter: breakAfter,
        spacing: spacing.merge(value),
        language: language,
        opacity: opacity,
      );
  ReaderRichParagraph replaceSpacing(ReaderBlockSpacing value) =>
      ReaderRichParagraph(
        alignment: alignment,
        writing: writing,
        rule: rule,
        ruby: ruby,
        references: references,
        emphasis: emphasis,
        breakBefore: breakBefore,
        breakAfter: breakAfter,
        spacing: value,
        language: language,
        opacity: opacity,
      );
  ReaderRichParagraph withPublisherLanguage(ReaderRichParagraph value) =>
      ReaderRichParagraph(
        alignment: alignment,
        writing: writing,
        rule: rule,
        ruby: ruby,
        references: references,
        emphasis: emphasis,
        breakBefore: breakBefore,
        breakAfter: breakAfter,
        spacing: spacing,
        language: value.language,
        opacity: value.opacity,
      );
  ReaderRichParagraph get withoutSpacing =>
      spacing.empty ? this : replaceSpacing(const ReaderBlockSpacing());
  double gapBefore(
    ReaderRichParagraph? previous, {
    required double font,
    required double lineHeight,
    required double width,
    required double defaultGap,
    bool overrideGap = false,
  }) => spacing.gapBefore(
    previous?.spacing,
    font: font,
    lineHeight: lineHeight,
    width: width,
    defaultGap: defaultGap,
    overrideGap: overrideGap,
  );
  bool get allowsIndent =>
      !const {'center', 'right', 'end'}.contains(alignment);
  bool get empty =>
      alignment.isEmpty &&
      writing.isEmpty &&
      !rule &&
      ruby.isEmpty &&
      references.isEmpty &&
      emphasis.isEmpty &&
      !breakBefore &&
      !breakAfter &&
      spacing.empty &&
      language.isEmpty &&
      opacity == 1;
  int emphasisAt(int offset) {
    var mask = 0;
    for (final run in emphasis) {
      if (run.start <= offset && offset < run.end) mask |= run.mask;
    }
    return mask;
  }

  static TextStyle emphasized(TextStyle base, int mask) => mask == 0
      ? base
      : base.copyWith(
          fontWeight: mask & 1 != 0 ? FontWeight.w700 : base.fontWeight,
          fontStyle: mask & 2 != 0 ? FontStyle.italic : base.fontStyle,
          decoration: mask & 4 != 0
              ? TextDecoration.underline
              : base.decoration,
        );
  List<InlineSpan> spans(String text) {
    if (emphasis.isEmpty) return [TextSpan(text: text)];
    final indexed = _ReaderEmphasisIndex(emphasis);
    final boundaries = <int>{
      0,
      text.length,
      for (final run in emphasis) ...[
        run.start.clamp(0, text.length),
        run.end.clamp(0, text.length),
      ],
    }.toList()..sort();
    return [
      for (var i = 0; i < boundaries.length - 1; i++)
        TextSpan(
          text: text.substring(boundaries[i], boundaries[i + 1]),
          style: emphasized(const TextStyle(), indexed.at(boundaries[i])),
        ),
    ];
  }

  TextAlign textAlign(TextAlign fallback) => switch (alignment) {
    'right' || 'end' => TextAlign.end,
    'center' => TextAlign.center,
    'left' || 'start' => TextAlign.start,
    'justify' => TextAlign.justify,
    _ => fallback,
  };
  TextStyle textStyle(TextStyle original) {
    final ink = opacity == 1 || original.color == null
        ? original
        : original.copyWith(
            color: original.color!.withValues(
              alpha: original.color!.a * opacity,
            ),
          );
    return ruby.isEmpty
        ? ink
        : ink.copyWith(
            // CJK fonts can have taller ink than their nominal font size. Ruby
            // needs real leading above the base, shared by paint and pagination.
            height: (original.height ?? 1.72) < 2.5 ? 2.5 : original.height,
            leadingDistribution: TextLeadingDistribution.proportional,
          );
  }

  Map<String, Object> toJson() => {
    if (language.isNotEmpty) 'lang': language,
    if (opacity != 1) 'opacity': opacity,
    if (alignment.isNotEmpty) 'align': alignment,
    if (writing.isNotEmpty) 'writing': writing,
    if (rule) 'rule': true,
    if (breakBefore) 'breakBefore': true,
    if (breakAfter) 'breakAfter': true,
    if (!spacing.empty) 'spacing': spacing.toJson(),
    if (emphasis.isNotEmpty)
      'emphasis': emphasis.map((r) => r.toJson()).toList(),
    if (ruby.isNotEmpty) 'ruby': ruby.map((r) => r.toJson()).toList(),
    if (references.isNotEmpty)
      'refs': references.map((r) => r.toJson()).toList(),
  };
  ReaderRichParagraph slice(int start, int end) => ReaderRichParagraph(
    alignment: alignment,
    writing: writing,
    language: language,
    opacity: opacity,
    rule: rule,
    breakBefore: breakBefore && start == 0,
    breakAfter: breakAfter,
    spacing: ReaderBlockSpacing(
      before: start == 0 ? spacing.before : const [],
      leading: start == 0 ? spacing.leading : const [],
      after: spacing.after,
      trailing: spacing.trailing,
    ),
    emphasis: [
      for (final r in emphasis)
        if (r.start < end && r.end > start)
          ReaderEmphasis(
            (r.start - start).clamp(0, end - start),
            (r.end - start).clamp(0, end - start),
            r.mask,
          ),
    ],
    ruby: [
      for (final r in ruby)
        if (r.start < end && r.end > start)
          ReaderRuby(
            (r.start - start).clamp(0, end - start),
            (r.end - start).clamp(0, end - start),
            rubyPart(r, start, end),
          ),
    ],
    references: [
      for (final r in references)
        if (r.start < end && r.end > start)
          ReaderNoteReference(
            (r.start - start).clamp(0, end - start),
            (r.end - start).clamp(0, end - start),
            r.id,
          ),
    ],
  );
  static String rubyPart(ReaderRuby ruby, int start, int end) {
    final letters = ruby.text.characters.toList();
    return _rubyPart(ruby, start, end, letters);
  }

  static String _rubyPart(
    ReaderRuby ruby,
    int start,
    int end,
    List<String> letters,
  ) {
    final a =
        (((start - ruby.start).clamp(0, ruby.end - ruby.start)) /
                (ruby.end - ruby.start) *
                letters.length)
            .floor();
    final b =
        (((end - ruby.start).clamp(0, ruby.end - ruby.start)) /
                (ruby.end - ruby.start) *
                letters.length)
            .floor();
    return letters.sublist(a, b).join();
  }

  factory ReaderRichParagraph.fromJson(Map value, int length) {
    bool range(Map r) =>
        r['start'] is int &&
        r['end'] is int &&
        r['start'] >= 0 &&
        r['end'] > r['start'] &&
        r['end'] <= length;
    return ReaderRichParagraph(
      alignment: '${value['align'] ?? ''}',
      writing: '${value['writing'] ?? ''}',
      language: readerLanguageCode('${value['lang'] ?? ''}'),
      opacity:
          value['opacity'] is num &&
              (value['opacity'] as num).isFinite &&
              value['opacity'] >= 0 &&
              value['opacity'] <= 1
          ? (value['opacity'] as num).toDouble()
          : 1,
      rule: value['rule'] == true,
      breakBefore: value['breakBefore'] == true,
      breakAfter: value['breakAfter'] == true,
      spacing: ReaderBlockSpacing.fromJson(value['spacing']),
      emphasis: [
        for (final r
            in value['emphasis'] is List ? value['emphasis'] as List : const [])
          if (r is Map &&
              range(r) &&
              r['mask'] is int &&
              r['mask'] >= 0 &&
              r['mask'] <= 7)
            ReaderEmphasis(r['start'], r['end'], r['mask']),
      ],
      ruby: [
        for (final r
            in value['ruby'] is List ? value['ruby'] as List : const [])
          if (r is Map &&
              range(r) &&
              r['text'] is String &&
              r['text'].length <= 2000)
            ReaderRuby(r['start'], r['end'], r['text']),
      ],
      references: [
        for (final r
            in value['refs'] is List ? value['refs'] as List : const [])
          if (r is Map && range(r) && r['id'] is String)
            ReaderNoteReference(r['start'], r['end'], r['id']),
      ],
    );
  }
}

/// Optional local EPUB metadata. Body coordinates are always plain UTF-16 text;
/// annotations never become copied text, speech, or an extra paragraph.
class ReaderRichBody {
  const ReaderRichBody(
    this.paragraphs, {
    this.formats = const {},
    this.notes = const {},
    this.revision = '',
    this.coordinateMap,
  });
  static const prefix = '<!--reader-rich-v1:';
  final List<String> paragraphs;
  final Map<int, ReaderRichParagraph> formats;
  final Map<String, String> notes;
  final String revision;
  final ReaderCoordinateMap? coordinateMap;
  String encode() {
    if (paragraphs.isEmpty) return '';
    final body = paragraphs.join('\n\n');
    if (formats.isEmpty &&
        notes.isEmpty &&
        revision.isEmpty &&
        coordinateMap == null) {
      return body;
    }
    final meta = jsonEncode({
      'count': paragraphs.length,
      'blocks': {for (final e in formats.entries) '${e.key}': e.value.toJson()},
      'notes': notes,
      if (revision.isNotEmpty) 'revision': revision,
      if (coordinateMap != null) 'coordinates': coordinateMap!.toJson(),
    });
    return '$body\n\n$prefix${base64Url.encode(utf8.encode(meta))}-->';
  }

  static ReaderRichBody decode(String source) {
    if (!source.contains(prefix)) return ReaderRichBody(source.split('\n\n'));
    final paragraphs = <String>[],
        formats = <int, ReaderRichParagraph>{},
        notes = <String, String>{};
    var revision = '';
    ReaderCoordinateMap? coordinates;
    for (final part in source.split('\n\n')) {
      if (!part.startsWith(prefix) || !part.endsWith('-->')) {
        paragraphs.add(part);
        continue;
      }
      final value = jsonDecode(
        utf8.decode(
          base64Url.decode(part.substring(prefix.length, part.length - 3)),
        ),
      );
      if (value is! Map ||
          value['count'] is! int ||
          value['count'] > paragraphs.length ||
          value['count'] < 0 ||
          value['blocks'] is! Map ||
          value['notes'] is! Map) {
        throw const FormatException('原书排版数据格式有误');
      }
      final base = paragraphs.length - (value['count'] as int);
      revision = value['revision'] is String
          ? value['revision']
          : 'epub-rich-v1';
      if (value['coordinates'] != null) {
        coordinates = ReaderCoordinateMap.fromJson(
          value['coordinates'],
          paragraphs.join('\n\n').length,
        );
      }
      for (final e in (value['blocks'] as Map).entries) {
        final index = int.tryParse('${e.key}');
        if (index != null &&
            index >= 0 &&
            base + index < paragraphs.length &&
            e.value is Map) {
          formats[base + index] = ReaderRichParagraph.fromJson(
            e.value,
            paragraphs[base + index].length,
          );
        }
      }
      for (final e in (value['notes'] as Map).entries) {
        if (e.key is String && e.value is String && e.value.length <= 32000) {
          notes[e.key] = e.value;
        }
      }
    }
    return ReaderRichBody(
      paragraphs,
      formats: formats,
      notes: notes,
      revision: revision,
      coordinateMap: coordinates,
    );
  }
}
