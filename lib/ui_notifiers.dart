import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Data changes remain synchronous; visual observers receive at most one
/// notification per frame, outside layout. No idle timer or permanent ticker.
class FrameChangeNotifier extends ChangeNotifier {
  bool _queued = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed || _queued || !hasListeners) return;
    _queued = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _queued = false;
      if (!_disposed) super.notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Retained home tabs do not rebuild for background data updates. Reactivation
/// reads the latest data once, so their scroll positions/elements stay alive.
class ActiveListenableBuilder extends StatefulWidget {
  const ActiveListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });
  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<ActiveListenableBuilder> createState() =>
      _ActiveListenableBuilderState();
}

class _ActiveListenableBuilderState extends State<ActiveListenableBuilder> {
  bool _active = false;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active == _active) return;
    _active = active;
    if (active) {
      widget.listenable.addListener(_changed);
    } else {
      widget.listenable.removeListener(_changed);
    }
  }

  @override
  void didUpdateWidget(ActiveListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_active && oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    if (_active) widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
