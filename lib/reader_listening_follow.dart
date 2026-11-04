import 'listening/controller.dart';
import 'listening/models.dart';

/// Audio outputs expose clip time, not word timings. Estimate the source cursor
/// within that clip so a sentence spanning leaves does not pin follow to its
/// first leaf. Speech sanitization retains the original UTF-16 length.
int readerListeningOffset(SpeechSegment segment, ListeningProgress progress) {
  final length = segment.end - segment.start;
  if (length <= 0 || progress.duration <= Duration.zero) return segment.start;
  final fraction =
      (progress.position.inMicroseconds / progress.duration.inMicroseconds)
          .clamp(0.0, 1.0);
  var local = (length * fraction).floor().clamp(0, length - 1);
  // Never point between the UTF-16 units of an original supplementary glyph.
  if (local > 0 && local < segment.text.length) {
    final before = segment.text.codeUnitAt(local - 1);
    final current = segment.text.codeUnitAt(local);
    if (before >= 0xD800 &&
        before <= 0xDBFF &&
        current >= 0xDC00 &&
        current <= 0xDFFF) {
      local--;
    }
  }
  return segment.start + local;
}
