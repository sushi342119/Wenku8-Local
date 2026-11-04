import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app_language.dart';
import 'archive_design.dart';
import 'archive_motion.dart';
import 'reading_statistics_shared_charts.dart';
export 'reading_statistics_shared_charts.dart';

/// Daily distinct book count uses the ledger's actual set, not a time split.
class ReadingBookBreadthChart extends StatelessWidget {
  const ReadingBookBreadthChart({
    super.key,
    required this.dates,
    required this.counts,
  });
  final List<DateTime> dates;
  final List<int?> counts;
  @override
  Widget build(BuildContext context) => Semantics(
    label: appText(context, '每日读过的书籍数量'),
    value: appText(
      context,
      [
        for (var i = 0; i < math.min(dates.length, counts.length); i++)
          '${_dateLabel(dates[i])} ${counts[i] == null ? '尚未记录' : '${counts[i]} 本'}',
      ].join('，'),
    ),
    child: ReadingStatisticsBars(
      labels: [for (final date in dates) '${date.month}.${date.day}'],
      values: [for (final count in counts) count?.toDouble()],
      semanticLabel: '每日读过的书籍数量',
      height: 108,
    ),
  );
}

/// A bounded reading trace. Null days deliberately break both curves:
/// absence of a measurement must never look like a measured zero.
class ReadingRhythmChart extends StatefulWidget {
  const ReadingRhythmChart({
    super.key,
    required this.dates,
    required this.minutes,
    required this.averageMinutes,
    required this.selectedIndex,
    required this.onSelected,
    this.entrance,
    this.reduceMotion = false,
  });

  final List<DateTime> dates;
  final List<double?> minutes;
  final List<double?> averageMinutes;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Animation<double>? entrance;
  final bool reduceMotion;

  @override
  State<ReadingRhythmChart> createState() => _ReadingRhythmChartState();
}

