import 'dart:convert';

/// UTF-16 offsets in the normalized internal text, shared by import and audit.
class LocalChapterIndex {
  const LocalChapterIndex(
    this.title,
    this.offset,
    this.length, {
    this.volume = '',
    this.byteOffset = -1,
    this.byteLength = -1,
  });
  final String title;
  final int offset;
  final int length;
  final String volume;
  final int byteOffset;
  final int byteLength;
  Map<String, Object?> toJson() => {
    't': title,
    'o': offset,
    'l': length,
    if (volume.isNotEmpty) 'v': volume,
    if (byteOffset >= 0 && byteLength >= 0) 'bo': byteOffset,
    if (byteOffset >= 0 && byteLength >= 0) 'bl': byteLength,
  };
  factory LocalChapterIndex.fromJson(Map<String, Object?> json) =>
      LocalChapterIndex(
        json['t'] as String? ?? '正文',
        (json['o'] as num?)?.toInt() ?? 0,
        (json['l'] as num?)?.toInt() ?? 0,
        volume: json['v'] as String? ?? '',
        byteOffset: (json['bo'] as num?)?.toInt() ?? -1,
        byteLength: (json['bl'] as num?)?.toInt() ?? -1,
      );
}

String normalizeLocalText(String text) => text
    .replaceFirst(RegExp(r'^\uFEFF'), '')
    .replaceAll('\r\n', '\n')
    .replaceAll(RegExp(r'[\r\u2028\u2029]'), '\n');

bool validChapterRanges(List<LocalChapterIndex> chapters, int textLength) {
  var end = 0;
  for (final c in chapters) {
    if (c.offset < end || c.length < 0 || c.offset + c.length > textLength) {
      return false;
    }
    end = c.offset + c.length;
  }
  return true;
}

const _number = r'[0-9０-９一二三四五六七八九十百千萬万零〇两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+';
final _numbered = RegExp(
  '(?:第[ \\t　]*$_number[ \\t　]*|$_number)[章节節回话話幕折卷部集篇]',
);
final _volumeNumber = RegExp('卷[ \\t　]*$_number');
final _english = RegExp(
  r'chapter\s*(?:[0-9０-９]+|[ivxlcdm]+)(?![a-z0-9０-９])',
  caseSensitive: false,
);
final _bare = RegExp(
  '^(?:[（(]($_number)[）)]|($_number)[.．、:：]|($_number)[ \\t　]+|($_number)\$)',
);
final _special = RegExp(
  r'^(?:序章|序曲|序言|序幕|楔子|终章|終章|终曲|番外(?:篇)?(?:[ \t]*[0-9０-９一二三四五六七八九十]+)?|后记|後記|后日谈|前言|引子|尾声|外篇|外传|外傳|[上中下]篇)',
);
final _decoration = RegExp(
  r'^[\s\uFEFF\u200B\u2060#＊*☆★◆◇●○◎※=—\-🍎📖📚]+',
  unicode: true,
);
final _endMarker = RegExp(
  r'^[\s【\[（(]*第?[^\n]{0,16}[卷部集篇][\s】\]）)]*(?:完|结束|終|终|END)',
  caseSensitive: false,
);
final _proseSuffix = RegExp(
  r'^(?:回[来去到头答想忆合事家顾]|节[课约省日]|部[分队门署]|集[合中体]|篇[文章幅])',
);
final _punctuation = RegExp(r'[。！？!?；;]');

class _Heading {
  _Heading(
    this.title,
    this.start,
    this.content,
    this.wordsBefore,
    this.wordsAfter,
    this.family,
    this.weak,
    this.volume,
    this.key,
    this.startBytes,
    this.contentBytes,
  );
  final String title, family, key;
  final int start, content, wordsBefore, wordsAfter;
  final int startBytes, contentBytes;
  final bool weak, volume;
}

/// Keeps only candidate headings and a bounded line prefix, never a whole book.
/// Leading whitespace is counted separately, so even very long indentation is
/// accepted without growing the line buffer. All coordinates stay in the source.
class ChapterTextIndex {
  int length = 0;
  int byteLength = 0;
  int _lineStart = 0, _lineByteStart = 0;
  int _indent = 0, _words = 0, _lineWords = 0;
  String _line = '';
  bool _leading = true;
  final _headings = <_Heading>[];
  final _directoryMarkers = <int>[];

