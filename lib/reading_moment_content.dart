import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'reading_export_theme.dart';
import 'reading_keepsake_theme.dart';
import 'reading_moments.dart';
import 'reading_visual_theme.dart';

/// Complete input for popup and export. No live ledger, library lookup or
/// presentation-queue mutation belongs in this surface.
@immutable
class ReadingMomentPresentation {
  const ReadingMomentPresentation({
    required this.moment,
    this.theme = ReadingVisualTheme.archive,
    this.isPreview = false,
    this.showBookDetails = true,
    this.coverBytes,
  });
  final ReadingMoment moment;
  final ReadingVisualTheme theme;
  final bool isPreview;
  final bool showBookDetails;
  final Uint8List? coverBytes;

  factory ReadingMomentPresentation.preview(ReadingVisualTheme theme) =>
      ReadingMomentPresentation(
        theme: theme,
        isPreview: true,
        moment: ReadingMoment(
          id: 'preview:completion',
          kind: ReadingMomentKind.completion,
          earnedAt: DateTime(2026, 1, 18, 20),
          completion: ReadingCompletionSnapshot(
            bookId: 1,
            title: '春日来信（示例书籍）',
            author: '示例作者',
            completedAt: DateTime(2026, 1, 18, 20),
            finished: true,
            verifiedSeconds: 9000,
            readingDays: 4,
            firstReadAt: DateTime(2026, 1, 15),
            lastReadAt: DateTime(2026, 1, 18),
          ),
        ),
      );
}

/// The popup and exported image share the same immutable event and visual family.
class ReadingMomentContent extends StatelessWidget {
  const ReadingMomentContent({
    super.key,
    required this.presentation,
    this.compact = false,
  });
  final ReadingMomentPresentation presentation;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) =>
        _MomentComposition(presentation, constraints.maxWidth, compact).build(),
  );
}

class _MomentComposition {
  _MomentComposition(this.presentation, this.width, this.compact);
  final ReadingMomentPresentation presentation;
  final double width;
  final bool compact;
  ReadingMoment get moment => presentation.moment;
  ReadingCompletionSnapshot? get completion => moment.completion;
  ReadingVisualTheme get theme => presentation.theme;
  ReadingExportTheme get edition => readingExportTheme(theme);
  double get gutter => width * .065;
  String get marker => presentation.isPreview ? '效果预览 · 示例内容' : '阅读纪念';
  String get artAsset => readingKeepsakeArt(theme, recordedAt: moment.earnedAt);
  bool get hasCover =>
      presentation.showBookDetails && presentation.coverBytes != null;
  bool get hasMeasurements =>
      completion != null &&
      (completion!.verifiedSeconds != null ||
          completion!.readingDays > 0 ||
          completion!.firstReadAt != null ||
          completion!.lastReadAt != null);

  Widget text(
    String value, {
    double size = 14,
    Color? color,
    bool display = false,
    bool serif = false,
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    TextAlign align = TextAlign.start,
  }) => AppText(
    value,
    textAlign: align,
    style: TextStyle(
      fontSize: size,
      color: color ?? edition.foreground,
      fontFamily: display
          ? 'ReadingDisplay'
          : serif
          ? 'ReadingSerifDisplay'
          : null,
      fontFamilyFallback: const ['CupertinoSystemText'],
      fontWeight: display || serif ? FontWeight.w700 : weight,
      height: height,
    ),
  );

  Widget build() => ColoredBox(
    key: ValueKey('reading-moment-composition-${theme.id}'),
    color: edition.background,
    child: switch (theme) {
      ReadingVisualTheme.archive => dossier(),
      ReadingVisualTheme.shelf => harbor(),
      ReadingVisualTheme.editorial => seasons(),
      ReadingVisualTheme.constellation => night(),
      ReadingVisualTheme.signal => paperEcho(),
      ReadingVisualTheme.score => film(),
      ReadingVisualTheme.ink => mountain(),
      ReadingVisualTheme.festival => postcard(),
    },
  );

