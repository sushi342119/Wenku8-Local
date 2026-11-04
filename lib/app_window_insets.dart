import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef WindowInsetProbe = Future<Object?> Function();

/// Correct only the independently confirmed API 35 caption-rectangle defect.
/// Keyboard, gestures, notches and the actual window size keep their semantics.
class AppWindowInsets extends StatefulWidget {
  const AppWindowInsets({super.key, required this.child, this.probe});
  final Widget child;
  final WindowInsetProbe? probe;
  static const channel = MethodChannel('org.mewx.wenku8/reader_controls');

  /// Unlike a SafeArea's consumed padding, this is the window's backdrop band.
  static EdgeInsets viewPaddingOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WindowPadding>()?.padding ??
      EdgeInsets.fromViewPadding(
        View.of(context).viewPadding,
        View.of(context).devicePixelRatio,
      );

  @override
  State<AppWindowInsets> createState() => _AppWindowInsetsState();
}

class _InsetCorrection {
  const _InsetCorrection(this.size, this.top);
  final Size size;
  final double top;
  static _InsetCorrection? parse(Object? value) {
    if (value is! Map) return null;
    final width = value['width'], height = value['height'], top = value['top'];
    if (width is! num || height is! num || top is! num) return null;
    if (!width.isFinite ||
        !height.isFinite ||
        !top.isFinite ||
        width <= 0 ||
        height <= 0 ||
        top < 0 ||
        top >= height) {
      return null;
    }
    return _InsetCorrection(
      Size(width.toDouble(), height.toDouble()),
      top.toDouble(),
    );
  }

  bool matches(Size other) =>
      (size.width - other.width).abs() < 1 &&
      (size.height - other.height).abs() < 1;
}

class _AppWindowInsetsState extends State<AppWindowInsets>
    with WidgetsBindingObserver {
  FlutterView? _view;
  _InsetCorrection? _correction;
  bool _scheduled = false;
  int _generation = 0;

  bool get _enabled =>
      widget.probe != null ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final view = View.of(context);
    if (_view != view) {
      _view = view;
      _correction = null;
      _scheduleProbe();
    }
  }

  @override
  void didChangeMetrics() => _scheduleProbe();

  void _scheduleProbe() {
    if (!_enabled) return;
    _generation++;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      final generation = _generation;
      final view = _view;
      Object? value;
      try {
        value =
            await (widget.probe?.call() ??
                AppWindowInsets.channel.invokeMethod<Object>('windowInsets'));
      } on PlatformException {
        value = null;
      } on MissingPluginException {
        value = null;
      }
      if (!mounted || generation != _generation || view != _view) return;
      final correction = _InsetCorrection.parse(value);
      if (correction != null && !correction.matches(view!.physicalSize)) return;
      if (_correction?.size == correction?.size &&
          _correction?.top == correction?.top) {
        return;
      }
      setState(() => _correction = correction);
    });
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final correction = _correction;
    final top = correction != null && correction.matches(_view!.physicalSize)
        ? math.min(
            media.viewPadding.top,
            correction.top / media.devicePixelRatio,
          )
        : media.viewPadding.top;
    final data = top == media.viewPadding.top
        ? media
        : media.copyWith(
            viewPadding: media.viewPadding.copyWith(top: top),
            padding: media.padding.copyWith(
              top: math.max(0, top - media.viewInsets.top),
            ),
          );
    return _WindowPadding(
      padding: data.viewPadding,
      child: MediaQuery(data: data, child: widget.child),
    );
  }
}

class _WindowPadding extends InheritedWidget {
  const _WindowPadding({required this.padding, required super.child});
  final EdgeInsets padding;
  @override
  bool updateShouldNotify(_WindowPadding oldWidget) =>
      padding != oldWidget.padding;
}