  // A high surrogate held from the previous chunk: it contributes no bytes
  // until its low surrogate arrives, so a pair split across chunk
  // boundaries is counted once (4 bytes) instead of twice (3 + 3 bytes
  // for two lone-surrogate replacements).
  int _pendingHigh = -1;

  void add(String chunk) {
    // Byte counting runs over countChunk, which carries a held high
    // surrogate from the previous chunk (shift 1) and holds a trailing
    // high surrogate for the next chunk. Character offsets keep using
    // the original chunk, so line splitting is unaffected.
    var countChunk = chunk;
    var shift = 0;
    if (_pendingHigh >= 0) {
      countChunk = String.fromCharCode(_pendingHigh) + chunk;
      _pendingHigh = -1;
      shift = 1;
    }
    if (countChunk.isNotEmpty) {
      final last = countChunk.codeUnitAt(countChunk.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        _pendingHigh = last;
        countChunk = countChunk.substring(0, countChunk.length - 1);
      }
    }
    // 增量字节计数：segStart 为 countChunk 中尚未计入 runningBytes 的起点。
    // 分段点只在下标 0 或 '\n' 之后，不会拆开代理对，各段 UTF-8 长度之和
    // 等于整段前缀长度。每个码元只编码一次。
    var segStart = 0;
    var runningBytes = byteLength;
    for (var i = 0; i < chunk.length;) {
      final newline = chunk.indexOf('\n', i);
      final end = newline < 0 ? chunk.length : newline;
      var part = chunk.substring(i, end);
      _lineWords += part.replaceAll(RegExp(r'[\s\uFEFF\u200B]'), '').length;
      if (_leading) {
        final trimmed = part.trimLeft();
        _indent += part.length - trimmed.length;
        part = trimmed;
        if (part.isNotEmpty) _leading = false;
      }
      if (_line.length < 2048) {
        final room = 2048 - _line.length;
        _line += part.length > room ? part.substring(0, room) : part;
      }
      if (newline < 0) break;
      final segEnd = newline + 1 + shift;
      runningBytes += utf8.encode(countChunk.substring(segStart, segEnd)).length;
      segStart = segEnd;
      final nextBytes = runningBytes;
      _finishLine(length + newline + 1, nextBytes);
      _lineStart = length + newline + 1;
      _lineByteStart = nextBytes;
      i = newline + 1;
    }
    length += chunk.length;
    byteLength =
        runningBytes + utf8.encode(countChunk.substring(segStart)).length;
  }

  void _finishLine(int next, int nextBytes) {
    final line = _line.trimRight();
    if (RegExp(
      r'^[【\[\s]*(?:目\s*录|contents)[】\]\s:：]*$',
      caseSensitive: false,
    ).hasMatch(line)) {
      _directoryMarkers.add(_lineStart);
    }
    final h = _parse(line, next, nextBytes);
    if (h != null) _headings.add(h);
    if (_headings.length + _directoryMarkers.length > 100000) {
      throw const FormatException('TXT 章节索引过大：候选标题与目录标记超过 100000 条');
    }
    _words += _lineWords;
    _lineWords = 0;
    _line = '';
    _indent = 0;
    _leading = true;
  }

