import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'haptic_preferences.dart';
import 'route_identity.dart';

/// Meaning, not motor duration: each platform chooses its native sensation.
enum HapticCue {
  selection,
  shelfStep,
  detent,
  pageTurn,
  action,
  longPress,
  boundary,
  success,
  warning,
  error,
}

extension HapticCueCategory on HapticCue {
  HapticCategory get category => switch (this) {
    HapticCue.selection || HapticCue.action => HapticCategory.controls,
    HapticCue.shelfStep => HapticCategory.shelf,
    HapticCue.pageTurn => HapticCategory.reading,
    HapticCue.detent => HapticCategory.adjustment,
    HapticCue.longPress => HapticCategory.longPress,
    HapticCue.boundary => HapticCategory.boundary,
    HapticCue.success ||
    HapticCue.warning ||
    HapticCue.error => HapticCategory.result,
  };
}

/// One physical pulse per interaction, with no late catch-up. Outcome throttles
/// apply to that outcome, not to the user's next unrelated selection or drag.
class HapticGate {
  Duration? _last;
  final _lastForCue = <HapticCue, Duration>{};

  static Duration interval(HapticCue cue) => Duration(
    milliseconds: switch (cue) {
      HapticCue.shelfStep => 65,
      HapticCue.detent => 70,
      HapticCue.selection => 80,
      HapticCue.pageTurn => 110,
      HapticCue.action => 100,
      HapticCue.longPress => 150,
      HapticCue.boundary => 100,
      HapticCue.success => 350,
      HapticCue.warning => 400,
      HapticCue.error => 450,
    },
  );

  bool accept(HapticCue cue, Duration now) {
    if (_last case final last?) {
      if (now - last < const Duration(milliseconds: 65)) return false;
    }
    if (_lastForCue[cue] case final previous?) {
      if (now - previous < interval(cue)) return false;
    }
    _last = now;
    _lastForCue[cue] = now;
    return true;
  }
}

abstract final class AppHaptics {
  static const channel = MethodChannel('org.mewx.wenku8_flutter/haptics');
  static final _clock = Stopwatch()..start();
  static Duration Function() _now = () => _clock.elapsed;
  static HapticGate _gate = HapticGate();
  static bool get _isHarmony => defaultTargetPlatform.name == 'ohos';

  /// Call only for a committed user interaction or its visible outcome. Loading,
  /// restored settings, background downloads and automatic page turns stay quiet.
  static void play(BuildContext context, HapticCue? cue) => _play(context, cue);

  /// Samples the newly saved setting without a second control-click or stale
  /// inherited value. Muted categories and the master switch still apply.
  static void preview(
    BuildContext context,
    HapticCue cue, {
    required HapticPreferences preferences,
  }) => _play(context, cue, preferences: preferences);

  /// Host diagnostics only; this never claims that a physical motor fired.
  static Future<Map<Object?, Object?>?> capabilities() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS &&
            !_isHarmony)) {
      return null;
    }
    try {
      final value = await channel.invokeMethod<Object?>('capabilities');
      return value is Map ? Map<Object?, Object?>.from(value) : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static void _play(
    BuildContext context,
    HapticCue? cue, {
    HapticPreferences? preferences,
  }) {
    if (cue == null || !context.mounted || kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS &&
        !_isHarmony) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if (RouteIdentity.read(context)?.isCurrent == false ||
        !TickerMode.getValuesNotifier(context).value.enabled) {
      return;
    }
    final strength = (preferences ?? HapticScope.of(context)).levelFor(
      cue.category,
    );
    // A muted interaction must not consume a tick meant for another category.
    if (strength == null || !_gate.accept(cue, _now())) return;
    unawaited(_send(cue, strength));
  }

  static Future<void> _send(HapticCue cue, HapticStrength strength) async {
    try {
      // A false result can mean system touch feedback is disabled. Do not
      // override that decision with another motor API or a forced vibration.
      await channel.invokeMethod<bool>(
        'play',
        strength == HapticStrength.standard
            ? cue.name
            : {'cue': cue.name, 'strength': strength.name},
      );
    } on MissingPluginException {
      // Existing host shells can still use Flutter's system-respecting presets.
      try {
        if (strength != HapticStrength.standard) {
          await (strength == HapticStrength.light
              ? HapticFeedback.lightImpact()
              : HapticFeedback.heavyImpact());
          return;
        }
        await switch (cue) {
          HapticCue.selection ||
          HapticCue.shelfStep ||
          HapticCue.detent ||
          HapticCue.pageTurn ||
          HapticCue.action => HapticFeedback.selectionClick(),
          HapticCue.longPress => HapticFeedback.mediumImpact(),
          HapticCue.boundary => HapticFeedback.lightImpact(),
          HapticCue.success => HapticFeedback.mediumImpact(),
          HapticCue.warning || HapticCue.error => HapticFeedback.mediumImpact(),
        };
      } on PlatformException {
        // Optional tactile feedback never interrupts the accepted action.
      } on MissingPluginException {
        // This host has no haptic implementation.
      }
    } on PlatformException {
      // The action and its visible result remain authoritative.
    }
  }

  @visibleForTesting
  static void resetForTesting({Duration Function()? now}) {
    _gate = HapticGate();
    _now = now ?? () => _clock.elapsed;
  }
}

/// A free scroll has no discrete items: only acknowledge an edge encounter.
/// Touching or starting a drag, ballistic motion, restoration and code-driven
/// scrolling never synthesize touches. Nested scroll views keep one owner.
class AppScrollHaptics extends StatefulWidget {
  const AppScrollHaptics({super.key, required this.child});
  final Widget child;

  @override
  State<AppScrollHaptics> createState() => _AppScrollHapticsState();
}

class _AppScrollHapticsState extends State<AppScrollHaptics> {
  int _edge = 0;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _edge = 0;
    }
    final double delta;
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      delta = notification.scrollDelta ?? 0;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      delta = notification.overscroll;
    } else {
      return false;
    }
    if (delta == 0) return false;
    final metrics = notification.metrics;
    final edge = delta < 0 && metrics.extentBefore == 0
        ? -1
        : delta > 0 && metrics.extentAfter == 0
        ? 1
        : 0;
    if (edge != 0 && edge != _edge) {
      AppHaptics.play(context, HapticCue.boundary);
      _edge = edge;
    }
    // Require actual travel back into the content before another edge pulse.
    if (metrics.extentBefore > 12 && metrics.extentAfter > 12) _edge = 0;
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
}

/// Only an explicit barrier dismissal clicks. Route transitions, timer closes
/// and buttons inside a dialog retain their own feedback owner.
mixin AppHapticModalBarrier<T> on ModalRoute<T> {
  @override
  Widget buildModalBarrier() => Builder(
    builder: (context) {
      void dismiss() {
        if (!isCurrent || !barrierDismissible) return;
        AppHaptics.play(context, HapticCue.action);
        navigator?.maybePop();
      }

      final color = barrierColor;
      if (color != null && color.a != 0 && !offstage) {
        return AnimatedModalBarrier(
          color: animation!.drive(
            ColorTween(
              begin: color.withValues(alpha: 0),
              end: color,
            ).chain(CurveTween(curve: barrierCurve)),
          ),
          dismissible: barrierDismissible,
          semanticsLabel: barrierLabel,
          barrierSemanticsDismissible: semanticsDismissible,
          onDismiss: dismiss,
        );
      }
      return ModalBarrier(
        dismissible: barrierDismissible,
        semanticsLabel: barrierLabel,
        barrierSemanticsDismissible: semanticsDismissible,
        onDismiss: dismiss,
      );
    },
  );
}
