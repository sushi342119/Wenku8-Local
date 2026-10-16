import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'archive_motion.dart';

/// Wait for a decoded frame, then replace the static skeleton with one shallow
/// diagonal cut. Recycled rows and Hero destinations reuse the presented frame.
class CoverArrival extends StatefulWidget {
  const CoverArrival({
    super.key,
    required this.bytes,
    required this.ready,
    required this.placeholder,
    required this.child,
    this.recordArrival = true,
  });

  final Uint8List bytes;
  final bool ready;
  final Widget placeholder;
  final Widget child;
  final bool recordArrival;

  // Weak keys follow the byte cache lifetime; this is not another cover cache.
  static final _presented = Expando<bool>('presented-cover-frame');
  static bool wasPresented(Uint8List bytes) => _presented[bytes] == true;

  @override
  State<CoverArrival> createState() => _CoverArrivalState();
}

class _CoverArrivalState extends State<CoverArrival>
    with SingleTickerProviderStateMixin {
  AnimationController? _clock;
  Animation<double>? _routeAnimation;
  bool _started = false;
  bool _done = false;
  bool _queued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_routeChanged);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeChanged);
    }
    // Do not combine an unfinished face reveal with a new paper flight.
    if (_started && route?.isCurrent == false) {
      _finish();
    } else {
      _prepare();
    }
  }

  @override
  void didUpdateWidget(CoverArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.bytes, oldWidget.bytes)) {
      _clock?.stop();
      _clock?.value = 0;
      _started = false;
      _done = false;
    }
    _prepare();
  }

  void _routeChanged(AnimationStatus status) {
    if (mounted && status == AnimationStatus.completed) {
      setState(_prepare);
    }
  }

  void _finish() {
    _clock?.stop();
    _done = true;
    if (widget.recordArrival) CoverArrival._presented[widget.bytes] = true;
  }

  void _prepare() {
    if (!widget.ready || _done) return;
    if (!widget.recordArrival) {
      _done = true;
      return;
    }
    if (CoverArrival.wasPresented(widget.bytes) ||
        MediaQuery.disableAnimationsOf(context)) {
      _finish();
      return;
    }
    if (_started || _queued || !_routeReady) return;
    _queued = true;
    // A newly attached Hero route can briefly report completed before its
    // actual push starts. Recheck after that first frame, never during flight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted && widget.ready && !_done && !_started && _routeReady) {
        setState(_start);
      }
    });
  }

  bool get _routeReady =>
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false &&
      (_routeAnimation == null ||
          _routeAnimation!.status == AnimationStatus.completed);

  void _start() {
    _started = true;
    _clock ??=
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 420),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(_finish);
          }
        });
    _clock!.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.ready || (!_started && !_done)) return widget.placeholder;
    if (_done) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.placeholder,
        ArchivePlaneTransition(
          key: const ValueKey('cover-arrival-plane'),
          animation: _clock!,
          child: RepaintBoundary(child: widget.child),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeChanged);
    _clock?.dispose();
    super.dispose();
  }
}
