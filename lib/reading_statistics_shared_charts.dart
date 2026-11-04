import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'performance_preferences.dart';

enum ReadingChartPresentation { dashboard, archive, shelf, narrative, night }

/// Keep axis captions separate; every bar/value remains in the semantic data.
Set<int> readingAxisLabelIndices(
  List<Rect> bounds, {
  Iterable<int> preferred = const [],
  bool fill = true,
  double gap = 4,
}) {
  final selected = <int>{};
  for (final index in [
    ...preferred,
    if (fill) ...List.generate(bounds.length, (i) => i),
  ]) {
    if (index < 0 || index >= bounds.length || selected.contains(index)) {
      continue;
    }
    final rect = bounds[index];
    if (selected.every(
      (other) =>
          rect.left >= bounds[other].right + gap ||
          rect.right + gap <= bounds[other].left,
    )) {
      selected.add(index);
    }
  }
  return selected;
}

/// The dashboard and PNG capture mount this exact monthly component.
class ReadingMonthlyChart extends StatelessWidget {
  const ReadingMonthlyChart({
    super.key,
    required this.dates,
    required this.seconds,
    this.reduceMotion = false,
    this.height = 178,
    this.presentation = ReadingChartPresentation.dashboard,
  });
  final List<DateTime> dates;
  final List<int?> seconds;
  final bool reduceMotion;
  final double height;
  final ReadingChartPresentation presentation;
  @override
  Widget build(BuildContext context) => ReadingStatisticsBars(
    labels: [
      for (var i = 0; i < dates.length; i++)
        i == 0 || dates[i].month == 1
            ? '${dates[i].month}/${dates[i].year % 100}'
            : '${dates[i].month}',
    ],
    values: [for (final value in seconds) value == null ? null : value / 3600],
    semanticLabel: '月度阅读时长 · 小时',
    allLabels: true,
    height: height,
    presentation: presentation,
    reduceMotion: reduceMotion,
  );
}

/// Retained bar geometry: animation ticks never re-layout axis text.
class ReadingStatisticsBars extends StatefulWidget {
  const ReadingStatisticsBars({
    super.key,
    required this.labels,
    required this.values,
    required this.semanticLabel,
    this.height = 108,
    this.allLabels = false,
    this.reduceMotion = false,
    this.presentation = ReadingChartPresentation.dashboard,
  });
  final List<String> labels;
  final List<double?> values;
  final String semanticLabel;
  final double height;
  final bool allLabels, reduceMotion;
  final ReadingChartPresentation presentation;
  @override
  State<ReadingStatisticsBars> createState() => _ReadingStatisticsBarsState();
}

