import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'archive_design.dart';
import 'archive_shelf_geometry.dart';

enum SkeletonLayout {
  library,
  search,
  detail,
  reader,
  bookRow,
  history,
  actions,
  inline,
  button,
  cover,
}

/// Static placeholders: no shimmer, repeating ticker, filter or loading mascot.
/// Decorative shapes have one accessible loading label, not separate controls.
class LoadingSkeleton extends StatelessWidget {
  const LoadingSkeleton({
    super.key,
    required this.layout,
    this.topInset = 0,
    this.label = '正在加载',
  });
  final SkeletonLayout layout;
  final double topInset;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            key: ValueKey('skeleton-${layout.name}'),
            painter: _SkeletonPainter(
              layout: layout,
              top: topInset,
              ink: Theme.of(context).colorScheme.onSurface,
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

class _SkeletonPainter extends CustomPainter {
  const _SkeletonPainter({
    required this.layout,
    required this.top,
    required this.ink,
    required this.dark,
  });
  final SkeletonLayout layout;
  final double top;
  final Color ink;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = ink.withValues(alpha: dark ? .0825 : .0625);
    void block(double x, double y, double w, double h, [double radius = 2]) {
      if (w <= 0 || h <= 0) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, h),
          Radius.circular(radius),
        ),
        fill,
      );
    }

    if (layout == SkeletonLayout.bookRow) {
      block(0, 13, 56, 76, ArchiveDesign.coverRadius);
      block(71, 20, 65, 7);
      block(71, 35, (size.width - 93) * .87, 15);
      block(71, 64, (size.width - 93) * .55, 10);
      return;
    }
    if (layout == SkeletonLayout.inline) {
      block(0, (size.height - 8) / 2, size.width * .78, 8);
      return;
    }
    if (layout == SkeletonLayout.button) {
      final y = (size.height - 12) / 2;
      block(0, y, 12, 12);
      block(22, y + 2, size.width - 22, 8);
      return;
    }
    if (layout == SkeletonLayout.cover) {
      final inset = size.width * .12;
      block(inset, inset, size.width - inset * 2, size.height * .52);
      block(inset, size.height * .74, size.width * .64, 5);
      block(inset, size.height * .83, size.width * .43, 4);
      return;
    }
    if (layout == SkeletonLayout.history || layout == SkeletonLayout.actions) {
      block(16, 19, (size.width - 32) * .78, 15);
      block(16, 48, (size.width - 32) * .51, 10);
      if (layout == SkeletonLayout.history) {
        block(16, 70, (size.width - 32) * .63, 10);
      }
      return;
    }
    if (layout == SkeletonLayout.detail) {
      block(0, 0, 54, 18);
      for (var i = 0; i < 4; i++) {
        block(0, 39 + i * 22, size.width * (i == 3 ? .68 : 1), 11);
      }
      block(0, 158, 54, 18);
      for (var i = 0; i < 3; i++) {
        final y = 198.0 + i * 45;
        block(0, y, 20, 11);
        block(42, y, size.width * (i == 1 ? .52 : .69), 12);
      }
      return;
    }
    if (layout == SkeletonLayout.reader) {
      for (var i = 0; i < 12; i++) {
        block(
          i % 4 == 0 ? 24 : 0,
          i * 25,
          size.width * (i % 4 == 3 ? .64 : .94) - (i % 4 == 0 ? 24 : 0),
          11,
        );
      }
      return;
    }
    const left = 24.0;
    final content = size.width - 48;
    var y = top;
    if (layout == SkeletonLayout.library) {
      block(left, y, 66, 7);
      block(left, y + 19, 90, 18);
      y += 58;
      final cover = ArchiveShelfGeometry.coverFor(content);
      final rowHeight = ArchiveShelfGeometry.rowHeight(
        cover,
        ArchiveShelfGeometry.bodyHeight(cover),
      );
      canvas.save();
      canvas.translate(left, y);
      _ArchiveShelfSkeletonPainter(
        dark: dark,
        ink: ink,
      ).paint(canvas, Size(content, rowHeight));
      canvas.restore();
      y += rowHeight + 16;
      block(left, y, content * .65, 15);
      block(left, y + 29, content * .43, 10);
      block(left, y + 65, content * .5, 7);
      y += 104;
    }
    block(left, y, 66, 7);
    block(left, y + 19, 90, 18);
    y += 54;
    for (var i = 0; i < 6 && y < size.height - 74; i++) {
      block(left, y, 56, 76, ArchiveDesign.coverRadius);
      block(left + 74, y + 9, (content - 74) * .8, 15);
      block(left + 74, y + 35, (content - 74) * .5, 10);
      block(left + 74, y + 57, (content - 74) * .94, 10);
      y += 101;
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter oldDelegate) =>
      layout != oldDelegate.layout ||
      top != oldDelegate.top ||
      ink != oldDelegate.ink ||
      dark != oldDelegate.dark;
}

