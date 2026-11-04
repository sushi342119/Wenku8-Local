import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'reader_content.dart';
import 'reader_rich_content.dart';
import 'reader_pagination.dart';
import 'reader_preferences.dart';
import 'reader_vertical_text.dart';
import 'reader_selection.dart';
import 'reader_underline.dart';

class ReaderEmbeddedVertical extends StatefulWidget {
  const ReaderEmbeddedVertical({
    super.key,
    required this.text,
    required this.paragraph,
    required this.format,
    required this.style,
    required this.preferences,
    required this.selection,
    required this.onNote,
    this.chapter,
    this.annotationChanges,
    this.annotations,
  });
  final String text;
  final int paragraph;
  final int? chapter;
  final ReaderRichParagraph format;
  final TextStyle style;
  final ReaderPreferences preferences;
  final ReaderSelectionController selection;
  final ValueChanged<String> onNote;
  final Listenable? annotationChanges;
  final List<ReaderTextMark> Function()? annotations;
  @override
  State<ReaderEmbeddedVertical> createState() => _ReaderEmbeddedVerticalState();
}

class _ReaderEmbeddedVerticalState extends State<ReaderEmbeddedVertical> {
  final _cache = ReaderGlyphCache();
  Future<ReaderPagination?>? _layout;
  Object? _key;
  int _epoch = 0;
  @override
  void dispose() {
    _epoch++;
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth,
          height = math
              .min(460.0, MediaQuery.sizeOf(context).height * .55)
              .clamp(160.0, 460.0);
      final key = (
        widget.text,
        widget.format,
        widget.style,
        widget.preferences.layoutKey,
        width,
        height,
        MediaQuery.textScalerOf(context),
      );
      if (key != _key) {
        _key = key;
        final epoch = ++_epoch;
        _layout = paginateReader(
          content: ReaderContent(
            [widget.text],
            formats: {0: widget.format.withoutSpacing},
          ),
          size: Size(width, height),
          style: widget.style,
          preferences: widget.preferences.copyWith(mode: ReaderMode.vertical),
          scaler: MediaQuery.textScalerOf(context),
          current: () => mounted && _epoch == epoch,
        );
      }
      return FutureBuilder<ReaderPagination?>(
        future: _layout,
        builder: (context, snapshot) {
          final pages = snapshot.data?.pages;
          if (pages == null) {
            return SizedBox(
              height: height,
              child: const Center(child: CircularProgressIndicator.adaptive()),
            );
          }
          return Column(
            children: [
              for (final page in pages)
                SizedBox(
                  width: width,
                  height: height,
                  child: ReaderSelectionFragment(
                    controller: widget.selection,
                    chapter: widget.chapter,
                    text: page.text,
                    anchorForOffset: (offset) {
                      final glyph = page.glyphs
                          .where((g) => g.start <= offset && g.end >= offset)
                          .firstOrNull;
                      return glyph == null
                          ? null
                          : (
                              paragraph: widget.paragraph,
                              offset:
                                  glyph.sourceStart +
                                  (offset - glyph.start).clamp(
                                    0,
                                    glyph.sourceEnd - glyph.sourceStart,
                                  ),
                            );
                    },
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation:
                                widget.annotationChanges ??
                                const AlwaysStoppedAnimation(0),
                            builder: (context, _) => ReaderVerticalText(
                              page: page,
                              glyphCache: _cache,
                              style: widget.style.copyWith(
                                fontSize: MediaQuery.textScalerOf(
                                  context,
                                ).scale(widget.style.fontSize ?? 19),
                              ),
                              annotations: [
                                for (final mark
                                    in widget.annotations?.call() ??
                                        const <ReaderTextMark>[])
                                  ReaderAnnotationRange(
                                    ReaderUnderlineRange(
                                      chapterId: 1,
                                      startParagraph: 0,
                                      startOffset: mark.start,
                                      endParagraph: 0,
                                      endOffset: mark.end,
                                    ),
                                    mark.style,
                                    mark.color,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        for (final glyph in page.glyphs)
                          if (glyph.note != null)
                            Positioned.fromRect(
                              rect: glyph.rect.inflate(2),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => widget.onNote(glyph.note!),
                                child: const SizedBox.expand(),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}
