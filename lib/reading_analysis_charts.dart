import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_language.dart';

enum ReadingAnalysisChartKind {
  bars,
  horizontal,
  share,
  nightOverlay,
  treemap,
  radial,
  gantt,
}

/// Small immutable chart inputs shared by the dashboard and report canvas.
class ReadingAnalysisDatum {
  const ReadingAnalysisDatum(
    this.label,
    this.value, {
    this.secondary = 0,
    this.cells = const [],
    this.first,
    this.completed,
  });
  final String label;
  final double? value;
  final double secondary;
  final List<bool> cells;
  final int? first, completed;
}

class ReadingAnalysisChart extends StatelessWidget {
  const ReadingAnalysisChart({
    super.key,
    required this.kind,
    required this.data,
    this.labels = const [],
    this.height = 190,
    this.semanticLabel = '',
  });
  final ReadingAnalysisChartKind kind;
  final List<ReadingAnalysisDatum> data;
  final List<String> labels;
  final double height;
  final String semanticLabel;

  String _semanticNumber(double? value) {
    if (kind == ReadingAnalysisChartKind.radial) {
      if (value == null) return '未知';
      if (value == 0) return '0';
      if (value > 0 && value < .1) return '小于0.1';
    }
    return value == null ? '未知' : value.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      value: data
          .map((d) => '${d.label} ${_semanticNumber(d.value)}')
          .join('，'),
      child: RepaintBoundary(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: ReadingAnalysisPainter(
              kind: kind,
              data: [
                for (final d in data)
                  ReadingAnalysisDatum(
                    appText(context, d.label),
                    d.value,
                    secondary: d.secondary,
                    cells: d.cells,
                    first: d.first,
                    completed: d.completed,
                  ),
              ],
              labels: labels.map((label) => appText(context, label)).toList(),
              fontFamily:
                  Theme.of(context).textTheme.bodyMedium?.fontFamily ??
                  'CupertinoSystemText',
              ink: colors.onSurface,
              muted: colors.onSurfaceVariant,
              accent: colors.primary,
              background: colors.surface,
            ),
          ),
        ),
      ),
    );
  }
}

class ReadingAnalysisPainter extends CustomPainter {
  ReadingAnalysisPainter({
    required this.kind,
    required this.data,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.background,
    this.labels = const [],
    this.fontFamily = 'CupertinoSystemText',
  });
  final ReadingAnalysisChartKind kind;
  final List<ReadingAnalysisDatum> data;
  final List<String> labels;
  final Color ink, muted, accent, background;
  final String fontFamily;