  Widget header({Color? color, bool compactDate = false}) {
    final ink = color ?? edition.muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 4,
          children: [
            text(
              readingExportBrandName,
              size: 12,
              color: ink,
              weight: FontWeight.w600,
            ),
            text(
              readingMomentDate(moment.earnedAt),
              size: 11,
              color: ink,
              display: true,
            ),
          ],
        ),
        const SizedBox(height: 5),
        text(marker, size: 10.5, color: ink),
      ],
    );
  }

  Widget headline({Color? color, double? size}) {
    final ink = color ?? edition.foreground;
    if (completion != null) {
      return text(
        completion!.finished ? '读完留念' : '读到此刻',
        size: size ?? (compact ? 28 : 40),
        color: ink,
        weight: FontWeight.w800,
        height: 1.12,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: text(
            moment.kind == ReadingMomentKind.firstDay
                ? '01'
                : '${moment.value}',
            size: size ?? (compact ? 64 : 100),
            color: ink,
            display: true,
            height: .95,
          ),
        ),
        const SizedBox(height: 4),
        text(
          moment.kind == ReadingMomentKind.duration ? '小时' : '天',
          size: 14,
          color: ink,
        ),
      ],
    );
  }

  Widget artwork({
    String? asset,
    double? height,
    double? artWidth,
    BoxFit fit = BoxFit.cover,
    Alignment? alignment,
  }) => Image.asset(
    asset ?? artAsset,
    width: artWidth ?? width,
    height: height,
    fit: fit,
    alignment: alignment ?? edition.previewAlignment,
    excludeFromSemantics: true,
    filterQuality: FilterQuality.medium,
  );

  Widget panorama({EdgeInsets? margin, double frame = 0}) => Container(
    margin: margin,
    padding: EdgeInsets.all(frame),
    color: frame == 0 ? null : const Color(0xfffcfbf5),
    child: AspectRatio(
      aspectRatio: 1080 / 608,
      child: artwork(fit: BoxFit.contain, alignment: Alignment.center),
    ),
  );

  Widget rule({Color? color, double height = 1}) => SizedBox(
    height: height,
    width: double.infinity,
    child: ColoredBox(color: color ?? edition.accent.withValues(alpha: .45)),
  );

  Widget cover(double size) => SizedBox(
    key: const ValueKey('reading-moment-book-cover'),
    width: size,
    height: size * 1.48,
    child: Image.memory(
      presentation.coverBytes!,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      semanticLabel: completion!.title.isEmpty
          ? '书籍封面'
          : '${completion!.title} 封面',
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    ),
  );

  Widget recordIdentity(Color ink, Color muted) {
    final name = presentation.showBookDetails
        ? completion!.title.trim()
        : '珍藏这一段阅读';
    final author = presentation.showBookDetails
        ? completion!.author.trim()
        : '';
    final words = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (name.isNotEmpty)
          text(
            name,
            size: compact ? 19 : 25,
            color: ink,
            weight: FontWeight.w600,
            height: 1.4,
          ),
        if (author.isNotEmpty) ...[
          const SizedBox(height: 5),
          text(author, size: 13, color: muted),
        ],
      ],
    );
    if (!hasCover) return words;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        cover(width * (compact ? .19 : .22)),
        const SizedBox(width: 15),
        Expanded(child: words),
      ],
    );
  }

  Widget eventBody({Color? foreground, Color? muted, EdgeInsets? padding}) {
    final ink = foreground ?? edition.foreground;
    final secondary = muted ?? edition.muted;
    return Padding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            gutter,
            compact ? 18 : 26,
            gutter,
            compact ? 20 : 30,
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: completion == null
            ? [
                text(
                  moment.title,
                  size: compact ? 19 : 24,
                  color: ink,
                  weight: FontWeight.w600,
                ),
                const SizedBox(height: 9),
                text(moment.subtitle, size: 13, color: secondary, height: 1.65),
              ]
            : [
                recordIdentity(ink, secondary),
                if (hasMeasurements) ...[
                  const SizedBox(height: 20),
                  rule(color: secondary.withValues(alpha: .3)),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 25,
                    runSpacing: 16,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      if (completion!.verifiedSeconds != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            text('有效阅读', size: 11, color: secondary),
                            const SizedBox(height: 6),
                            text(
                              readingMomentDuration(
                                completion!.verifiedSeconds!,
                              ),
                              size: compact ? 17 : 21,
                              color: ink,
                              weight: FontWeight.w600,
                            ),
                          ],
                        ),
                      if (completion!.readingDays > 0 ||
                          completion!.verifiedSeconds != null ||
                          completion!.firstReadAt != null ||
                          completion!.lastReadAt != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            text(
                              '${completion!.readingDays}',
                              size: compact ? 28 : 40,
                              color: ink,
                              display: true,
                              height: 1,
                            ),
                            const SizedBox(height: 5),
                            text('个阅读日', size: 11, color: secondary),
                          ],
                        ),
                    ],
                  ),
                  if (completion!.firstReadAt != null ||
                      completion!.lastReadAt != null) ...[
                    const SizedBox(height: 13),
                    text(
                      completion!.firstReadAt != null &&
                              completion!.lastReadAt != null
                          ? '${readingMomentDate(completion!.firstReadAt!)} — ${readingMomentDate(completion!.lastReadAt!)}'
                          : completion!.firstReadAt != null
                          ? '初次已记录阅读 ${readingMomentDate(completion!.firstReadAt!)}'
                          : '最后已记录阅读 ${readingMomentDate(completion!.lastReadAt!)}',
                      size: 11,
                      color: secondary,
                    ),
                  ],
                ],
              ],
      ),
    );
  }

  Widget dossier() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 14 : 24, gutter, 0),
        child: header(),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          compact ? 17 : 26,
          gutter,
          compact ? 16 : 24,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  headline(
                    size: completion == null
                        ? null
                        : compact
                        ? 27
                        : 35,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            artwork(
              artWidth: width * .32,
              height: width * .32 * 4 / 3,
              fit: BoxFit.contain,
              alignment: Alignment.topRight,
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        child: rule(color: edition.accent, height: 6),
      ),
      eventBody(),
    ],
  );

  Widget harbor() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Stack(
        children: [
          artwork(
            asset: readingKeepsakeArt(theme, portrait: true),
            height: width * (compact ? .72 : 1.02),
            alignment: const Alignment(0, .15),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    edition.background.withValues(alpha: .22),
                    edition.background.withValues(alpha: .05),
                    edition.background.withValues(alpha: .98),
                  ],
                  stops: const [0, .35, 1],
                ),
              ),
            ),
          ),
          Positioned(
            top: compact ? 13 : 23,
            left: gutter,
            right: gutter,
            child: header(color: edition.foreground),
          ),
          Positioned(
            left: gutter,
            right: gutter,
            bottom: compact ? 15 : 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                headline(
                  size: completion == null
                      ? compact
                            ? 54
                            : 78
                      : compact
                      ? 27
                      : 38,
                ),
              ],
            ),
          ),
        ],
      ),
      eventBody(),
    ],
  );

  Widget seasons() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 13 : 23, gutter, 16),
        child: header(),
      ),
      panorama(margin: EdgeInsets.symmetric(horizontal: gutter)),
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 14 : 22, gutter, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [headline()],
        ),
      ),
      eventBody(),
    ],
  );

  Widget night() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 13 : 23, gutter, 0),
        child: header(),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 17 : 27, gutter, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  text(
                    '${moment.earnedAt.hour.toString().padLeft(2, '0')}:'
                    '${moment.earnedAt.minute.toString().padLeft(2, '0')}',
                    size: compact ? 28 : 39,
                    display: true,
                    height: 1.1,
                  ),
                  const SizedBox(height: 5),
                  text('留念时刻', size: 10.5, color: edition.muted),
                  const SizedBox(height: 24),
                  headline(
                    size: completion != null
                        ? compact
                              ? 25
                              : 32
                        : compact
                        ? 50
                        : 77,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            artwork(artWidth: width * .43, height: width * .43 * 16 / 9),
          ],
        ),
      ),
      eventBody(),
    ],
  );

  Widget paperEcho() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 13 : 24, gutter, 0),
        child: header(),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 14 : 23, gutter, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  headline(
                    size: completion != null
                        ? compact
                              ? 27
                              : 36
                        : compact
                        ? 59
                        : 88,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 13),
            artwork(
              artWidth: width * .45,
              height: width * .45 * 4 / 3,
              fit: BoxFit.contain,
              alignment: Alignment.topRight,
            ),
          ],
        ),
      ),
      const SizedBox(height: 17),
      ClipPath(
        clipper: const _MomentPaperEdge(),
        child: ColoredBox(
          color: const Color(0xfff4f2e9),
          child: eventBody(
            foreground: const Color(0xff292b28),
            muted: const Color(0xff71736a),
            padding: EdgeInsets.fromLTRB(
              gutter,
              compact ? 22 : 31,
              gutter,
              compact ? 21 : 31,
            ),
          ),
        ),
      ),
    ],
  );

  Widget film() => CustomPaint(
    foregroundPainter: _MomentFilmEdges(edition.muted),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              gutter - 10,
              compact ? 14 : 24,
              gutter - 10,
              16,
            ),
            child: header(),
          ),
          panorama(),
          Padding(
            padding: EdgeInsets.fromLTRB(
              gutter - 10,
              compact ? 17 : 26,
              gutter - 10,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [headline()],
            ),
          ),
          eventBody(
            padding: EdgeInsets.fromLTRB(
              gutter - 10,
              compact ? 18 : 26,
              gutter - 10,
              compact ? 22 : 32,
            ),
          ),
        ],
      ),
    ),
  );

  Widget mountain() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 13 : 23, gutter, 16),
        child: header(),
      ),
      panorama(),
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 18 : 28, gutter, 0),
        child: Container(
          padding: const EdgeInsets.only(left: 16),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: edition.accent, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              headline(
                size: completion == null
                    ? compact
                          ? 58
                          : 90
                    : compact
                    ? 28
                    : 41,
              ),
            ],
          ),
        ),
      ),
      eventBody(),
    ],
  );

  Widget postcard() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 14 : 24, gutter, 16),
        child: header(),
      ),
      panorama(margin: EdgeInsets.symmetric(horizontal: gutter), frame: 6),
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 17 : 26, gutter, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            headline(),
            const SizedBox(height: 18),
            CustomPaint(
              painter: _MomentPostmark(edition.accent),
              size: Size(width - gutter * 2, 5),
            ),
          ],
        ),
      ),
      eventBody(),
    ],
  );
}

