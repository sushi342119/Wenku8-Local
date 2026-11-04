import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'reader_chrome.dart';
import 'reader_status.dart';

/// Listen to pixels locally, but rebuild only when the displayed percentage
/// changes. Source progress uses only mounted row geometry after layout, never
/// eager paragraph layout, disk writes or article rebuilds on a fling.
class ReaderScrollLocation extends StatefulWidget {
  const ReaderScrollLocation({
    super.key,
    required this.controller,
    required this.title,
    required this.margin,
    required this.ink,
    required this.paper,
    this.sourceFraction,
    this.sourceTitle,
    this.bookTitle,
    this.footer = false,
    this.showClock = false,
    this.showBattery = false,
    this.onFractionChanged,
    this.chrome,
    this.reduceMotion = false,
    this.statusFontSize,
    this.statusBand = false,
    this.transparentPaper = false,
  });
  final ScrollController controller;
  final String title;
  final EdgeInsets margin;
  final Color ink, paper;
  final double? Function(double viewportOffset)? sourceFraction;
  final String? Function(double viewportOffset)? sourceTitle;
  final String? bookTitle;
  final bool footer, showClock, showBattery;
  final ValueChanged<double>? onFractionChanged;
  final Animation<double>? chrome;
  final bool reduceMotion;
  final double? statusFontSize;
  final bool statusBand;
  final bool transparentPaper;
  static double extentOf(BuildContext context) =>
      math.max(24, MediaQuery.textScalerOf(context).scale(13) * 1.4 + 6);

  @override
  State<ReaderScrollLocation> createState() => _ReaderScrollLocationState();
}

class _ReaderScrollLocationState extends State<ReaderScrollLocation> {
  int _percent = 0;
  String? _title;
  bool _updateQueued = false;
  int? _reportedPercent;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateAfterLayout);
    _updateAfterLayout();
  }

  void _updateAfterLayout() {
    if (_updateQueued) return;
    _updateQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateQueued = false;
      if (mounted) _update();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _update() {
    final controller = widget.controller;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return;
    }
    final maximum = controller.position.maxScrollExtent;
    final source = widget.sourceFraction;
    final fraction = !widget.footer && widget.onFractionChanged == null
        ? null
        : source == null
        ? (maximum > 0 ? controller.offset / maximum : 0.0)
        : controller.offset <= .5
        ? 0.0
        : controller.position.extentAfter <= .5
        ? 1.0
        : source(controller.offset);
    // A layout/restore can temporarily have no mounted source row. Keep the
    // last verified location instead of substituting an unrelated estimate.
    final percent = fraction == null
        ? _percent
        : (fraction * 100).clamp(0, 100).round();
    final title = widget.sourceTitle == null
        ? widget.title
        : widget.sourceTitle!(controller.offset) ?? _title ?? widget.title;
    if (fraction != null && _reportedPercent != percent) {
      _reportedPercent = percent;
      widget.onFractionChanged?.call(fraction.clamp(0.0, 1.0));
    }
    if (_percent != percent || _title != title) {
      setState(() {
        _percent = percent;
        _title = title;
      });
    }
  }

  @override
  void didUpdateWidget(ReaderScrollLocation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateAfterLayout);
      widget.controller.addListener(_updateAfterLayout);
    }
    if (oldWidget.onFractionChanged != widget.onFractionChanged) {
      _reportedPercent = null;
    }
    // Font, margins or viewport changes can update maxScrollExtent without
    // changing pixels, so a scroll listener alone leaves the label stale.
    _updateAfterLayout();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateAfterLayout);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: Stack(
      children: [
        if (!widget.transparentPaper)
          Positioned.fill(
            child: IgnorePointer(child: ColoredBox(color: widget.paper)),
          ),
        Padding(
          padding: widget.margin,
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize:
                  widget.statusFontSize ??
                  (widget.footer || widget.showClock ? 13 : 11),
              height: widget.footer || widget.showClock ? 1.4 : 1.3,
              color: widget.ink.withValues(alpha: .72),
            ),
            child: widget.showClock
                ? ReaderStatusFooter(
                    compact: true,
                    fontSize: widget.statusFontSize,
                    statusBand: widget.statusBand,
                    timeAtEnd: true,
                    showBattery: widget.showBattery,
                    interactiveLeading: true,
                    ink: widget.ink.withValues(alpha: .72),
                    leading: ReaderChapterTitle(
                      text: _title ?? widget.title,
                      key: const ValueKey('reader-scroll-chapter-title'),
                      chrome: widget.chrome,
                      showWithChrome: false,
                      reduceMotion: widget.reduceMotion,
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: widget.footer && widget.bookTitle != null
                            ? AppText(
                                widget.bookTitle!,
                                key: const ValueKey('reader-scroll-book-title'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : ReaderChapterTitle(
                                text: _title ?? widget.title,
                                chrome: widget.chrome,
                                showWithChrome: false,
                                reduceMotion: widget.reduceMotion,
                              ),
                      ),
                      const SizedBox(width: 12),
                      AppText(
                        '$_percent%',
                        key: const ValueKey('reader-scroll-percent'),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    ),
  );
}