class LibrarySkeleton extends StatelessWidget {
  const LibrarySkeleton({super.key, this.header});
  final Widget? header;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在翻开文库',
    liveRegion: true,
    container: true,
    explicitChildNodes: true,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        maxHeight: double.infinity,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.paddingOf(context).top + 76,
            24,
            0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header ??
                  const SizedBox(
                    height: 44,
                    child: LoadingSkeleton(layout: SkeletonLayout.actions),
                  ),
              const SizedBox(height: 14),
              const ArchiveShelfSkeleton(),
              const SizedBox(height: 32),
              const SizedBox(
                height: 44,
                child: LoadingSkeleton(layout: SkeletonLayout.actions),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < 3; i++) const BookRowSkeleton(),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A static parallel file bank, with the same solids, crest and allocated space
/// as the loaded carousel. No legacy featured-card panel, shimmer or ticker.
class ArchiveShelfSkeleton extends StatelessWidget {
  const ArchiveShelfSkeleton({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cover = ArchiveShelfGeometry.coverFor(constraints.maxWidth);
          final height = ArchiveShelfGeometry.bodyHeight(cover);
          final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('archive-shelf-skeleton'),
                  painter: _ArchiveShelfSkeletonPainter(
                    dark: Theme.of(context).brightness == Brightness.dark,
                    ink: Theme.of(context).colorScheme.onSurface,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: ArchiveShelfGeometry.rowHeight(cover, height),
                  ),
                ),
              ),
              SizedBox(
                height: 16 + 17 * 1.35 * 2 * scale + 12 * 1.4 * scale,
                child: const LoadingSkeleton(layout: SkeletonLayout.actions),
              ),
              const SizedBox(
                height: 40,
                child: LoadingSkeleton(layout: SkeletonLayout.inline),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _ArchiveShelfSkeletonPainter extends CustomPainter {
  const _ArchiveShelfSkeletonPainter({required this.dark, required this.ink});
  final bool dark;
  final Color ink;
  @override
  void paint(Canvas canvas, Size size) {
    final g = ArchiveShelfGeometry.coverFor(size.width);
    final h = ArchiveShelfGeometry.bodyHeight(g);
    final spine = ArchiveShelfGeometry.spineFor(size.width);
    final pitch = ArchiveShelfGeometry.pitchFor(size.width);
    final centre =
        size.width / 2 -
        ArchiveShelfGeometry.footprint(spine, g) / 2 +
        ArchiveShelfGeometry.pullDistance(g) * ArchiveShelfGeometry.depthX;
    final edge = (size.width / pitch / 2).ceil() + 5;
    final base = dark ? ArchiveDesign.darkSurface : ArchiveDesign.milk;
    final rule = Paint()
      ..color = ink.withValues(alpha: .12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .4;
    final placeholder = Paint()
      ..color = ink.withValues(alpha: dark ? .0825 : .0625);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = -edge; i <= edge; i++) {
      final weight = i.abs() < 1.48
          ? math.pow(math.cos(i / 1.48 * math.pi / 2), 2).toDouble()
          : 0.0;
      final origin =
          ArchiveShelfGeometry.origin(g, h, weight) +
          Offset(centre + i * pitch, ArchiveShelfGeometry.railY(i.toDouble()));
      final front = Offset(spine, spine * .1);
      final depth = Offset(
        g * ArchiveShelfGeometry.depthX,
        g * ArchiveShelfGeometry.depthY,
      );
      final side = Path()
        ..addPolygon([
          origin + front,
          origin + front + depth,
          origin + front + depth + Offset(0, h),
          origin + front + Offset(0, h),
        ], true);
      canvas.drawPath(side, Paint()..color = base);
      canvas.drawPath(side, rule);
      // Cover and two metadata bands are projected onto the same face, rather
      // than floating screen-space rectangles over neighbouring files.
      canvas.save();
      canvas.transform(
        (Matrix4.identity()
              ..setEntry(0, 0, ArchiveShelfGeometry.depthX)
              ..setEntry(1, 0, ArchiveShelfGeometry.depthY)
              ..setEntry(0, 3, origin.dx + spine)
              ..setEntry(1, 3, origin.dy + spine * .1))
            .storage,
      );
      canvas.drawRect(Rect.fromLTWH(10, 10, g - 20, h - 54), placeholder);
      canvas.drawRect(Rect.fromLTWH(10, h - 31, (g - 20) * .7, 5), placeholder);
      canvas.drawRect(
        Rect.fromLTWH(10, h - 18, (g - 20) * .45, 4),
        placeholder,
      );
      canvas.restore();
      final top = Path()
        ..addPolygon([
          origin,
          origin + front,
          origin + front + depth,
          origin + depth,
        ], true);
      canvas.drawPath(top, Paint()..color = Color.lerp(base, ink, .035)!);
      canvas.drawPath(top, rule);
      final face = Path()
        ..addPolygon([
          origin,
          origin + front,
          origin + front + Offset(0, h),
          origin + Offset(0, h),
        ], true);
      canvas.drawPath(face, Paint()..color = Color.lerp(base, ink, .065)!);
      canvas.drawPath(face, rule);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArchiveShelfSkeletonPainter oldDelegate) =>
      dark != oldDelegate.dark || ink != oldDelegate.ink;
}

class SearchSkeleton extends StatelessWidget {
  const SearchSkeleton({super.key});
  @override
  Widget build(BuildContext context) => LoadingSkeleton(
    layout: SkeletonLayout.search,
    topInset: MediaQuery.paddingOf(context).top + 76,
    label: '正在找故事',
  );
}

class DetailSkeleton extends StatelessWidget {
  const DetailSkeleton({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 310,
    width: double.infinity,
    child: LoadingSkeleton(layout: SkeletonLayout.detail, label: '正在打开这本书'),
  );
}

/// Reserve a real metadata line without showing an unconfirmed count or label.
class InlineSkeleton extends StatelessWidget {
  const InlineSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 18,
    this.label = '正在加载信息',
  });
  final double width;
  final double height;
  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: LoadingSkeleton(layout: SkeletonLayout.inline, label: label),
  );
}

class ReaderSkeleton extends StatelessWidget {
  const ReaderSkeleton({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 300,
    width: double.infinity,
    child: LoadingSkeleton(layout: SkeletonLayout.reader, label: '正在加载正文'),
  );
}

class BookRowSkeleton extends StatelessWidget {
  const BookRowSkeleton({super.key, this.label = '正在载入书籍'});
  final String label;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 102,
    width: double.infinity,
    child: LoadingSkeleton(layout: SkeletonLayout.bookRow, label: label),
  );
}
