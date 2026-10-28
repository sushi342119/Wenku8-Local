import 'chapter_splitter.dart';

int paragraphTextOffset(List<String> paragraphs, int index) {
  var offset = 0;
  for (var i = 0; i < index && i < paragraphs.length; i++) {
    offset += paragraphs[i].length + 2;
  }
  return offset;
}

/// Context is matched against actual text, not rendered scroll percentages.
/// Duplicate passages use the nearest occurrence; deleted passages fall back
/// to a surviving neighbour, then to the bounded old character position.
int relocateTextOffset(String oldText, String newText, int offset) {
  offset = offset.clamp(0, oldText.length);
  if (oldText == newText) return offset;
  int? find(String needle, int expected) {
    if (needle.trim().isEmpty) return null;
    var at = newText.indexOf(needle);
    int? best;
    while (at >= 0) {
      if (best == null || (at - expected).abs() < (best - expected).abs()) {
        best = at;
      }
      at = newText.indexOf(needle, at + 1);
    }
    return best;
  }

  final left = (offset - 32).clamp(0, oldText.length);
  final right = (offset + 96).clamp(0, oldText.length);
  final context = find(oldText.substring(left, right), left);
  if (context != null) return context + offset - left;
  final forward = find(oldText.substring(offset, right), offset);
  if (forward != null) return forward;
  for (var distance = 64; distance <= 4096; distance *= 2) {
    for (final sign in [1, -1]) {
      final start = (offset + sign * distance).clamp(0, oldText.length);
      final end = (start + 64).clamp(0, oldText.length);
      if (end - start < 16) continue;
      final found = find(oldText.substring(start, end), start);
      if (found != null) return sign > 0 ? found : found + end - start;
    }
  }
  return offset.clamp(0, newText.length);
}

({
  int chapter,
  int textOffset,
  int paragraph,
  int paragraphStart,
  double fraction,
})
locateTextAnchor(String text, List<LocalChapterIndex> chapters, int global) {
  if (chapters.isEmpty) {
    throw StateError('Cannot anchor an empty chapter table');
  }
  var index = chapters.length - 1;
  for (var i = 0; i < chapters.length; i++) {
    if (global < chapters[i].offset + chapters[i].length) {
      index = i;
      break;
    }
  }
  final c = chapters[index];
  final raw = text.substring(c.offset, c.offset + c.length);
  final body = raw.trim();
  final trim = raw.length - raw.trimLeft().length;
  final local = (global - c.offset - trim).clamp(0, body.length);
  var paragraph = 0, start = 0;
  while (true) {
    final end = body.indexOf('\n\n', start);
    if (end < 0 || end + 2 > local) break;
    start = end + 2;
    paragraph++;
  }
  return (
    chapter: index,
    textOffset: local,
    paragraph: paragraph,
    paragraphStart: start,
    fraction: body.isEmpty ? 0 : local / body.length,
  );
}
