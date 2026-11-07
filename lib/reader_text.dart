import 'package:flutter/widgets.dart';

// A fixed inline box is not discarded as leading whitespace by SkParagraph's
// justification. One placeholder code unit maps back to zero source characters.
const readerIndentLength = 1;
const readerIndentPlaceholder = '\ufffc';

const cjkClosingPunctuation = '，。！？、；：）》」』】〕］｝’”';
const cjkOpeningPunctuation = '（《「『【〔［｛‘“';

bool isCompressibleCjkPunctuationPair(String previous, String current) {
  if (previous.isEmpty || current.isEmpty) return false;
  final prevClosing = cjkClosingPunctuation.contains(previous);
  final currClosing = cjkClosingPunctuation.contains(current);
  final currOpening = cjkOpeningPunctuation.contains(current);
  return (prevClosing && currClosing) || (prevClosing && currOpening);
}

List<InlineSpan> compressCjkPunctuationSpans(
  List<InlineSpan> spans,
  TextStyle baseStyle,
) {
  final font = baseStyle.fontSize ?? 19.0;
  final baseSpacing = baseStyle.letterSpacing ?? 0.0;
  final compressedStyle = baseStyle.copyWith(
    letterSpacing: baseSpacing - font * 0.28,
  );
  final result = <InlineSpan>[];
  for (final span in spans) {
    if (span is! TextSpan || span.text == null || span.children != null) {
      result.add(span);
      continue;
    }
    final text = span.text!;
    if (text.length < 2) {
      result.add(span);
      continue;
    }
    final effectiveStyle = span.style == null
        ? compressedStyle
        : span.style!.copyWith(
            letterSpacing: (span.style!.letterSpacing ?? baseSpacing) - font * 0.28,
          );
    var segStart = 0;
    var inCompressed = false;
    for (var i = 0; i < text.length; i++) {
      final pairCompress =
          i + 1 < text.length &&
          isCompressibleCjkPunctuationPair(text[i], text[i + 1]);
      if (pairCompress != inCompressed) {
        if (i > segStart) {
          result.add(
            TextSpan(
              text: text.substring(segStart, i),
              style: inCompressed ? effectiveStyle : span.style,
            ),
          );
        }
        segStart = i;
        inCompressed = pairCompress;
      }
    }
    if (segStart == 0 && !inCompressed) {
      result.add(span);
    } else if (segStart < text.length) {
      result.add(
        TextSpan(
          text: text.substring(segStart),
          style: inCompressed ? effectiveStyle : span.style,
        ),
      );
    }
  }
  return result;
}

/// Builds source text with geometry-only indentation and optional continuation.
/// A continuation occupies the clipped next line, so a page edge is not treated
/// as a paragraph ending by justification; it never enters copied source text.
TextSpan readerParagraphSpan({
  required List<InlineSpan> children,
  required TextStyle style,
  required bool indent,
  double? continuationWidth,
  bool compressPunctuation = false,
}) => TextSpan(
  style: style,
  children: [
    if (indent)
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: ExcludeSemantics(
          // Text.rich scales inline widgets with its TextScaler already.
          child: SizedBox(width: (style.fontSize ?? 19) * 2, height: 0),
        ),
      ),
    ...(compressPunctuation
        ? compressCjkPunctuationSpans(children, style)
        : children),
    if (continuationWidth != null)
      WidgetSpan(
        child: ExcludeSemantics(
          child: SelectionContainer.disabled(
            // A geometry-only next line keeps a page break a soft wrap. It
            // contributes no selectable text and is clipped by the fragment.
            child: SizedBox(width: continuationWidth, height: 0),
          ),
        ),
      ),
  ],
);

List<PlaceholderDimensions> readerIndentDimensions(bool indent, double font) =>
    [
      if (indent)
        PlaceholderDimensions(
          size: Size(font * 2, 0),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: 0,
        ),
    ];
