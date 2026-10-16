import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'app_ui.dart';

class GlassDockItem {
  const GlassDockItem(
    this.icon,
    this.label, {
    this.enabled = true,
    this.semanticLabel,
    this.selectableOnDrag = true,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final String? semanticLabel;
  final bool selectableOnDrag;
}

/// The touch preview is local to the dock: pages only change on release.
class GlassDock extends StatefulWidget {
  const GlassDock({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.reduceMotion = false,
    this.items = const [
      GlassDockItem(CupertinoIcons.house, '发现'),
      GlassDockItem(CupertinoIcons.book, '书架'),
      GlassDockItem(CupertinoIcons.settings, '设置'),
    ],
  }) : assert(items.length == 3);

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool reduceMotion;
  final List<GlassDockItem> items;

  @override
  State<GlassDock> createState() => _GlassDockState();
}

class _GlassDockState extends State<GlassDock> with TickerProviderStateMixin {
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _stretch = AnimationController.unbounded(
    vsync: this,
  );
  late final Listenable _motion = Listenable.merge([
    _position,
    _press,
    _stretch,
  ]);
  late int _targetIndex = widget.selectedIndex;
  double _segmentWidth = 1;
  double _lastX = 0;
  Duration _lastTime = Duration.zero;
  int? _pointer;
  Timer? _restTimer;
  bool _dragging = false;
  bool _reduceMotion = false;
  bool _pointerCancelled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(GlassDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reduceMotion =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (widget.selectedIndex != _targetIndex) {
      _settlePosition(widget.selectedIndex);
    }
    if (_reduceMotion) {
      _press.value = 0;
      _stretch.value = 0;
    }
  }

  @override
  void dispose() {
    _restTimer?.cancel();
    _position.dispose();
    _press.dispose();
    _stretch.dispose();
    super.dispose();
  }

  double _fingerPosition(double x) => (x / _segmentWidth - .5).clamp(0.0, 2.0);

  Future<void> _spring(
    AnimationController controller,
    double target, {
    double velocity = 0,
  }) async {
    if (_reduceMotion) {
      controller.value = target;
      return;
    }
    try {
      await controller
          .animateWith(
            SpringSimulation(
              NovelMotion.spring,
              controller.value,
              target,
              velocity.clamp(-5.0, 5.0),
            ),
          )
          .orCancel;
      if (mounted) controller.value = target;
    } on TickerCanceled {
      // A new touch/animation owns the controller after cancellation.
    }
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointerCancelled = false;
    _pointer = event.pointer;
    _lastX = event.localPosition.dx;
    _lastTime = event.timeStamp;
    _restTimer?.cancel();
    _position.stop();
    // Pointer-down, rather than tap recognition, starts the soft response.
    if (!_reduceMotion) {
      _press.animateTo(
        1,
        duration: NovelMotion.contact,
        curve: NovelMotion.ease,
      );
    }
    _spring(_position, _fingerPosition(event.localPosition.dx));
  }

  void _release() {
    _pointer = null;
    _restTimer?.cancel();
    _spring(_press, 0);
    _spring(_stretch, 0);
  }

  void _dragStart(DragStartDetails details) {
    _dragging = true;
    _position.stop();
    _lastX = details.localPosition.dx;
    _lastTime = details.sourceTimeStamp ?? _lastTime;
    _position.value = _fingerPosition(_lastX);
  }

  void _dragUpdate(DragUpdateDetails details) {
    final time = details.sourceTimeStamp ?? _lastTime;
    final micros = (time - _lastTime).inMicroseconds;
    final speed = micros > 0
        ? (details.localPosition.dx - _lastX) * 1e6 / micros
        : details.delta.dx * 60;
    _lastX = details.localPosition.dx;
    _lastTime = time;
    final finger = _fingerPosition(details.localPosition.dx);
    // Never restart a time-based tween for every pointer event: high-rate
    // input can keep resetting it before its first frame. Follow immediately,
    // with a small spatial lag; the spring takes over only after release.
    _position.value = _reduceMotion
        ? finger
        : _position.value + (finger - _position.value) * .8;
    if (!_reduceMotion) {
      // Deform from motion, not total distance. Reversing reverses the meniscus;
      // holding still lets it relax without moving the touch preview.
      _stretch.stop();
      final target = (speed * .028).clamp(-24.0, 24.0);
      _stretch.value += (target - _stretch.value) * .55;
      _restTimer?.cancel();
      _restTimer = Timer(const Duration(milliseconds: 100), () {
        if (mounted) _spring(_stretch, 0);
      });
    }
  }

  void _settlePosition(int index, {double velocity = 0}) {
    _targetIndex = index;
    _spring(_position, index.toDouble(), velocity: velocity);
  }

  void _commit(int index, {double velocity = 0, bool fromDrag = false}) {
    if (!widget.items[index].enabled ||
        (fromDrag && !widget.items[index].selectableOnDrag)) {
      _cancel();
      return;
    }
    _dragging = false;
    _release();
    _settlePosition(index, velocity: velocity);
    widget.onSelected(index);
  }

  void _dragEnd(DragEndDetails details) {
    if (_pointerCancelled) {
      _cancel();
      return;
    }
    final velocity = (details.primaryVelocity ?? 0) / _segmentWidth;
    final projected =
        _fingerPosition(_lastX) + (velocity * .055).clamp(-.22, .22);
    _commit(projected.round().clamp(0, 2), velocity: velocity, fromDrag: true);
  }

  void _cancel() {
    if (!mounted) return;
    _dragging = false;
    _release();
    _settlePosition(widget.selectedIndex);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    // The phone Gallery's three-item capsule is about 187 x 52 logical pixels.
    // Keep a similarly compact footprint, with a 48px inner touch target.
    height: 54,
    width: 196,
    child: AnimatedBuilder(
      animation: _motion,
      builder: (context, child) {
        final pressure = _reduceMotion ? 0.0 : _press.value.clamp(0.0, 1.0);
        final flow = _reduceMotion ? 0.0 : _stretch.value;
        return Transform.translate(
          offset: Offset(flow * .16, -pressure * .6),
          child: Transform.scale(
            key: const ValueKey('dock-whole-capsule-transform'),
            scaleX: 1 + pressure * .022 + flow.abs() * .00125,
            scaleY: 1 + pressure * .065 - flow.abs() * .0006,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: LiquidGlass(
                      key: const ValueKey('dock-fluid-surface'),
                      radius: 27,
                      thickness: 16 + pressure * 2,
                      activation: pressure,
                      touchPosition: (_position.value.clamp(0.0, 2.0) + .5) / 3,
                      elevated: false,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GlassForeground(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _segmentWidth = constraints.maxWidth / 3;
                          return Listener(
                            onPointerDown: _down,
                            onPointerUp: (event) {
                              if (event.pointer == _pointer) _release();
                            },
                            onPointerCancel: (event) {
                              if (event.pointer == _pointer) {
                                _pointerCancelled = true;
                                _cancel();
                              }
                            },
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) {
                                if (!_dragging && !_pointerCancelled) {
                                  _commit(
                                    _fingerPosition(
                                      details.localPosition.dx,
                                    ).round().clamp(0, 2),
                                  );
                                }
                              },
                              onHorizontalDragStart: _dragStart,
                              onHorizontalDragUpdate: _dragUpdate,
                              onHorizontalDragEnd: _dragEnd,
                              onHorizontalDragCancel: _cancel,
                              child: Row(
                                children: [
                                  for (var index = 0; index < 3; index++)
                                    _nav(index, widget.items[index]),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _nav(int index, GlassDockItem item) {
    final proximity = (1 - (_position.value - index).abs()).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    final color = !item.enabled && index != widget.selectedIndex
        ? scheme.onSurfaceVariant.withValues(alpha: .4)
        : Color.lerp(scheme.onSurfaceVariant, scheme.primary, proximity);
    return Expanded(
      child: Semantics(
        key: ValueKey('dock-tab-$index'),
        button: item.enabled,
        enabled: item.enabled,
        selected: widget.selectedIndex == index,
        label: item.semanticLabel ?? item.label,
        onTap: item.enabled ? () => _commit(index) : null,
        child: ExcludeSemantics(
          child: SizedBox(
            height: 48,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, size: 20, color: color),
                  const SizedBox(height: 3),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        item.label,
                        maxLines: 1,
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: widget.selectedIndex == index
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  ExcludeSemantics(
                    child: SizedBox(
                      width: 12,
                      height: 1.5,
                      child: ColoredBox(
                        color: scheme.onSurface.withValues(alpha: proximity),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
