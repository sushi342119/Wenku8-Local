import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_ui.dart';
import 'local_platform.dart';
import 'app_window_insets.dart';

String readerInformationTitle(String title, int number) =>
    RegExp(r'^第[零〇一二三四五六七八九十百千万两0-9]+[章话回节]').hasMatch(title.trimLeft())
    ? title
    : '第$number话 · $title';

/// Only this small status line updates on a system time/battery broadcast. Reading
/// text, pagination and glass never rebuild to tick a clock.
class ReaderStatusFooter extends StatefulWidget {
  const ReaderStatusFooter({
    super.key,
    this.leading,
    this.compact = false,
    this.timeAtEnd = false,
    this.showBattery = true,
    this.ink,
    this.interactiveLeading = false,
    this.fontSize,
    this.statusBand = false,
  });
  final Widget? leading;
  final bool compact, timeAtEnd, showBattery;
  final Color? ink;
  final bool interactiveLeading;
  final double? fontSize;
  final bool statusBand;
  static const height = 24.0;
  // Reuse the cutout/status band, not another row below it. Time and battery
  // sit at opposite edges, leaving the camera/sensor area in the middle clear.
  static double heightFor(BuildContext context, {double fontSize = 11}) =>
      math.max(
        math.max(
          MediaQuery.viewPaddingOf(context).top,
          AppWindowInsets.viewPaddingOf(context).top,
        ),
        (MediaQuery.textScalerOf(context).scale(fontSize) * 1.4 + 8).clamp(
          height,
          double.infinity,
        ),
      );
  static const events = EventChannel('org.mewx.wenku8/reader_status');
  // Incoming/outgoing sheets share one native subscription and the same data.
  static final _updates = events.receiveBroadcastStream();
  static Map? _lastStatus;
  static EdgeInsets horizontalInsetsFor(
    BuildContext context, {
    double extra = 0,
    double fontSize = 11,
  }) {
    final media = MediaQuery.of(context);
    return readerStatusInsets(
      size: media.size,
      viewPadding: media.viewPadding,
      features: media.displayFeatures,
      bandHeight: heightFor(context, fontSize: fontSize),
      textScale: media.textScaler.scale(fontSize) / 11,
      extra: extra,
    );
  }

  @override
  State<ReaderStatusFooter> createState() => _ReaderStatusFooterState();
}

/// Keep the two small labels out of off-centre holes, not just a centred notch.
/// Extra inset is bounded by available label space on compact/large-text views.
EdgeInsets readerStatusInsets({
  required Size size,
  required EdgeInsets viewPadding,
  required List<DisplayFeature> features,
  required double bandHeight,
  double textScale = 1,
  double extra = 0,
}) {
  final labelWidth = 64 * textScale;
  final baseLeft = viewPadding.left + 26, baseRight = viewPadding.right + 26;
  final available = math.max(
    0.0,
    (size.width - baseLeft - baseRight - labelWidth * 2 - 16) / 2,
  );
  final inset = extra.clamp(0.0, available);
  var left = baseLeft + inset, right = baseRight + inset;
  final band = Rect.fromLTWH(0, 0, size.width, bandHeight);
  for (final feature in features) {
    if (feature.type != DisplayFeatureType.cutout ||
        !feature.bounds.overlaps(band)) {
      continue;
    }
    final hole = feature.bounds;
    if (hole.center.dx < size.width / 2 &&
        hole.left < left + labelWidth &&
        hole.right > left) {
      left = math.max(left, hole.right + 8);
    } else if (hole.center.dx >= size.width / 2 &&
        hole.right > size.width - right - labelWidth &&
        hole.left < size.width - right) {
      right = math.max(right, size.width - hole.left + 8);
    }
  }
  return EdgeInsets.only(left: left, right: right);
}

class _ReaderStatusFooterState extends State<ReaderStatusFooter>
    with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _subscription;
  late DateTime _time = DateTime.now();
  int? _battery;
  bool _charging = false;
  @override
  void initState() {
    super.initState();
    final cached = ReaderStatusFooter._lastStatus;
    if (cached != null) _readStatus(cached);
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    if (!LocalPlatform.readerAppearance || _subscription != null) return;
    _subscription = ReaderStatusFooter._updates.listen((value) {
      if (!mounted || value is! Map) return;
      ReaderStatusFooter._lastStatus = value;
      setState(() => _readStatus(value));
    }, onError: (Object _) {});
  }

  void _readStatus(Map value) {
    final milliseconds = value['time'], battery = value['battery'];
    if (milliseconds is int) {
      _time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    _battery = battery is int && battery >= 0 && battery <= 100
        ? battery
        : null;
    _charging = value['charging'] == true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _listen();
    } else {
      _subscription?.cancel();
      _subscription = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.fontSize ?? (widget.compact ? 13.0 : 11.0);
    final time =
        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      ignoring: !widget.interactiveLeading,
      child: SizedBox(
        key: const ValueKey('reader-system-footer'),
        height: widget.statusBand
            ? ReaderStatusFooter.heightFor(context, fontSize: size)
            : widget.compact
            ? MediaQuery.textScalerOf(context).scale(size) * 1.4
            : ReaderStatusFooter.heightFor(context, fontSize: size),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: size,
            height: widget.compact ? 1.4 : 1.3,
            color: widget.ink ?? Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                if (widget.statusBand) ...[
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .36,
                      ),
                      child: widget.leading!,
                    ),
                  ),
                  const Spacer(),
                ] else
                  Expanded(child: widget.leading!),
                const SizedBox(width: 12),
              ] else if (widget.timeAtEnd)
                const Spacer(),
              IgnorePointer(
                child: AppText(time, key: const ValueKey('reader-status-time')),
              ),
              if (widget.leading == null && !widget.timeAtEnd) const Spacer(),
              if (widget.showBattery && _charging)
                const IgnorePointer(
                  child: ArchiveIcon(CupertinoIcons.bolt_fill, size: 11),
                ),
              if (widget.showBattery && _battery != null) ...[
                if (widget.compact) const SizedBox(width: 8),
                const IgnorePointer(
                  child: ArchiveIcon(CupertinoIcons.battery_100, size: 15),
                ),
                const SizedBox(width: 5),
                IgnorePointer(
                  child: AppText(
                    '$_battery%',
                    key: const ValueKey('reader-status-battery'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