class _ReadingStatisticsBarsState extends State<ReadingStatisticsBars> {
  ui.Picture? _guides, _bars;
  Object? _key;
  @override
  void dispose() {
    _guides?.dispose();
    _bars?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: appText(context, widget.semanticLabel),
    value: [
      for (
        var i = 0;
        i < math.min(widget.labels.length, widget.values.length);
        i++
      )
        '${widget.labels[i]} ${widget.values[i] == null ? '尚未记录' : widget.values[i]!.toStringAsFixed(1)}',
    ].join('，'),
    child: SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          final scheme = Theme.of(context).colorScheme;
          final key = (
            size,
            Object.hashAll(widget.labels),
            Object.hashAll(widget.values),
            scheme.primary,
            scheme.onSurfaceVariant,
            widget.allLabels,
            widget.presentation,
          );
          if (_key != key) {
            _key = key;
            _guides?.dispose();
            _bars?.dispose();
            final style = ArchiveDesign.codeStyle(context).copyWith(
              fontSize: 10,
              letterSpacing: 0,
              color: scheme.onSurfaceVariant,
            );
            final guides = ui.PictureRecorder();
            final gc = Canvas(guides);
            final bars = ui.PictureRecorder();
            final bc = Canvas(bars);
            final count = math.min(widget.labels.length, widget.values.length);
            final maximum = widget.values.whereType<double>().fold<double>(
              1,
              math.max,
            );
            final baseline = size.height - 25;
            final stride = size.width / math.max(1, count);
            final axisPainters = <TextPainter>[];
            final axisBounds = <Rect>[];
            for (var i = 0; i < count; i++) {
              final painter = TextPainter(
                text: TextSpan(text: widget.labels[i], style: style),
                textDirection: TextDirection.ltr,
              )..layout(maxWidth: 80);
              final center = stride * (i + .5);
              final left = (center - painter.width / 2)
                  .clamp(0.0, math.max(0, size.width - painter.width))
                  .toDouble();
              axisPainters.add(painter);
              axisBounds.add(
                Rect.fromLTWH(
                  left,
                  baseline + 9,
                  painter.width,
                  painter.height,
                ),
              );
            }
            final axisLabels = readingAxisLabelIndices(
              axisBounds,
              preferred: [
                0,
                count - 1,
                if (widget.allLabels)
                  for (var i = 0; i < count; i++)
                    if (widget.labels[i].contains('/')) i,
              ],
              fill: widget.allLabels,
            );
            gc.drawLine(
              Offset(0, baseline),
              Offset(size.width, baseline),
              Paint()
                ..color = scheme.onSurfaceVariant.withValues(alpha: .2)
                ..strokeWidth = .7,
            );
            for (var i = 0; i < count; i++) {
              final value = widget.values[i];
              final x = stride * (i + .5);
              final width = math.min(
                widget.allLabels ? 28.0 : 18.0,
                stride * .64,
              );
              final height = (baseline - 21) * (value ?? 0) / maximum;
              if (value == null) {
                bc.drawRect(
                  Rect.fromLTWH(x - width / 2, baseline - 3, width, 3),
                  Paint()
                    ..color = scheme.onSurfaceVariant.withValues(alpha: .4)
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = .6,
                );
              } else if (value == 0) {
                bc.drawCircle(
                  Offset(x, baseline),
                  1.2,
                  Paint()..color = scheme.onSurfaceVariant,
                );
              } else if (widget.presentation ==
                  ReadingChartPresentation.shelf) {
                final rect = Rect.fromLTWH(
                  x - width / 2,
                  baseline - height,
                  width,
                  height,
                );
                bc.drawRect(
                  rect,
                  Paint()
                    ..color = value == maximum
                        ? scheme.primary
                        : scheme.surface,
                );
                bc.drawRect(
                  rect,
                  Paint()
                    ..color = scheme.onSurfaceVariant.withValues(alpha: .4)
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = .7,
                );
                bc.drawLine(
                  Offset(rect.left + 3, rect.top + 4),
                  Offset(rect.left + 3, rect.bottom - 4),
                  Paint()
                    ..color = value == maximum
                        ? scheme.surface.withValues(alpha: .5)
                        : scheme.onSurfaceVariant.withValues(alpha: .16)
                    ..strokeWidth = .7,
                );
              } else {
                bc.drawRRect(
                  RRect.fromRectAndRadius(
                    Rect.fromLTWH(
                      x - width / 2,
                      baseline - height,
                      width,
                      height,
                    ),
                    const Radius.circular(1.5),
                  ),
                  Paint()
                    ..color =
                        widget.presentation == ReadingChartPresentation.archive
                        ? value == maximum
                              ? scheme.primary
                              : scheme.onSurface.withValues(alpha: .30)
                        : scheme.primary.withValues(
                            alpha: value == maximum
                                ? 1
                                : widget.presentation ==
                                      ReadingChartPresentation.narrative
                                ? .25
                                : .45,
                          ),
                );
              }
              if (axisLabels.contains(i)) {
                axisPainters[i].paint(gc, axisBounds[i].topLeft);
              }
              if (widget.allLabels &&
                  widget.presentation != ReadingChartPresentation.narrative &&
                  count <= 14 &&
                  value != null &&
                  height > 16) {
                final painter = TextPainter(
                  text: TextSpan(
                    text: value > 0 && value < .1
                        ? '<0.1'
                        : value < 1
                        ? value.toStringAsFixed(1)
                        : '${value.round()}',
                    style: style.copyWith(fontSize: 9),
                  ),
                  textDirection: TextDirection.ltr,
                )..layout();
                painter.paint(
                  gc,
                  Offset(x - painter.width / 2, baseline - height - 17),
                );
                painter.dispose();
              }
            }
            for (final painter in axisPainters) {
              painter.dispose();
            }
            _guides = guides.endRecording();
            _bars = bars.endRecording();
          }
          final reduced =
              widget.reduceMotion ||
              MediaQuery.disableAnimationsOf(context) ||
              PerformanceScope.reduceMotionOf(context);
          return TweenAnimationBuilder<double>(
            key: ValueKey(_key),
            tween: Tween(begin: 0, end: 1),
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 340),
            curve: NovelMotion.settle,
            builder: (context, progress, _) => RepaintBoundary(
              child: CustomPaint(
                painter: _RetainedBars(_guides!, _bars!, progress),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _RetainedBars extends CustomPainter {
  const _RetainedBars(this.guides, this.bars, this.progress);
  final ui.Picture guides, bars;
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPicture(guides);
    canvas.save();
    canvas.translate(0, size.height - 25);
    canvas.scale(1, progress);
    canvas.translate(0, -(size.height - 25));
    canvas.drawPicture(bars);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RetainedBars old) =>
      guides != old.guides || bars != old.bars || progress != old.progress;
}

class ReadingProgressBands extends StatelessWidget {
  const ReadingProgressBands({
    super.key,
    required this.bands,
    this.reduceMotion = false,
    this.compact = false,
    this.labelSize = 12,
  });
  final List<int> bands;
  final bool reduceMotion;
  final bool compact;
  final double labelSize;
  @override
  Widget build(BuildContext context) {
    final maximum = bands.fold(1, math.max);
    return Column(
      children: [
        for (var i = 0; i < math.min(4, bands.length); i++)
          Padding(
            padding: EdgeInsets.symmetric(vertical: compact ? 4 : 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: AppText(
                        const ['0–25%', '25–50%', '50–75%', '75–100%'][i],
                        style: TextStyle(fontSize: labelSize),
                      ),
                    ),
                    AppText(
                      '${bands[i]} 本',
                      style: TextStyle(fontSize: labelSize),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 4 : 7),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: bands[i] / maximum),
                  duration:
                      reduceMotion || MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 300),
                  curve: NovelMotion.settle,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: value,
                    minHeight: 3,
                    color: Theme.of(context).colorScheme.primary,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .08),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class ReadingActivityRing extends StatelessWidget {
  const ReadingActivityRing({
    super.key,
    required this.ratio,
    this.size = 190,
    this.reduceMotion = false,
    this.segmented = false,
    this.caption,
  });
  final double? ratio;
  final double size;
  final bool reduceMotion;
  final bool segmented;
  final String? caption;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ratio ?? 0),
      duration: reduceMotion || MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      curve: NovelMotion.settle,
      builder: (context, value, _) => CustomPaint(
        painter: _ActivityRingPainter(
          value,
          Theme.of(context).colorScheme.primary,
          Theme.of(context).colorScheme.onSurface,
          segmented,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                ratio == null ? '—' : '${(ratio! * 100).round()}%',
                style: TextStyle(
                  fontSize: size * .21,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (caption != null)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: AppText(
                    caption!,
                    style: TextStyle(
                      fontSize: size * .045,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ActivityRingPainter extends CustomPainter {
  const _ActivityRingPainter(this.value, this.ink, this.track, this.segmented);
  final double value;
  final Color ink, track;
  final bool segmented;
  @override
  void paint(Canvas canvas, Size size) {
    if (segmented) {
      const count = 36;
      final center = size.center(Offset.zero);
      final radius = size.width * .37;
      final step = math.pi * 2 / count;
      for (var i = 0; i < count; i++) {
        final active = (value * count - i).clamp(0.0, 1.0);
        final thickness = size.width * (.045 + .045 * active);
        final rect = Rect.fromCircle(
          center: center,
          radius: radius + thickness / 2,
        );
        canvas.drawArc(
          rect,
          -math.pi / 2 + i * step + .025,
          step - .05,
          false,
          Paint()
            ..color = Color.lerp(track.withValues(alpha: .12), ink, active)!
            ..style = PaintingStyle.stroke
            ..strokeWidth = thickness,
        );
      }
      canvas.drawCircle(
        center,
        size.width * .285,
        Paint()..color = track.withValues(alpha: .035),
      );
      return;
    }
    final rect = (Offset.zero & size).deflate(size.width * .10);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .09;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2,
      false,
      pen..color = track.withValues(alpha: .09),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      pen..color = ink,
    );
  }

  @override
  bool shouldRepaint(_ActivityRingPainter old) =>
      old.value != value ||
      old.ink != ink ||
      old.track != track ||
      old.segmented != segmented;
}