  double _text(
    Canvas c,
    String value,
    double x,
    double y,
    double width, {
    double size = 12,
    Color? color,
    TextAlign align = TextAlign.left,
    int lines = 2,
  }) {
    if (width <= 0) return 0;
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: const ['CupertinoSystemText', 'Roboto'],
          fontSize: size,
          color: color ?? muted,
          height: 1.35,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: lines,
      ellipsis: '…',
    )..layout(maxWidth: width);
    p.paint(c, Offset(x, y));
    final height = p.height;
    p.dispose();
    return height;
  }

  Color _color(int i) => Color.alphaBlend(
    accent.withValues(alpha: (.94 - i * .095).clamp(.28, .94)),
    background,
  );
  String _number(double? value) => value == null
      ? '—'
      : value >= 10
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty || size.isEmpty) return;
    switch (kind) {
      case ReadingAnalysisChartKind.bars:
      case ReadingAnalysisChartKind.nightOverlay:
        _bars(canvas, size);
      case ReadingAnalysisChartKind.horizontal:
        _horizontal(canvas, size);
      case ReadingAnalysisChartKind.share:
        _share(canvas, size);
      case ReadingAnalysisChartKind.treemap:
        _treemap(canvas, size);
      case ReadingAnalysisChartKind.radial:
        _radial(canvas, size);
      case ReadingAnalysisChartKind.gantt:
        _gantt(canvas, size);
    }
  }

  void _bars(Canvas c, Size s) {
    final maximum = data.map((d) => d.value ?? 0).fold<double>(0, math.max);
    final stride = s.width / data.length,
        base = s.height - 30,
        area = base - 30;
    c.drawLine(
      Offset(0, base),
      Offset(s.width, base),
      Paint()..color = muted.withValues(alpha: .25),
    );
    for (var i = 0; i < data.length; i++) {
      final d = data[i], x = i * stride, bw = math.min(30.0, stride * .65);
      final h = maximum <= 0 ? 0.0 : area * (d.value ?? 0) / maximum;
      if (h > 0) {
        c.drawRect(
          Rect.fromLTWH(x + (stride - bw) / 2, base - h, bw, h),
          Paint()
            ..color = kind == ReadingAnalysisChartKind.nightOverlay
                ? accent.withValues(alpha: .22)
                : _color(i % 4),
        );
      }
      if (kind == ReadingAnalysisChartKind.nightOverlay &&
          maximum > 0 &&
          d.secondary > 0) {
        final nh = area * d.secondary / maximum;
        c.drawRect(
          Rect.fromLTWH(x + (stride - bw) / 2, base - nh, bw, nh),
          Paint()..color = accent,
        );
      }
      _text(c, d.label, x, base + 8, stride, align: TextAlign.center, lines: 1);
      if (stride >= 32) {
        _text(
          c,
          _number(d.value),
          x,
          base - h - 22,
          stride,
          align: TextAlign.center,
          size: 12,
          color: ink,
          lines: 1,
        );
      }
    }
  }

  void _horizontal(Canvas c, Size s) {
    final maximum = data.map((d) => d.value ?? 0).fold<double>(0, math.max);
    final row = s.height / data.length;
    for (var i = 0; i < data.length; i++) {
      final d = data[i], y = row * i;
      _text(c, d.label, 0, y, s.width - 72, size: 13, color: ink, lines: 1);
      _text(
        c,
        _number(d.value),
        s.width - 68,
        y,
        68,
        align: TextAlign.right,
        color: ink,
      );
      c.drawRect(
        Rect.fromLTWH(0, y + 25, s.width, 6),
        Paint()..color = muted.withValues(alpha: .1),
      );
      if (maximum > 0) {
        c.drawRect(
          Rect.fromLTWH(0, y + 25, s.width * (d.value ?? 0) / maximum, 6),
          Paint()..color = _color(i),
        );
      }
    }
  }

  void _share(Canvas c, Size s) {
    final total = data.fold<double>(0, (sum, d) => sum + (d.value ?? 0));
    var x = 0.0;
    for (var i = 0; i < data.length; i++) {
      final d = data[i],
          ratio = total == 0 ? 0.0 : (d.value ?? 0) / total,
          width = ratio * s.width;
      c.drawRect(Rect.fromLTWH(x, 0, width, 23), Paint()..color = _color(i));
      if (width > 46) {
        _text(
          c,
          '${(ratio * 100).round()}%',
          x + 3,
          3,
          width - 6,
          color: background,
          align: TextAlign.center,
          lines: 1,
        );
      }
      x += width;
      final y = 38.0 + i * 26;
      c.drawRect(Rect.fromLTWH(0, y + 4, 9, 9), Paint()..color = _color(i));
      _text(c, d.label, 17, y, s.width - 77, size: 12, lines: 1);
      _text(
        c,
        '${(ratio * 100).toStringAsFixed(1)}%',
        s.width - 60,
        y,
        60,
        align: TextAlign.right,
        color: ink,
      );
    }
  }

  void _treemap(Canvas c, Size s) {
    final positive = [
      for (var i = 0; i < data.length; i++)
        if ((data[i].value ?? 0) > 0) i,
    ];
    final total = positive.fold<double>(0, (sum, i) => sum + data[i].value!);
    void split(List<int> ids, Rect r) {
      if (ids.isEmpty) return;
      if (ids.length == 1) {
        final index = ids.first, d = data[index], box = r.deflate(2);
        c.drawRect(box, Paint()..color = _color(index));
        if (box.width > 48 && box.height > 39) {
          _text(
            c,
            d.label,
            box.left + 8,
            box.top + 8,
            box.width - 16,
            size: 13,
            color: background,
          );
          if (box.height > 63) {
            _text(
              c,
              '${(d.value! / total * 100).toStringAsFixed(1)}%',
              box.left + 8,
              box.bottom - 25,
              box.width - 16,
              size: 14,
              color: background,
            );
          }
        }
        return;
      }
      final sum = ids.fold<double>(0, (sum, i) => sum + data[i].value!);
      var left = 0.0, n = 0;
      while (n < ids.length - 1 && left < sum / 2) {
        left += data[ids[n++]].value!;
      }
      final ratio = left / sum;
      if (r.width >= r.height) {
        final cut = r.left + r.width * ratio;
        split(
          ids.take(n).toList(),
          Rect.fromLTRB(r.left, r.top, cut, r.bottom),
        );
        split(
          ids.skip(n).toList(),
          Rect.fromLTRB(cut, r.top, r.right, r.bottom),
        );
      } else {
        final cut = r.top + r.height * ratio;
        split(ids.take(n).toList(), Rect.fromLTRB(r.left, r.top, r.right, cut));
        split(
          ids.skip(n).toList(),
          Rect.fromLTRB(r.left, cut, r.right, r.bottom),
        );
      }
    }

    split(positive, Offset.zero & s);
  }

  void _radial(Canvas c, Size s) {
    final hours = [for (var i = 0; i < 24; i++) data.elementAtOrNull(i)?.value];
    final maximum = hours.whereType<double>().fold<double>(0, math.max);
    if (maximum <= 0) return;
    final center = Offset(s.width / 2, s.height / 2);
    final outer = math.min(s.width, s.height) / 2 - 27;
    final inner = outer * .58;
    const step = math.pi / 12, sweep = step * .76;
    Path sector(double start, double endRadius) => Path()
      ..arcTo(
        Rect.fromCircle(center: center, radius: inner),
        start,
        sweep,
        false,
      )
      ..arcTo(
        Rect.fromCircle(center: center, radius: endRadius),
        start + sweep,
        -sweep,
        false,
      )
      ..close();
    for (var i = 0; i < 24; i++) {
      final angle = -math.pi / 2 + i * step;
      final value = hours[i];
      final start = angle - sweep / 2;
      // A missing hour has no track. A measured zero retains only its neutral
      // clock position, never a minimum-length reading mark.
      if (value != null) {
        c.drawPath(
          sector(start, outer),
          Paint()..color = muted.withValues(alpha: .09),
        );
      }
      if (value != null && value > 0) {
        final length = (outer - inner) * value / maximum;
        c.drawPath(
          sector(start, inner + length),
          Paint()
            ..color = i >= 22 || i < 6 ? accent : ink.withValues(alpha: .58),
        );
      }
      if (i % 3 == 0) {
        final direction = Offset(math.cos(angle), math.sin(angle));
        final p = center + direction * (outer + 17);
        _text(
          c,
          '$i',
          p.dx - 14,
          p.dy - 8,
          28,
          align: TextAlign.center,
          color: ink,
          size: i % 6 == 0 ? 13 : 11.5,
          lines: 1,
        );
      }
    }
    _text(
      c,
      '24 小时',
      center.dx - inner + 4,
      center.dy - 9,
      inner * 2 - 8,
      align: TextAlign.center,
      color: ink,
      size: 13,
      lines: 1,
    );
  }

  void _gantt(Canvas c, Size s) {
    final count = labels.length;
    if (count == 0) return;
    final cell = s.width / count, row = (s.height - 27) / data.length;
    for (var i = 0; i < count; i++) {
      _text(c, labels[i], i * cell, 0, cell, align: TextAlign.center, lines: 1);
    }
    for (var i = 0; i < data.length; i++) {
      final d = data[i], y = 30 + row * i;
      _text(c, d.label, 0, y, s.width, size: 13, color: ink, lines: 1);
      for (var m = 0; m < count; m++) {
        final x = m * cell, active = d.cells.elementAtOrNull(m) ?? false;
        c.drawRect(
          Rect.fromLTWH(x + 2, y + 26, cell - 4, 8),
          Paint()..color = active ? accent : muted.withValues(alpha: .1),
        );
        if (d.first == m) {
          c.drawCircle(
            Offset(x + cell / 2, y + 30),
            6,
            Paint()
              ..color = ink
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
        if (d.completed == m) {
          final p = Offset(x + cell / 2, y + 30);
          c.drawPath(
            Path()
              ..moveTo(p.dx, p.dy - 7)
              ..lineTo(p.dx + 7, p.dy)
              ..lineTo(p.dx, p.dy + 7)
              ..lineTo(p.dx - 7, p.dy)
              ..close(),
            Paint()..color = ink,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant ReadingAnalysisPainter old) =>
      kind != old.kind ||
      data != old.data ||
      labels != old.labels ||
      ink != old.ink ||
      muted != old.muted ||
      accent != old.accent ||
      background != old.background ||
      fontFamily != old.fontFamily;
}