  _Heading? _parse(String raw, int next, int nextBytes) {
    if (raw.isEmpty) return null;
    var line = raw.replaceFirst(_decoration, '');
    final displayLine = line;
    var skipped = raw.length - line.length;
    if (_endMarker.hasMatch(line)) return null;
    // Enclosing book names are meaningful display prefixes. Only syntactic
    // opening brackets around a heading are removed for matching.
    final opening = RegExp(
      r'^[【\[（(](?=第|chapter|序|番外|外篇|外传|[上中下]篇)',
      caseSensitive: false,
    ).firstMatch(line);
    if (opening != null) {
      skipped++;
      line = line.substring(1);
    }
    RegExpMatch? m =
        _numbered.firstMatch(line) ??
        _volumeNumber.firstMatch(line) ??
        _english.firstMatch(line);
    var weak = false;
    String family = '';
    if (m != null && m.start > 0) {
      final prefix = line.substring(0, m.start);
      // Prefixes are titles/正文, never a sentence or a reference in prose.
      if (prefix.length > 48 ||
          RegExp(r'[。！？!?，,；;：:“”「」]').hasMatch(prefix) ||
          !(prefix.endsWith(' ') ||
              prefix.endsWith('　') ||
              prefix.endsWith('】') ||
              prefix.endsWith('》') ||
              prefix.endsWith('）') ||
              prefix.endsWith(')') ||
              prefix == '正文')) {
        return null;
      }
    }
    if (m == null) {
      // 【书名】（13） and repeated book-title prefixes before bare numbers.
      var base = 0;
      final bracket = RegExp(r'^【[^】\n]{1,48}】\s*').firstMatch(line);
      if (bracket != null) base = bracket.end;
      final candidate = line.substring(base);
      m = _bare.firstMatch(candidate);
      if (m != null) {
        family = candidate.startsWith('（') || candidate.startsWith('(')
            ? 'parenthesized'
            : 'bare';
        weak = true;
        skipped += base;
        line = candidate;
      } else {
        m = _special.firstMatch(line);
        if (m == null) return null;
        family = 'special';
        final tail = line.substring(m.end);
        if (tail.isNotEmpty &&
            !RegExp(r'^[\s\d０-９:：、.．【\[（(】\]）)\-—]').hasMatch(tail)) {
          return null;
        }
        if (_punctuation.hasMatch(tail) && tail.length > 12) return null;
      }
    }
    final token = m.group(0)!;
    if (RegExp(
      r'^[【\[].*[卷部集篇].*(?:完|结束|END)[）)】\]]*$',
      caseSensitive: false,
    ).hasMatch(raw)) {
      return null;
    }
    final isVolume =
        RegExp(r'[卷部集篇]$').hasMatch(token) && family != 'special' ||
        RegExp(r'^[上中下]篇').hasMatch(token);
    final suffix = line.substring(m.end);
    if (family.isEmpty &&
        !token.startsWith('第') &&
        !token.startsWith('卷') &&
        !token.toLowerCase().startsWith('chapter')) {
      weak = true;
    }
    if (isVolume && (_punctuation.hasMatch(suffix) || suffix.length > 120)) {
      return null;
    }
    if (_proseSuffix.hasMatch('${token[token.length - 1]}$suffix')) return null;
    if (family.isEmpty) {
      family = token.toLowerCase().startsWith('chapter')
          ? 'english'
          : token[token.length - 1];
    }
    // In-body numbered lists need repeated evidence and never accept sentences.
    if (weak && (_punctuation.hasMatch(suffix) || suffix.length > 120)) {
      return null;
    }
    final forum = RegExp(
      r'\[bbs\]|https?://|viewthread\.php',
      caseSensitive: false,
    ).firstMatch(line);
    var titleEnd = forum?.start ?? line.length;
    var content = next;
    final glued =
        forum == null &&
        !weak &&
        !isVolume &&
        (suffix.length > 96 ||
            suffix.length > 28 && _punctuation.hasMatch(suffix));
    if (glued) {
      // The title/body boundary is unknowable without semantics. Keep the
      // entire ambiguous suffix in the body, rather than discarding a guess.
      titleEnd = m.end;
      content = _lineStart + _indent + skipped + m.end;
    }
    if (titleEnd < m.end) return null;
    var title = line.substring(0, titleEnd).trim();
    if (opening != null) title = '${opening.group(0)}$title';
    if (title.isEmpty) return null;
    // Restore a book-name prefix stripped solely to parse a bracketed number.
    if (weak && skipped > 0 && raw.contains('】')) {
      title = '${displayLine.substring(0, displayLine.indexOf('】') + 1)}$title';
    }
    final wordsAfter = glued
        ? _words +
              raw
                  .substring(
                    0,
                    (content - _lineStart - _indent).clamp(0, raw.length),
                  )
                  .replaceAll(RegExp(r'\s'), '')
                  .length
        : _words + _lineWords;
    final key = title.replaceAll(RegExp(r'[\s【】\[\]（）()]'), '');
    final contentUnits = (content - _lineStart).clamp(0, raw.length);
    final contentBytes = glued
        ? _lineByteStart + utf8.encode(raw.substring(0, contentUnits)).length
        : nextBytes;
    return _Heading(
      title,
      _lineStart,
      content,
      _words,
      wordsAfter,
      family,
      weak,
      isVolume,
      key,
      _lineByteStart,
      contentBytes,
    );
  }

