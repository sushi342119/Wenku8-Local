import 'package:flutter/widgets.dart';

// A fixed inline box is not discarded as leading whitespace by SkParagraph's
// justification. One placeholder code unit maps back to zero source characters.
const readerIndentLength = 1;
const readerIndentPlaceholder = '\ufffc';

/// Builds source text with geometry-only indentation and optional continuation.
/// A continuation occupies the clipped next line, so a page edge is not treated
/// as a paragraph ending by justification; it never enters copied source text.
TextSpan readerParagraphSpan({
  required List<InlineSpan> children,
  required TextStyle style,
  required bool indent,
  double? continuationWidth,
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
    ...children,
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
