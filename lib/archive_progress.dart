import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_ui.dart';

/// A transfer occupies its action, never a second panel. The fine open ring
/// measures real progress; the centre remains the stop target throughout.
class ArchiveTransferButton extends StatefulWidget {
  const ArchiveTransferButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.working = false,
    this.completed = false,
    this.value,
    this.status,
    this.reduceMotion = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool working, completed, reduceMotion;
  final double? value;
  final String? status;

  @override
  State<ArchiveTransferButton> createState() => _ArchiveTransferButtonState();
}

class _ArchiveTransferButtonState extends State<ArchiveTransferButton>
    with TickerProviderStateMixin {
  late final _fill = AnimationController(vsync: this);
  late final _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final _finish = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 720),
  );
  late final _paint = Listenable.merge([_fill, _turn, _finish]);
  bool get _still =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ArchiveTransferButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.working && !widget.working && widget.completed && !_still) {
      _finish.forward(from: 0);
    } else if (widget.working || _still) {
      _finish.value = 1;
    }
    _sync();
  }

  void _sync() {
    final target = widget.value?.clamp(0.0, 1.0) ?? 0;
    if (_still || !widget.working) {
      _fill.value = target;
    } else if (_fill.value != target) {
      _fill.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    // Only an actual unknown-duration operation rotates. Determinate transfers,
    // queued jobs and completed/failed actions carry no idle animation.
    if (widget.working && widget.value == null && !_still) {
      if (!_turn.isAnimating) _turn.repeat();
    } else {
      _turn.stop();
      _turn.value = 0;
    }
    if (_still) _finish.value = 1;
  }

  @override
  void dispose() {
    _fill.dispose();
    _turn.dispose();
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = widget.onPressed == null
        ? theme.disabledColor
        : theme.colorScheme.onSurface;
    final value = widget.value;
    final semanticValue = [
      if (widget.working && value != null)
        '${(value.clamp(0, 1) * 100).floor()}%',
      if (widget.status case final status?) appText(context, status),
    ].join(' · ');
    return MergeSemantics(
      child: Semantics(
        value: semanticValue.isEmpty ? null : semanticValue,
        child: GlassIconButton.custom(
          // A finger pressed on Stop must not activate Delete/Install if the
          // transfer completes before it lifts. Keep the mark's animation in
          // this parent, but give each action phase its own gesture identity.
          key: ValueKey((widget.working, widget.completed)),
          label: widget.label,
          onPressed: widget.onPressed,
          child: RepaintBoundary(
            child: SizedBox.square(
              dimension: 30,
              child: AnimatedBuilder(
                animation: _finish,
                builder: (context, icon) => CustomPaint(
                  key: const ValueKey('archive-transfer-ring'),
                  painter: _TransferMarkPainter(
                    fill: _fill,
                    turn: _turn,
                    finish: _finish,
                    repaint: _paint,
                    ink: ink,
                    working: widget.working,
                    indeterminate: value == null,
                    highContrast: MediaQuery.highContrastOf(context),
                  ),
                  child: Opacity(
                    opacity: widget.working
                        ? 0
                        : Curves.easeOut.transform(
                            ((_finish.value - .65) / .35).clamp(0, 1),
                          ),
                    child: icon,
                  ),
                ),
                child: ArchiveIcon(widget.icon, size: 21, color: ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferMarkPainter extends CustomPainter {
  _TransferMarkPainter({
    required this.fill,
    required this.turn,
    required this.finish,
    required Listenable repaint,
    required this.ink,
    required this.working,
    required this.indeterminate,
    required this.highContrast,
  }) : super(repaint: repaint);
  final Animation<double> fill, turn, finish;
  final Color ink;
  final bool working, indeterminate, highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final pen = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round;
    if (working) {
      final ring = Rect.fromCircle(center: centre, radius: 12.5);
      const gap = .22;
      const start = -math.pi / 2 + gap / 2;
      const sweep = 2 * math.pi - gap;
      pen.color = ink.withValues(alpha: highContrast ? .32 : .12);
      canvas.drawArc(ring, start, sweep, false, pen);
      pen.color = ink.withValues(alpha: .88);
      if (indeterminate) {
        canvas.drawArc(
          ring,
          start + turn.value * 2 * math.pi,
          sweep * .23,
          false,
          pen,
        );
      } else if (fill.value > 0) {
        canvas.drawArc(ring, start, sweep * fill.value, false, pen);
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: centre, width: 7, height: 7),
          const Radius.circular(1.2),
        ),
        Paint()..color = ink.withValues(alpha: .88),
      );
    } else if (finish.value < 1) {
      final reveal = Curves.easeOut.transform((finish.value / .3).clamp(0, 1));
      final fade = 1.0 - ((finish.value - .65) / .35).clamp(0, 1);
      final path = Path()
        ..moveTo(centre.dx - 5, centre.dy)
        ..lineTo(centre.dx - 1.2, centre.dy + 3.8)
        ..lineTo(centre.dx + 6, centre.dy - 4.5);
      final metric = path.computeMetrics().single;
      pen.color = ink.withValues(alpha: fade);
      canvas.drawPath(metric.extractPath(0, metric.length * reveal), pen);
    }
  }

  @override
  bool shouldRepaint(_TransferMarkPainter old) =>
      old.ink != ink ||
      old.working != working ||
      old.indeterminate != indeterminate ||
      old.highContrast != highContrast;
}