  List<LocalChapterIndex> finish() {
    // A trailing unpaired high surrogate encodes as one replacement
    // character (3 bytes) in whole-string UTF-8 encoding.
    if (_pendingHigh >= 0) {
      byteLength += 3;
      _pendingHigh = -1;
    }
    _finishLine(length, byteLength);
    final families = <String, int>{};
    for (final h in _headings) {
      families.update(h.family, (n) => n + 1, ifAbsent: () => 1);
    }
    final weakEvidence = <String, int>{};
    for (var i = 0; i < _headings.length; i++) {
      final h = _headings[i];
      if (!h.weak) continue;
      final next = i + 1 < _headings.length ? _headings[i + 1] : null;
      if ((next?.wordsBefore ?? _words) - h.wordsAfter > 8) {
        weakEvidence.update(h.family, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final dominant =
        families.entries
            .where(
              (e) =>
                  e.key != 'special' &&
                  ![
                    '卷',
                    '部',
                    '篇',
                    '集',
                    'bare',
                    'parenthesized',
                  ].contains(e.key),
            )
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    var headings = _headings.where((h) {
      if (h.weak && (weakEvidence[h.family] ?? 0) < 2) return false;
      if (dominant.isNotEmpty &&
          dominant.first.value >= 8 &&
          ['回', '节', '部', '集'].contains(h.family) &&
          (families[h.family] ?? 0) < 2 &&
          h.family != dominant.first.key) {
        return false;
      }
      return true;
    }).toList();
    // Front matter TOCs contain consecutive headings with no body and often
    // repeat at the real chapter. Do not make those entries empty chapters.
    final lastHeadingByKey = <String, int>{};
    for (var i = 0; i < headings.length; i++) {
      lastHeadingByKey[headings[i].key] = i;
    }
    final directory = <_Heading>{};
    for (var i = 0; i + 1 < headings.length; i++) {
      final h = headings[i], after = headings[i + 1];
      if (after.wordsBefore - h.wordsAfter > 0) break;
      final repeated = (lastHeadingByKey[h.key] ?? i) > i;
      final marked = _directoryMarkers.any((offset) => offset <= h.start);
      if (repeated || marked) directory.add(h);
    }
    headings = headings.where((h) => !directory.contains(h)).toList();
    if (headings.isEmpty) {
      return [
        LocalChapterIndex(
          '正文',
          0,
          length,
          byteOffset: 0,
          byteLength: byteLength,
        ),
      ];
    }
    final chapters = <LocalChapterIndex>[];
    var volume = '';
    final volumes = _headings.where((h) => h.volume).toList();
    var volumeCursor = 0;
    // Preserve ALL nonempty front matter, including TOC text as front matter;
    // it has no independent chapter entries and never hides opening prose.
    if (headings.first.wordsBefore > 0) {
      chapters.add(
        LocalChapterIndex(
          '前言',
          0,
          headings.first.start,
          byteOffset: 0,
          byteLength: headings.first.startBytes,
        ),
      );
    }
    for (var i = 0; i < headings.length; i++) {
      final h = headings[i];
      final next = i + 1 < headings.length ? headings[i + 1] : null;
      final end = next?.start ?? length;
      final bodyWords = (next?.wordsBefore ?? _words) - h.wordsAfter;
      while (volumeCursor < volumes.length &&
          volumes[volumeCursor].start <= h.start) {
        volume = volumes[volumeCursor++].title;
      }
      if (bodyWords <= 0) continue;
      chapters.add(
        LocalChapterIndex(
          h.title,
          h.content,
          end - h.content,
          volume: h.volume ? '' : volume,
          byteOffset: h.contentBytes,
          byteLength: (next?.startBytes ?? byteLength) - h.contentBytes,
        ),
      );
    }
    if (chapters.isEmpty) {
      return [
        LocalChapterIndex(
          '正文',
          0,
          length,
          byteOffset: 0,
          byteLength: byteLength,
        ),
      ];
    }
    if (!validChapterRanges(chapters, length)) {
      throw StateError('Invalid chapter ranges');
    }
    return List.unmodifiable(chapters);
  }
}

List<LocalChapterIndex> splitLocalChapters(String normalizedText) =>
    (ChapterTextIndex()..add(normalizedText)).finish();
