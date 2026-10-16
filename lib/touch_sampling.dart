import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// One display interval plus a small delivery margin, not Flutter's fixed
/// -38ms default. This is input alignment, not an FPS limiter or extrapolator.
Duration touchSamplingOffset(double refreshHz) {
  final rate = refreshHz.isFinite && refreshHz >= 30 ? refreshHz : 60.0;
  final microseconds = (1000000 / rate + 2000).round().clamp(6000, 20000);
  return Duration(microseconds: -microseconds);
}

/// Android touch packets can arrive in bursts between render frames. Resample
/// their positions at the frame clock; mouse/wheel/pan-zoom remain untouched.
/// No timer, frame callback, widget rebuild or persistent preference is added.
class TouchSamplingPolicy with WidgetsBindingObserver {
  TouchSamplingPolicy(
    this.binding, {
    TargetPlatform? platform,
    bool enabled = true,
  }) : _enabled =
           enabled &&
           !kIsWeb &&
           (platform ?? defaultTargetPlatform) == TargetPlatform.android,
       _previousEnabled = binding.resamplingEnabled,
       _previousOffset = binding.samplingOffset {
    if (!_enabled) return;
    _refresh();
    binding.resamplingEnabled = true;
    binding.addObserver(this);
    binding.pointerRouter.addGlobalRoute(_pointer);
  }

  final WidgetsBinding binding;
  final bool _enabled;
  final bool _previousEnabled;
  final Duration _previousOffset;
  final Set<int> _touches = {};
  Duration? _pendingOffset;
  bool _disposed = false;

  void _refresh() {
    final view = binding.platformDispatcher.implicitView;
    final offset = touchSamplingOffset(view?.display.refreshRate ?? 60);
    // A refresh-mode change during contact must not shift the sampling time
    // underneath a finger. Apply it once all touch contacts have ended.
    if (_touches.isEmpty) {
      binding.samplingOffset = offset;
      _pendingOffset = null;
    } else {
      _pendingOffset = offset;
    }
  }

  void _pointer(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (event is PointerDownEvent) {
      _touches.add(event.pointer);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touches.remove(event.pointer);
      if (_touches.isEmpty && _pendingOffset != null) {
        binding.samplingOffset = _pendingOffset!;
        _pendingOffset = null;
      }
    }
  }

  @override
  void didChangeMetrics() => _refresh();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    } else {
      // Some devices terminate contact while the activity is suspended. Do
      // not let an undelivered up event pin an old display cadence forever.
      _touches.clear();
      _pendingOffset = null;
    }
  }

  void dispose() {
    if (!_enabled || _disposed) return;
    _disposed = true;
    binding.removeObserver(this);
    binding.pointerRouter.removeGlobalRoute(_pointer);
    binding.resamplingEnabled = _previousEnabled;
    binding.samplingOffset = _previousOffset;
  }
}