class _ReadingRhythmChartState extends State<ReadingRhythmChart>
    with SingleTickerProviderStateMixin {
  late final _change = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    value: 1,
  )..addStatusListener(_releaseSnapshot);
  _RhythmFrame? _frame;
  _RhythmPainter? _lastPainter;
  ui.Picture? _previousSnapshot;
  bool _dataChanged = false;

  void _releaseSnapshot(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _previousSnapshot?.dispose();
    _previousSnapshot = null;
  }

  @override
  void didUpdateWidget(ReadingRhythmChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _dataChanged =
        !listEquals(widget.dates, oldWidget.dates) ||
        !listEquals(widget.minutes, oldWidget.minutes) ||
        !listEquals(widget.averageMinutes, oldWidget.averageMinutes);
  }

  @override
  void dispose() {
    _change.dispose();
    _previousSnapshot?.dispose();
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dates = widget.dates;
    final minutes = widget.minutes;
    final averageMinutes = widget.averageMinutes;
    final selectedIndex = widget.selectedIndex;
    final onSelected = widget.onSelected;
    final scope = ArchiveMotionScope.maybeOf(context);
    final reduceMotion =
        widget.reduceMotion ||
        MediaQuery.disableAnimationsOf(context) ||
        (scope != null && !scope.enabled);
    final entrance = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : widget.entrance ??
              scope?.animation ??
              const AlwaysStoppedAnimation<double>(1);
    if (reduceMotion && _change.value != 1) _change.value = 1;
    final count = math.min(dates.length, minutes.length);
    final selected = count == 0 ? 0 : selectedIndex.clamp(0, count - 1);
    final visibleMinutes = minutes.take(count).toList(growable: false);
    final visibleAverages = List<double?>.generate(
      count,
      (i) => i < averageMinutes.length ? averageMinutes[i] : null,
      growable: false,
    );
    final maximum = _axisMaximum([...visibleMinutes, ...visibleAverages]);
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = ArchiveDesign.codeStyle(
      context,
    ).copyWith(fontSize: 10, letterSpacing: 0);
    final selectedValue = count == 0
        ? '尚未记录'
        : '${_dateLabel(dates[selected])}，${_durationLabel(minutes[selected])}';

    void select(int index) {
      if (count == 0) return;
      final next = index.clamp(0, count - 1);
      if (next != selected) onSelected(next);
    }

    return Semantics(
      label: appText(context, '阅读时长曲线'),
      value: appText(context, selectedValue),
      increasedValue: count > 0 && selected < count - 1
          ? appText(context, _dateLabel(dates[selected + 1]))
          : null,
      decreasedValue: count > 0 && selected > 0
          ? appText(context, _dateLabel(dates[selected - 1]))
          : null,
      onIncrease: count > 0 && selected < count - 1
          ? () => select(selected + 1)
          : null,
      onDecrease: count > 0 && selected > 0 ? () => select(selected - 1) : null,
      child: RepaintBoundary(
        child: SizedBox(
          height: 204,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, 204);
              final bounds = _rhythmBounds(size);
              final oldFrame = _frame;
              if (oldFrame == null ||
                  !oldFrame.matches(
                    size,
                    dates,
                    visibleMinutes,
                    visibleAverages,
                    scheme.onSurface,
                    scheme.onSurfaceVariant,
                    labelStyle,
                  )) {
                final animateChange =
                    _dataChanged &&
                    !reduceMotion &&
                    oldFrame != null &&
                    oldFrame.size == size;
                final snapshot = animateChange
                    ? _lastPainter?.snapshot()
                    : null;
                _previousSnapshot?.dispose();
                _previousSnapshot = snapshot;
                _frame = _RhythmFrame(
                  size: size,
                  dates: dates.take(count).toList(growable: false),
                  minutes: visibleMinutes,
                  averages: visibleAverages,
                  maximum: maximum,
                  ink: scheme.onSurface,
                  muted: scheme.onSurfaceVariant,
                  style: labelStyle,
                );
                oldFrame?.dispose();
                if (snapshot != null) {
                  _change.forward(from: 0);
                } else {
                  _change.value = 1;
                }
              }
              _dataChanged = false;
              final painter = _RhythmPainter(
                frame: _frame!,
                previousSnapshot: _previousSnapshot,
                entrance: entrance,
                change: _change,
                selectedIndex: selected,
                surface: scheme.surface,
              );
              _lastPainter = painter;
              void selectAt(Offset position) => select(
                count < 2
                    ? 0
                    : ((position.dx - bounds.left) / bounds.width * (count - 1))
                          .round(),
              );

              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('reading-rhythm-gesture'),
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTapUp: count == 0
                          ? null
                          : (details) => selectAt(details.localPosition),
                      onHorizontalDragStart: count == 0
                          ? null
                          : (details) => selectAt(details.localPosition),
                      onHorizontalDragUpdate: count == 0
                          ? null
                          : (details) => selectAt(details.localPosition),
                      child: CustomPaint(painter: painter),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ExcludeSemantics(
                      child: Row(
                        children: [
                          AppText(
                            '分钟',
                            style: labelStyle,
                            textScaler: TextScaler.noScaling,
                          ),
                          const Spacer(),
                          _TraceLegend(
                            label: '每日',
                            color: scheme.onSurface,
                            style: labelStyle,
                          ),
                          const SizedBox(width: 14),
                          _TraceLegend(
                            label: '7 日均值',
                            color: scheme.onSurfaceVariant,
                            style: labelStyle,
                            dashed: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TraceLegend extends StatelessWidget {
  const _TraceLegend({
    required this.label,
    required this.color,
    required this.style,
    this.dashed = false,
  });

  final String label;
  final Color color;
  final TextStyle style;
  final bool dashed;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 16,
        child: Row(
          children: [
            Expanded(
              child: ColoredBox(color: color, child: const SizedBox(height: 1)),
            ),
            if (dashed) ...[
              const SizedBox(width: 3),
              Expanded(
                child: ColoredBox(
                  color: color,
                  child: const SizedBox(height: 1),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(width: 5),
      AppText(label, style: style, textScaler: TextScaler.noScaling),
    ],
  );
}

Rect _rhythmBounds(Size size) => Rect.fromLTRB(
  math.min(38, size.width * .2),
  32,
  math.max(1, size.width - 7),
  size.height - 28,
);

double? _measurement(double? value) =>
    value == null || !value.isFinite ? null : math.max(0, value);

double _axisMaximum(Iterable<double?> values) {
  final maxValue = values.fold<double>(
    0,
    (current, value) => math.max(current, _measurement(value) ?? 0),
  );
  if (maxValue == 0) return 30;
  if (maxValue <= 1) return 1;
  final power = math
      .pow(10, (math.log(maxValue) / math.ln10).floor())
      .toDouble();
  final factor = maxValue / power;
  return (factor <= 1
          ? 1
          : factor <= 2
          ? 2
          : factor <= 5
          ? 5
          : 10) *
      power;
}

/// Geometry is separated from painting so its bounds remain inexpensive to
/// verify. A missing sample retains its place on the time axis.
List<Offset?> readingRhythmPoints({
  required List<double?> values,
  required Rect bounds,
  required double maximum,
}) => List<Offset?>.generate(values.length, (index) {
  final value = _measurement(values[index]);
  if (value == null) return null;
  return Offset(
    values.length == 1
        ? bounds.center.dx
        : bounds.left + bounds.width * index / (values.length - 1),
    bounds.bottom - bounds.height * (value / maximum).clamp(0, 1),
  );
}, growable: false);

/// Each cubic's control polygon stays between its two real measurements. This
/// shape-preserving interpolation cannot create a peak or a negative duration.
Path readingRhythmPath(List<Offset?> points) {
  final path = Path();
  Offset? previous;
  for (final point in points) {
    if (point == null) {
      previous = null;
      continue;
    }
    if (previous == null) {
      path.moveTo(point.dx, point.dy);
    } else {
      final middle = (previous.dx + point.dx) / 2;
      path.cubicTo(middle, previous.dy, middle, point.dy, point.dx, point.dy);
    }
    previous = point;
  }
  return path;
}

/// All geometry and text layout are retained for the finite paint animation.
/// Selection and clock ticks never rebuild paths or lay out the axis labels.
class _RhythmFrame {
  _RhythmFrame({
    required this.size,
    required this.dates,
    required this.minutes,
    required this.averages,
    required this.maximum,
    required this.ink,
    required this.muted,
    required this.style,
  }) {
    bounds = _rhythmBounds(size);
    points = readingRhythmPoints(
      values: minutes,
      bounds: bounds,
      maximum: maximum,
    );
    line = readingRhythmPath(points);
    average = _dashedPath(
      readingRhythmPath(
        readingRhythmPoints(values: averages, bounds: bounds, maximum: maximum),
      ),
    );
    area = _rhythmArea(points, bounds.bottom);
    isolated = [
      for (var i = 0; i < points.length; i++)
        if (points[i] != null &&
            (i == 0 || points[i - 1] == null) &&
            (i == points.length - 1 || points[i + 1] == null))
          points[i]!,
    ];
    final recorder = ui.PictureRecorder();
    _paintGuides(Canvas(recorder));
    guides = recorder.endRecording();
  }
  final Size size;
  final List<DateTime> dates;
  final List<double?> minutes;
  final List<double?> averages;
  final double maximum;
  final Color ink;
  final Color muted;
  final TextStyle style;
  late final Rect bounds;
  late final List<Offset?> points;
  late final List<Offset> isolated;
  late final Path line;
  late final Path average;
  late final Path area;
  late final ui.Picture guides;

  bool matches(
    Size nextSize,
    List<DateTime> nextDates,
    List<double?> nextMinutes,
    List<double?> nextAverages,
    Color nextInk,
    Color nextMuted,
    TextStyle nextStyle,
  ) =>
      size == nextSize &&
      listEquals(dates, nextDates) &&
      listEquals(minutes, nextMinutes) &&
      listEquals(averages, nextAverages) &&
      ink == nextInk &&
      muted == nextMuted &&
      style == nextStyle;

  void _paintGuides(Canvas canvas) {
    final grid = Paint()
      ..color = muted.withValues(alpha: .14)
      ..strokeWidth = .6;
    for (var tick = 0; tick <= 2; tick++) {
      final y = bounds.bottom - bounds.height * tick / 2;
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y), grid);
      _paintText(
        canvas,
        _number(maximum * tick / 2),
        Offset(0, y - 6),
        style,
        maxWidth: bounds.left - 7,
      );
    }
    if (dates.isEmpty) return;
    for (final index in <int>{0, dates.length ~/ 2, dates.length - 1}) {
      final date = dates[index];
      final x = dates.length == 1
          ? bounds.center.dx
          : bounds.left + bounds.width * index / (dates.length - 1);
      _paintText(
        canvas,
        '${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}',
        Offset(x, bounds.bottom + 11),
        style,
        alignment: index == 0
            ? 0
            : index == dates.length - 1
            ? 1
            : .5,
      );
    }
  }

  void dispose() => guides.dispose();
}

class _RhythmPainter extends CustomPainter {
  _RhythmPainter({
    required this.frame,
    required this.previousSnapshot,
    required this.entrance,
    required this.change,
    required this.selectedIndex,
    required this.surface,
  }) : super(repaint: Listenable.merge([entrance, change]));

  final _RhythmFrame frame;
  final ui.Picture? previousSnapshot;
  final Animation<double> entrance;
  final Animation<double> change;
  final int selectedIndex;
  final Color surface;

  @visibleForTesting
  Object get debugGeometry => frame;

  ui.Picture snapshot() {
    final recorder = ui.PictureRecorder();
    _paintTransition(Canvas(recorder), frame.size);
    return recorder.endRecording();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // The range's labels change once, while only the measured trace crossfades.
    // Recording labels in both layers would make dates overlap mid-transition.
    canvas.drawPicture(frame.guides);
    _paintTransition(canvas, size);
  }

  void _paintTransition(Canvas canvas, Size size) {
    final mix = Curves.easeOutCubic.transform(change.value.clamp(0, 1));
    if (previousSnapshot != null && mix < 1) {
      _withOpacity(
        canvas,
        Offset.zero & size,
        1 - mix,
        () => canvas.drawPicture(previousSnapshot!),
      );
    }
    _withOpacity(
      canvas,
      Offset.zero & size,
      previousSnapshot == null ? 1 : mix,
      () => _paintCurrent(canvas),
    );
  }

  void _paintCurrent(Canvas canvas) {
    if (frame.dates.isEmpty) return;
    final bounds = frame.bounds;
    final time = entrance.value.clamp(0.0, 1.0);
    final primary = _phase(time, 0, .78);
    final average = _phase(time, .12, .9);
    final area = _phase(time, .55, 1);
    if (area > 0) {
      canvas.drawPath(
        frame.area,
        Paint()..color = frame.ink.withValues(alpha: .045 * area),
      );
    }
    _withHorizontalReveal(
      canvas,
      bounds,
      average,
      () => canvas.drawPath(
        frame.average,
        Paint()
          ..color = frame.muted.withValues(alpha: .58)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      ),
    );
    _withHorizontalReveal(canvas, bounds, primary, () {
      canvas.drawPath(
        frame.line,
        Paint()
          ..color = frame.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7
          ..strokeCap = StrokeCap.round,
      );
      for (final point in frame.isolated) {
        canvas.drawCircle(point, 2.3, Paint()..color = frame.ink);
      }
    });
    final cursorAlpha = _phase(time, .68, 1);
    if (cursorAlpha == 0) return;
    final selectedPoint = frame.points[selectedIndex];
    final selectedX = frame.dates.length == 1
        ? bounds.center.dx
        : bounds.left + bounds.width * selectedIndex / (frame.dates.length - 1);
    canvas.drawLine(
      Offset(selectedX, bounds.top),
      Offset(selectedX, bounds.bottom),
      Paint()
        ..color = frame.muted.withValues(alpha: .3 * cursorAlpha)
        ..strokeWidth = .7,
    );
    if (selectedPoint != null) {
      canvas.drawCircle(
        selectedPoint,
        3.7,
        Paint()..color = surface.withValues(alpha: cursorAlpha),
      );
      canvas.drawCircle(
        selectedPoint,
        3.7,
        Paint()
          ..color = frame.ink.withValues(alpha: cursorAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RhythmPainter old) =>
      frame != old.frame ||
      previousSnapshot != old.previousSnapshot ||
      entrance != old.entrance ||
      change != old.change ||
      selectedIndex != old.selectedIndex ||
      surface != old.surface;
}

/// One week-row dot matrix, arranged in consecutive sections of at most 14 weeks.
/// Sections flow left to right, then wrap at the actual widget or PNG width.
/// [forceMonthly] is retained for old callers and no longer changes the layout.
Size readingCalendarSize(
  List<DateTime> dates,
  double width, {
  bool forceMonthly = false,
  bool showDateAnchors = false,
}) => _CalendarLayout(dates, width, showDateAnchors: showDateAnchors).size;

class ReadingActivityCalendar extends StatefulWidget {
  const ReadingActivityCalendar({
    super.key,
    required this.dates,
    required this.seconds,
    required this.selectedDate,
    required this.onSelected,
    this.entrance,
    this.reduceMotion = false,
    this.forceMonthly = false,
    this.showDateAnchors = false,
  });

  final List<DateTime> dates;
  final List<int?> seconds;
  final DateTime? selectedDate;
  final ValueChanged<DateTime> onSelected;
  final Animation<double>? entrance;
  final bool reduceMotion;

  /// Retained for source compatibility; every range uses the same week rows.
  final bool forceMonthly;

  /// Static date axes for exports, where days cannot be tapped for their date.
  /// Existing interactive calendars retain their compact layout by default.
  final bool showDateAnchors;

  @override
  State<ReadingActivityCalendar> createState() =>
      _ReadingActivityCalendarState();
}

class _ReadingActivityCalendarState extends State<ReadingActivityCalendar>
    with SingleTickerProviderStateMixin {
  late final _change = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  _CalendarFrame? _frame;
  List<_CellAppearance>? _previousAppearance;
  Rect? _selectionFrom;
  Rect? _selectionTo;
  double _selectionFromAlpha = 1;
  bool _selectionChanged = false;

  @override
  void didUpdateWidget(ReadingActivityCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectionChanged = widget.selectedDate != oldWidget.selectedDate;
  }

  @override
  void dispose() {
    _change.dispose();
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dates = widget.dates;
    final seconds = widget.seconds;
    final selectedDate = widget.selectedDate;
    final onSelected = widget.onSelected;
    final scope = ArchiveMotionScope.maybeOf(context);
    final reduceMotion =
        widget.reduceMotion ||
        MediaQuery.disableAnimationsOf(context) ||
        (scope != null && !scope.enabled);
    final entrance = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : widget.entrance ??
              scope?.animation ??
              const AlwaysStoppedAnimation<double>(1);
    if (reduceMotion && _change.value != 1) _change.value = 1;
    final count = math.min(dates.length, seconds.length);
    final visibleDates = dates.take(count).toList(growable: false);
    final visibleSeconds = seconds.take(count).toList(growable: false);
    final maximum = visibleSeconds.fold<int>(
      0,
      (value, item) => math.max(value, item ?? 0),
    );
    final scheme = Theme.of(context).colorScheme;
    final style = ArchiveDesign.codeStyle(
      context,
    ).copyWith(fontSize: 10, letterSpacing: 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _CalendarLayout(
          visibleDates,
          constraints.maxWidth,
          showDateAnchors: widget.showDateAnchors,
        );
        final oldFrame = _frame;
        final dataChanged =
            oldFrame == null ||
            !oldFrame.matches(
              visibleDates,
              visibleSeconds,
              layout,
              scheme.onSurface,
              scheme.onSurfaceVariant,
              style,
            );
        final progress = _phase(_change.value, 0, 1);
        if (dataChanged || _selectionChanged) {
          final currentRect = Rect.lerp(
            _selectionFrom ?? _selectionTo,
            _selectionTo ?? _selectionFrom,
            progress,
          );
          final currentAlpha = ui.lerpDouble(
            _selectionFromAlpha,
            _selectionTo == null ? 0 : 1,
            progress,
          )!;
          final appearances = oldFrame == null
              ? null
              : [
                  for (var i = 0; i < oldFrame.appearances.length; i++)
                    _CellAppearance.lerp(
                      _previousAppearance?[i] ?? oldFrame.appearances[i],
                      oldFrame.appearances[i],
                      progress,
                    ),
                ];
          if (dataChanged) {
            _frame = _CalendarFrame(
              dates: visibleDates,
              seconds: visibleSeconds,
              maximum: maximum,
              layout: layout,
              ink: scheme.onSurface,
              muted: scheme.onSurfaceVariant,
              style: style,
            );
          }
          final nextSelection = _frame!.selectionRect(selectedDate);
          if (oldFrame != null &&
              !reduceMotion &&
              oldFrame.layout.size == layout.size) {
            _previousAppearance = [
              for (var i = 0; i < visibleDates.length; i++)
                _appearanceForDate(
                      visibleDates[i],
                      oldFrame.dates,
                      appearances!,
                    ) ??
                    _frame!.appearances[i],
            ];
            _selectionFrom = currentRect;
            _selectionTo = nextSelection;
            _selectionFromAlpha = currentAlpha;
            _change.forward(from: 0);
          } else {
            _previousAppearance = null;
            _selectionFrom = nextSelection;
            _selectionTo = nextSelection;
            _selectionFromAlpha = nextSelection == null ? 0 : 1;
            _change.value = 1;
          }
          if (dataChanged) oldFrame?.dispose();
        }
        _selectionChanged = false;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: RepaintBoundary(
            child: GestureDetector(
              key: const ValueKey('reading-calendar-gesture'),
              excludeFromSemantics: true,
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                final index = layout.indexAt(details.localPosition);
                if (index != null) onSelected(visibleDates[index]);
              },
              child: CustomPaint(
                size: layout.size,
                painter: _CalendarPainter(
                  frame: _frame!,
                  previousAppearance: _previousAppearance,
                  entrance: entrance,
                  change: _change,
                  selectionFrom: _selectionFrom,
                  selectionTo: _selectionTo,
                  selectionFromAlpha: _selectionFromAlpha,
                  selectedDate: selectedDate,
                  labels: [
                    for (var i = 0; i < count; i++)
                      appText(
                        context,
                        '${_dateLabel(visibleDates[i])}，${_secondsLabel(visibleSeconds[i])}',
                      ),
                  ],
                  onSelected: onSelected,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CalendarLayout {
  _CalendarLayout(
    List<DateTime> dates,
    double width, {
    this.showDateAnchors = false,
  }) : count = dates.length {
    final availableWidth = width.isFinite ? math.max(0.0, width) : 520.0;
    final span = _CalendarWeekSpan(dates);
    rows = span.weeks;
    _positions = [for (final date in dates) span.position(date)];
    final segmentCount = (rows / maximumWeeksPerSegment).ceil();
    final capacity = availableWidth >= 440
        ? 4
        : availableWidth >= 240
        ? 2
        : 1;
    segmentColumns = math.min(capacity, math.max(1, segmentCount));
    final segmentWidth =
        (availableWidth - (segmentColumns - 1) * segmentGap) / segmentColumns;
    final gridWidth = math.max(0.0, segmentWidth - dateGutter);
    columnPitch = math.min(24.0, gridWidth / 7);
    cell = math.min(10.0, math.max(0.0, columnPitch - gap));
    rowPitch = cell + gap;
    segmentInset = dateGutter + (gridWidth - columnPitch * 7) / 2;
    final blocks = <_CalendarSegment>[];
    var top = 0.0;
    for (var start = 0; start < segmentCount; start += segmentColumns) {
      var rowHeight = 0.0;
      for (var column = 0; column < segmentColumns; column++) {
        final index = start + column;
        if (index >= segmentCount) break;
        final firstWeek = index * maximumWeeksPerSegment;
        final weeks = math.min(maximumWeeksPerSegment, rows - firstWeek);
        final height = headerHeight + weeks * rowPitch - gap + bottomPadding;
        final monday = span.monday.add(Duration(days: firstWeek * 7));
        final lastDay = monday.add(Duration(days: weeks * 7 - 1));
        blocks.add(
          _CalendarSegment(
            firstWeek,
            weeks,
            Rect.fromLTWH(
              column * (segmentWidth + segmentGap),
              top,
              segmentWidth,
              height,
            ),
            monday,
            monday.isBefore(span.first) ? span.first : monday,
            lastDay.isAfter(span.last) ? span.last : lastDay,
          ),
        );
        rowHeight = math.max(rowHeight, height);
      }
      top += rowHeight;
      if (start + segmentColumns < segmentCount) top += segmentGap;
    }
    segments = blocks;
    size = Size(availableWidth, top);
  }
  static const gap = 2.0;
  static const maximumWeeksPerSegment = 14;
  static const segmentGap = 16.0;
  static const bottomPadding = 2.0;
  final bool showDateAnchors;
  double get dateGutter => showDateAnchors ? 34 : 0;
  double get headerHeight => showDateAnchors ? 54 : 20;
  final int count;
  late final List<int> _positions;
  late final int rows, segmentColumns;
  late final List<_CalendarSegment> segments;
  late final double cell, columnPitch, rowPitch, segmentInset;
  late final Size size;

  Rect rectAt(int index) {
    final position = _positions[index];
    final week = position ~/ 7;
    final segment = segments[week ~/ maximumWeeksPerSegment];
    return Rect.fromLTWH(
      segment.bounds.left +
          segmentInset +
          position % 7 * columnPitch +
          (columnPitch - cell) / 2,
      segment.bounds.top + headerHeight + (week - segment.firstWeek) * rowPitch,
      cell,
      cell,
    );
  }

  int? indexAt(Offset position) {
    for (var i = 0; i < count; i++) {
      if (rectAt(i).inflate(gap / 2).contains(position)) return i;
    }
    return null;
  }

  double revealStart(int index) =>
      .04 + (_positions[index] ~/ 7) / math.max(1, rows - 1) * .38;
}

class _CalendarSegment {
  const _CalendarSegment(
    this.firstWeek,
    this.weeks,
    this.bounds,
    this.monday,
    this.firstDate,
    this.lastDate,
  );
  final int firstWeek, weeks;
  final Rect bounds;
  final DateTime monday, firstDate, lastDate;
}

/// UTC calendar days avoid daylight-saving changes altering a natural-week slot.
class _CalendarWeekSpan {
  _CalendarWeekSpan(List<DateTime> dates) {
    if (dates.isEmpty) {
      monday = DateTime.utc(1970, 1, 5);
      first = monday;
      last = monday;
      weeks = 0;
      return;
    }
    final days = [for (final date in dates) _day(date)];
    first = days.reduce((a, b) => a.isBefore(b) ? a : b);
    last = days.reduce((a, b) => a.isAfter(b) ? a : b);
    monday = first.subtract(Duration(days: first.weekday - 1));
    weeks = last.difference(monday).inDays ~/ 7 + 1;
  }
  static DateTime _day(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
  late final DateTime monday, first, last;
  late final int weeks;
  int position(DateTime date) => _day(date).difference(monday).inDays;
}

class _CellAppearance {
  const _CellAppearance(this.fill, this.outline);
  final double fill;
  final double outline;
  static _CellAppearance lerp(
    _CellAppearance from,
    _CellAppearance to,
    double t,
  ) => _CellAppearance(
    ui.lerpDouble(from.fill, to.fill, t)!,
    ui.lerpDouble(from.outline, to.outline, t)!,
  );
}

_CellAppearance? _appearanceForDate(
  DateTime date,
  List<DateTime> dates,
  List<_CellAppearance> appearances,
) {
  final index = dates.indexWhere((item) => _sameDay(item, date));
  return index < 0 ? null : appearances[index];
}

class _CalendarFrame {
  _CalendarFrame({
    required this.dates,
    required this.seconds,
    required int maximum,
    required this.layout,
    required this.ink,
    required this.muted,
    required this.style,
  }) {
    cells = [
      for (var i = 0; i < dates.length; i++)
        RRect.fromRectAndRadius(layout.rectAt(i), const Radius.circular(2)),
    ];
    appearances = [
      for (final value in seconds)
        value == null
            ? const _CellAppearance(0, .19)
            : _CellAppearance(
                const [.055, .18, .31, .49, .72][value <= 0 || maximum == 0
                    ? 0
                    : (value / maximum * 4).ceil().clamp(1, 4)],
                0,
              ),
    ];
    final recorder = ui.PictureRecorder();
    _paintGuides(Canvas(recorder));
    guides = recorder.endRecording();
  }
  final List<DateTime> dates;
  final List<int?> seconds;
  final _CalendarLayout layout;
  final Color ink;
  final Color muted;
  final TextStyle style;
  late final List<RRect> cells;
  late final List<_CellAppearance> appearances;
  late final ui.Picture guides;

  bool matches(
    List<DateTime> nextDates,
    List<int?> nextSeconds,
    _CalendarLayout nextLayout,
    Color nextInk,
    Color nextMuted,
    TextStyle nextStyle,
  ) =>
      listEquals(dates, nextDates) &&
      listEquals(seconds, nextSeconds) &&
      layout.size == nextLayout.size &&
      layout.showDateAnchors == nextLayout.showDateAnchors &&
      ink == nextInk &&
      muted == nextMuted &&
      style == nextStyle;

  Rect? selectionRect(DateTime? date) {
    if (date == null) return null;
    final index = dates.indexWhere((item) => _sameDay(item, date));
    return index < 0 ? null : layout.rectAt(index).inflate(1.4);
  }

  void _paintGuides(Canvas canvas) {
    for (final segment in layout.segments) {
      if (layout.showDateAnchors) {
        String date(DateTime value) =>
            '${value.year}.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')}';
        final captionStyle = style.copyWith(fontSize: 11, height: 1.2);
        _paintText(
          canvas,
          date(segment.firstDate),
          segment.bounds.topLeft,
          captionStyle,
          maxWidth: segment.bounds.width,
        );
        _paintText(
          canvas,
          '—${date(segment.lastDate)}',
          segment.bounds.topLeft + const Offset(0, 14),
          captionStyle,
          maxWidth: segment.bounds.width,
        );
        for (var week = 0; week < segment.weeks; week++) {
          final monday = segment.monday.add(Duration(days: week * 7));
          _paintText(
            canvas,
            '${monday.month.toString().padLeft(2, '0')}.${monday.day.toString().padLeft(2, '0')}',
            Offset(
              segment.bounds.left,
              segment.bounds.top + layout.headerHeight + week * layout.rowPitch,
            ),
            style.copyWith(fontSize: 10, height: 1.2),
            maxWidth: layout.dateGutter - 4,
          );
        }
      }
      for (var weekday = 0; weekday < 7; weekday++) {
        _paintText(
          canvas,
          const ['一', '二', '三', '四', '五', '六', '日'][weekday],
          Offset(
            segment.bounds.left +
                layout.segmentInset +
                (weekday + .5) * layout.columnPitch,
            segment.bounds.top + (layout.showDateAnchors ? 34 : 0),
          ),
          style.copyWith(fontSize: 9.5),
          alignment: .5,
        );
      }
    }
  }

  void dispose() => guides.dispose();
}

class _CalendarPainter extends CustomPainter {
  _CalendarPainter({
    required this.frame,
    required this.previousAppearance,
    required this.entrance,
    required this.change,
    required this.selectionFrom,
    required this.selectionTo,
    required this.selectionFromAlpha,
    required this.selectedDate,
    required this.labels,
    required this.onSelected,
  }) : super(repaint: Listenable.merge([entrance, change]));
  final _CalendarFrame frame;
  final List<_CellAppearance>? previousAppearance;
  final Animation<double> entrance;
  final Animation<double> change;
  final Rect? selectionFrom;
  final Rect? selectionTo;
  final double selectionFromAlpha;
  final DateTime? selectedDate;
  final List<String> labels;
  final ValueChanged<DateTime> onSelected;

  @visibleForTesting
  Object get debugGeometry => frame;

  @visibleForTesting
  Rect? get debugSelectionRect => Rect.lerp(
    selectionFrom ?? selectionTo,
    selectionTo ?? selectionFrom,
    _phase(change.value, 0, 1),
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPicture(frame.guides);
    final layout = frame.layout;
    final progress = _phase(change.value, 0, 1);
    final time = entrance.value.clamp(0.0, 1.0);
    for (var i = 0; i < frame.cells.length; i++) {
      final start = layout.revealStart(i);
      final reveal = _phase(time, start, start + .52);
      if (reveal == 0) continue;
      final rounded = frame.cells[i].shift(Offset(0, 4 * (1 - reveal)));
      final target = frame.appearances[i];
      final previous = previousAppearance?[i] ?? target;
      final outline = ui.lerpDouble(
        previous.outline,
        target.outline,
        progress,
      )!;
      final fill = ui.lerpDouble(previous.fill, target.fill, progress)!;
      if (outline > 0) {
        canvas.drawRRect(
          rounded.deflate(.4),
          Paint()
            ..color = frame.muted.withValues(alpha: outline * reveal)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .7,
        );
      }
      if (fill > 0) {
        canvas.drawRRect(
          rounded,
          Paint()..color = frame.ink.withValues(alpha: fill * reveal),
        );
      }
    }
    final selected = debugSelectionRect;
    if (selected != null) {
      final opacity =
          ui.lerpDouble(
            selectionFromAlpha,
            selectionTo == null ? 0 : 1,
            progress,
          )! *
          _phase(time, .58, 1);
      if (opacity > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(selected, const Radius.circular(3.4)),
          Paint()
            ..color = frame.ink.withValues(alpha: opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (var i = 0; i < frame.dates.length; i++)
          CustomPainterSemantics(
            key: ValueKey(frame.dates[i]),
            rect: frame.layout.rectAt(i).inflate(2),
            properties: SemanticsProperties(
              label: labels[i],
              textDirection: TextDirection.ltr,
              button: true,
              selected: _sameDay(frame.dates[i], selectedDate),
              onTap: () => onSelected(frame.dates[i]),
            ),
          ),
      ];

  @override
  bool shouldRepaint(_CalendarPainter old) =>
      frame != old.frame ||
      previousAppearance != old.previousAppearance ||
      entrance != old.entrance ||
      change != old.change ||
      selectionFrom != old.selectionFrom ||
      selectionTo != old.selectionTo ||
      selectionFromAlpha != old.selectionFromAlpha ||
      selectedDate != old.selectedDate ||
      onSelected != old.onSelected;

  @override
  bool shouldRebuildSemantics(_CalendarPainter old) =>
      shouldRepaint(old) ||
      !listEquals(labels, old.labels) ||
      onSelected != old.onSelected;
}

void _paintText(
  Canvas canvas,
  String text,
  Offset position,
  TextStyle style, {
  double alignment = 0,
  double maxWidth = double.infinity,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: maxWidth);
  painter.paint(canvas, position.translate(-painter.width * alignment, 0));
  painter.dispose();
}

Path _dashedPath(Path path) {
  final dashes = Path();
  for (final metric in path.computeMetrics()) {
    for (var distance = 0.0; distance < metric.length; distance += 8) {
      dashes.addPath(
        metric.extractPath(distance, math.min(distance + 4, metric.length)),
        Offset.zero,
      );
    }
  }
  return dashes;
}

Path _rhythmArea(List<Offset?> points, double baseline) {
  final area = Path();
  var run = <Offset?>[];
  for (final point in [...points, null]) {
    if (point != null) {
      run.add(point);
      continue;
    }
    if (run.length > 1) {
      final contour = readingRhythmPath(run)
        ..lineTo(run.last!.dx, baseline)
        ..lineTo(run.first!.dx, baseline)
        ..close();
      area.addPath(contour, Offset.zero);
    }
    run = [];
  }
  return area;
}

double _phase(double value, double start, double end) => Curves.easeOutCubic
    .transform(((value - start) / (end - start)).clamp(0, 1));

void _withHorizontalReveal(
  Canvas canvas,
  Rect bounds,
  double progress,
  VoidCallback paint,
) {
  if (progress == 0) return;
  if (progress == 1) {
    paint();
    return;
  }
  canvas.save();
  canvas.clipRect(
    Rect.fromLTRB(
      bounds.left - 4,
      bounds.top - 5,
      bounds.left + bounds.width * progress,
      bounds.bottom + 5,
    ),
  );
  paint();
  canvas.restore();
}

void _withOpacity(
  Canvas canvas,
  Rect bounds,
  double opacity,
  VoidCallback paint,
) {
  if (opacity == 0) return;
  if (opacity == 1) {
    paint();
    return;
  }
  canvas.saveLayer(
    bounds.inflate(5),
    Paint()..color = Colors.white.withValues(alpha: opacity),
  );
  paint();
  canvas.restore();
}

bool _sameDay(DateTime date, DateTime? other) =>
    other != null &&
    date.year == other.year &&
    date.month == other.month &&
    date.day == other.day;

String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';
String _number(double value) => value == value.roundToDouble()
    ? '${value.toInt()}'
    : value.toStringAsFixed(1);
String _durationLabel(double? minutes) => minutes == null || !minutes.isFinite
    ? '尚未记录'
    : _secondsLabel((math.max(0, minutes) * 60).round());
String _secondsLabel(int? seconds) {
  if (seconds == null) return '尚未记录';
  final value = math.max(0, seconds);
  return value < 60 ? '$value秒' : '${value ~/ 60}分钟${value % 60}秒';
}
