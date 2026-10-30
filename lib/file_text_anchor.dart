import 'dart:convert';
import 'dart:io';

import 'chapter_splitter.dart';
import 'text_anchor.dart';

class FileTextAnchor {
  FileTextAnchor._(this.file, this.length, this._text);
  final File file;
  final int length;
  final String? _text;
  static const maxSliceLength = 4 * 1024 * 1024;

  static Future<FileTextAnchor> open(String path) async {
    final file = File(path);
    if (await file.length() <= 2 * 1024 * 1024) {
      final text = await file.readAsString();
      return FileTextAnchor._(file, text.length, text);
    }
    var length = 0;
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      length += chunk.length;
    }
    return FileTextAnchor._(file, length, null);
  }

  Future<String> slice(int start, int end) async {
    if (start < 0 || end < start || end > length) {
      throw StateError('阅读锚点范围损坏');
    }
    if (end - start > maxSliceLength) {
      throw const FormatException('单章正文过大，请拆分章节后迁移阅读进度');
    }
    if (_text case final text?) return text.substring(start, end);
    var offset = 0;
    final result = StringBuffer();
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final next = offset + chunk.length;
      if (next > start && offset < end) {
        result.write(
          chunk.substring(
            start > offset ? start - offset : 0,
            end < next ? end - offset : chunk.length,
          ),
        );
      }
      offset = next;
      if (offset >= end) break;
    }
    if (result.length != end - start) throw StateError('迁移期间正文发生变化');
    return result.toString();
  }

  Stream<String> _chunks(int start, int end) async* {
    if (start < 0 || end < start || end > length) {
      throw StateError('阅读锚点范围损坏');
    }
    var offset = 0;
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final next = offset + chunk.length;
      if (next > start && offset < end) {
        yield chunk.substring((start - offset).clamp(0, chunk.length),
            (end - offset).clamp(0, chunk.length));
      }
      offset = next;
      if (offset >= end) break;
    }
    if (offset < end) throw StateError('迁移期间正文发生变化');
  }

  Future<({int start, int end})> trimmedRange(int start, int end) async {
    int? first;
    var last = start;
    var offset = start;
    await for (final chunk in _chunks(start, end)) {
      final left = chunk.trimLeft();
      if (first == null && left.isNotEmpty) first = offset + chunk.length - left.length;
      final right = chunk.trimRight();
      if (right.isNotEmpty) last = offset + right.length;
      offset += chunk.length;
    }
    return (start: first ?? end, end: first == null ? end : last);
  }

  Future<({int index, int start})> paragraphAt(int start, int end, {int? stopAt}) async {
    var paragraph = 0;
    var paragraphStart = 0;
    var consumed = 0;
    var newline = false;
    if (stopAt == 0) return (index: 0, start: 0);
    await for (final chunk in _chunks(start, end)) {
      for (final unit in chunk.codeUnits) {
        consumed++;
        if (unit == 10 && newline) {
          paragraph++;
          paragraphStart = consumed;
          newline = false;
          if (stopAt != null && paragraph >= stopAt) {
            return (index: paragraph, start: paragraphStart);
          }
        } else {
          newline = unit == 10;
        }
      }
    }
    return (index: paragraph, start: paragraphStart);
  }

  Future<int> relocateFrom(FileTextAnchor old, int offset) async {
    offset = offset.clamp(0, old.length);
    if (old._text != null && _text != null) {
      return relocateTextOffset(old._text, _text, offset);
    }
    if (old.file.path == file.path) {
      if (old.length != length) {
        throw StateError('迁移期间正文发生变化');
      }
      return offset;
    }
    final windowStart = (offset - 4096).clamp(0, old.length);
    final windowEnd = (offset + 4160).clamp(0, old.length);
    final window = await old.slice(windowStart, windowEnd);
    final candidates = <({String text, int expected, int adjustment})>[];
    void add(int start, int end, int adjustment) {
      final text = window.substring(start - windowStart, end - windowStart);
      if (text.trim().isNotEmpty) {
        candidates.add((text: text, expected: start, adjustment: adjustment));
      }
    }

    final left = (offset - 32).clamp(0, old.length);
    final right = (offset + 96).clamp(0, old.length);
    add(left, right, offset - left);
    add(offset, right, 0);
    for (var distance = 64; distance <= 4096; distance *= 2) {
      for (final sign in [1, -1]) {
        final start = (offset + sign * distance).clamp(0, old.length);
        final end = (start + 64).clamp(0, old.length);
        if (end - start >= 16) add(start, end, sign > 0 ? 0 : end - start);
      }
    }
    final matches = List<int?>.filled(candidates.length, null);
    var consumed = 0;
    var tail = '';
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final text = '$tail$chunk';
      final base = consumed - tail.length;
      for (var candidate = 0; candidate < candidates.length; candidate++) {
        final needle = candidates[candidate];
        var best = matches[candidate];
        if (best != null &&
            base - needle.expected >= (best - needle.expected).abs()) {
          continue;
        }
        var found = text.indexOf(needle.text);
        while (found >= 0) {
          final position = base + found;
          if (best == null ||
              (position - needle.expected).abs() <
                  (best - needle.expected).abs()) {
            best = position;
          }
          if (position >= needle.expected) break;
          found = text.indexOf(needle.text, found + 1);
        }
        matches[candidate] = best;
      }
      consumed += chunk.length;
      tail = text.substring((text.length - 127).clamp(0, text.length));
    }
    for (var candidate = 0; candidate < candidates.length; candidate++) {
      if (matches[candidate] case final match?) {
        return match + candidates[candidate].adjustment;
      }
    }
    return offset.clamp(0, length);
  }

  Future<
    ({
      int chapter,
      int textOffset,
      int paragraph,
      int paragraphStart,
      double fraction,
    })
  >
  locate(List<LocalChapterIndex> chapters, int global) async {
    if (chapters.isEmpty) {
      throw StateError('Cannot anchor an empty chapter table');
    }
    var index = chapters.indexWhere(
      (chapter) => global < chapter.offset + chapter.length,
    );
    if (index < 0) index = chapters.length - 1;
    final chapter = chapters[index];
    if (chapter.length > maxSliceLength) {
      final range = await trimmedRange(chapter.offset, chapter.offset + chapter.length);
      final bodyLength = range.end - range.start;
      final local = (global - range.start).clamp(0, bodyLength);
      final paragraph = await paragraphAt(range.start, range.start + local);
      return (chapter: index, textOffset: local,
        paragraph: paragraph.index, paragraphStart: paragraph.start,
        fraction: bodyLength == 0 ? 0.0 : local / bodyLength);
    }
    final body = await slice(chapter.offset, chapter.offset + chapter.length);
    final target = locateTextAnchor(body, [
      LocalChapterIndex(chapter.title, 0, body.length),
    ], global - chapter.offset);
    return (
      chapter: index,
      textOffset: target.textOffset,
      paragraph: target.paragraph,
      paragraphStart: target.paragraphStart,
      fraction: target.fraction,
    );
  }
}