class _MomentPaperEdge extends CustomClipper<Path> {
  const _MomentPaperEdge();
  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, 5);
    for (var x = 0.0; x < size.width; x += 16) {
      path
        ..lineTo(x + 8, 0)
        ..lineTo(x + 16, 5);
    }
    return path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_MomentPaperEdge old) => false;
}

class _MomentFilmEdges extends CustomPainter {
  const _MomentFilmEdges(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: .4);
    for (var y = 18.0; y < size.height - 15; y += 23) {
      for (final x in [3.0, size.width - 10]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 7, 11),
            const Radius.circular(1),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MomentFilmEdges old) => color != old.color;
}

class _MomentPostmark extends CustomPainter {
  const _MomentPostmark(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 13) {
      canvas.drawLine(
        Offset(x, 2),
        Offset(x + 6, 2),
        Paint()
          ..color = color.withValues(alpha: .65)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_MomentPostmark old) => color != old.color;
}

String readingMomentDate(DateTime value) =>
    '${value.year}.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')}';
String readingMomentDuration(int seconds) => seconds < 60
    ? '$seconds 秒'
    : seconds < 3600
    ? '${seconds ~/ 60} 分钟'
    : '${seconds ~/ 3600} 小时 ${seconds % 3600 ~/ 60} 分钟';
