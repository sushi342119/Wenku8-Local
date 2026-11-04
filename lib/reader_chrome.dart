import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';

import 'app_ui.dart';
import 'app_window_insets.dart';
import 'dock_layout.dart';
import 'native_effects.dart' show NativeGlassGroup, NativeScrollEdgeGroup;

/// The reveal clip reserves the capsule's shadow without adding a second gutter.
const readerDockPaintPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 6,
);

/// Shares the home-indicator spacing used by the app's navigation dock.
double readerDockBottomPadding(
  BuildContext context, {
  bool viewPadding = false,
}) => DockLayout.bottomPaddingOf(context, viewPadding: viewPadding);

/// Scroll-edge treatment, mounted only while the reader controls are visible.
class ReaderEdgeBlur extends StatelessWidget {
  const ReaderEdgeBlur({
    super.key,
    this.animation = const AlwaysStoppedAnimation(1),
    this.topInset = 0,
    this.compact = false,
    this.blurBottom = true,
    this.headerExtent = FrostedHeader.toolbarHeight,
  });
  final Animation<double> animation;
  final double topInset;
  final bool compact, blurBottom;
  final double headerExtent;

  @override
  Widget build(BuildContext context) {
    final top = math.max(
      MediaQuery.paddingOf(context).top,
      AppWindowInsets.viewPaddingOf(context).top,
    );
    final blur = GlassAppearance.of(context).blur;
    final topHeight =
        top +
        topInset +
        headerExtent +
        (compact ? 24 : FrostedHeader.featherHeight);
    final highContrast = MediaQuery.highContrastOf(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final strength = Curves.easeInOut.transform(animation.value);
        if (strength == 0) return const SizedBox.shrink();
        return IgnorePointer(
          // A shared backdrop can be reused as a whole filtered result when
          // a GPU reduces both shrinking Gaussian kernels to identity. Their
          // independent dstIn feathers then erase the destination for a frame.
          // Keep the exact live radii and ramp, but give each moving edge its
          // own input; the fully visible, scrolling reader still shares input.
          child: NativeScrollEdgeGroup(
            key: const ValueKey('reader-edge-input'),
            enabled: animation.value == 1,
            child: Stack(
              children: [
                if (!highContrast)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: topHeight,
                    child: ProgressiveBlur(
                      maxSigma: blur * strength,
                      plateauHeight: top + topInset + headerExtent,
                      shadeOpacity: DockLayout.topEdgeShadeOpacity * strength,
                    ),
                  ),
                if (blurBottom)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: DockLayout.underlayExtentOf(context),
                    child: ProgressiveBlur(
                      maxSigma: blur * strength,
                      plateauHeight: DockLayout.bottomPaddingOf(
                        context,
                        viewPadding: true,
                      ),
                      fromBottom: true,
                      shadeOpacity: DockLayout.edgeShadeOpacity * strength,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Live glass leaves the viewport without an opacity saveLayer. An opacity
/// subpass changes the backdrop's origin/contents on its first partial frame.
/// At zero controls have no paint, hit targets or accessibility focus.
class ReaderChromeLayer extends StatelessWidget {
  const ReaderChromeLayer({
    super.key,
    required this.animation,
    required this.child,
    this.slide = Offset.zero,
    this.paintPadding = EdgeInsets.zero,
    this.curve = Curves.easeOutCubic,
    this.scaleFrom = 1,
    this.clip = true,
    this.maintainSize = false,
    this.interactionThreshold = .95,
  }) : assert(interactionThreshold >= 0 && interactionThreshold <= 1);
  final Animation<double> animation;
  final Widget child;
  final Offset slide;
  final EdgeInsets paintPadding;
  final Curve curve;
  final double scaleFrom;
  final bool clip;
  final bool maintainSize;

  /// Earliest visible animation value that accepts input in its painted bounds.
  final double interactionThreshold;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final inactive =
          animation.value == 0 || animation.value < interactionThreshold;
      final layer = IgnorePointer(
        ignoring: inactive,
        child: ExcludeSemantics(
          excluding: inactive,
          child: NativeGlassGroup(
            inherit: false,
            child: ClipRect(
              clipBehavior: clip ? Clip.hardEdge : Clip.none,
              child: FractionalTranslation(
                translation:
                    slide *
                    (1 - curve.transform(animation.value.clamp(0.0, 1.0))),
                child: Transform.scale(
                  scale:
                      scaleFrom +
                      (1 - scaleFrom) *
                          curve.transform(animation.value.clamp(0.0, 1.0)),
                  child: Padding(padding: paintPadding, child: child),
                ),
              ),
            ),
          ),
        ),
      );
      if (!maintainSize) {
        return Offstage(offstage: animation.value == 0, child: layer);
      }
      // The follow action shares these real dimensions while the capsules
      // travel. Hidden controls still neither paint, tick nor receive input.
      return Visibility(
        visible: animation.value != 0,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: TickerMode(enabled: animation.value != 0, child: layer),
      );
    },
  );
}

/// Keeps a hidden chrome leaf's geometry without rebuilding it for source
/// updates. The data source stays live; the first reveal reads its latest value.
/// Visibility crossings, not animation ticks or TickerMode, own the subscription.
class ReaderChromeValueBuilder<T> extends StatefulWidget {
  const ReaderChromeValueBuilder({
    super.key,
    required this.visibility,
    required this.valueListenable,
    required this.builder,
  });
  final Animation<double> visibility;
  final ValueListenable<T> valueListenable;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<ReaderChromeValueBuilder<T>> createState() =>
      _ReaderChromeValueBuilderState<T>();
}

class _ReaderChromeValueBuilderState<T>
    extends State<ReaderChromeValueBuilder<T>> {
  ValueListenable<T>? _subscribedTo;
  late bool _visible;

  @override
  void initState() {
    super.initState();
    _visible = widget.visibility.value != 0;
    widget.visibility.addListener(_visibilityChanged);
    _subscribe();
  }

  void _subscribe() {
    final source = _visible ? widget.valueListenable : null;
    if (_subscribedTo == source) return;
    _subscribedTo?.removeListener(_changed);
    _subscribedTo = source;
    source?.addListener(_changed);
  }

  void _visibilityChanged() {
    final visible = widget.visibility.value != 0;
    if (_visible == visible) return;
    _visible = visible;
    _subscribe();
    if (visible) setState(() {});
  }

  void _changed() => setState(() {});

  @override
  void didUpdateWidget(ReaderChromeValueBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visibility != widget.visibility) {
      oldWidget.visibility.removeListener(_visibilityChanged);
      widget.visibility.addListener(_visibilityChanged);
    }
    _visible = widget.visibility.value != 0;
    _subscribe();
  }

  @override
  void dispose() {
    _subscribedTo?.removeListener(_changed);
    widget.visibility.removeListener(_visibilityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.valueListenable.value);
}

/// An independent secondary action using the same glass/press treatment as the
/// follow control, without enlarging the header's full-width blur and shade.
class ReaderHandoffChip extends StatelessWidget {
  const ReaderHandoffChip({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GlassTextButton(
    compact: true,
    compactMainPage: true,
    onPressed: onPressed,
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveIcon(CupertinoIcons.device_laptop, size: 17),
        SizedBox(width: 8),
        Flexible(
          child: AppText(
            '在其他设备上续读',
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The location line is plain text/paper, not live glass. Its small alpha layer
/// can dissolve while the header glides in, without filtering the article or
/// changing the backdrop origin of any glass controls.
class ReaderLocationLayer extends SingleChildRenderObjectWidget {
  const ReaderLocationLayer({
    super.key,
    required this.chrome,
    required super.child,
    this.interactive = false,
  });
  final Animation<double> chrome;
  final bool interactive;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReaderLocation(chrome, interactive);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderReaderLocation)
      ..chrome = chrome
      ..interactive = interactive;
  }
}

class _RenderReaderLocation extends RenderProxyBox {
  _RenderReaderLocation(this._chrome, this._interactive);

  Animation<double> _chrome;
  bool _interactive;
  bool _semanticsVisible = true;
  final _opacityLayer = LayerHandle<OpacityLayer>();
  final _transformLayer = LayerHandle<TransformLayer>();

  double get _visible => 1 - Curves.easeInOutCubic.transform(_chrome.value);
  Offset get _shift => Offset(0, -6 * (1 - _visible));

  set chrome(Animation<double> value) {
    if (_chrome == value) return;
    if (attached) _chrome.removeListener(_changed);
    _chrome = value;
    if (attached) _chrome.addListener(_changed);
    _changed();
  }

  set interactive(bool value) {
    if (_interactive == value) return;
    _interactive = value;
    markNeedsSemanticsUpdate();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  Rect get paintBounds => Offset(0, -6) & Size(size.width, size.height + 6);

  void _changed() {
    // A widget rebuild inside LayoutBuilder's private BuildScope requests a
    // layout callback even when geometry is unchanged. Animate this small text
    // plane in paint instead, leaving the turning sheet and article untouched.
    markNeedsPaint();
    final visible = _visible >= .95;
    if (_semanticsVisible || visible) {
      markNeedsSemanticsUpdate();
    }
    _semanticsVisible = visible;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _semanticsVisible = _visible >= .95;
    _chrome.addListener(_changed);
  }

  @override
  void detach() {
    _chrome.removeListener(_changed);
    super.detach();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      _interactive &&
      _visible >= .95 &&
      result.addWithPaintOffset(
        offset: _shift,
        position: position,
        hitTest: (result, position) =>
            super.hitTest(result, position: position),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_semanticsVisible) super.visitChildrenForSemantics(visitor);
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isBlockingUserActions = !_interactive || !_semanticsVisible;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final alpha = (_visible * 255).round();
    if (alpha == 0 || child == null) return;
    _opacityLayer.layer = context.pushOpacity(offset, alpha, (context, offset) {
      _transformLayer.layer = context.pushTransform(
        needsCompositing,
        offset,
        Matrix4.translationValues(_shift.dx, _shift.dy, 0),
        super.paint,
        oldLayer: _transformLayer.layer,
      );
    }, oldLayer: _opacityLayer.layer);
  }

  @override
  void dispose() {
    _opacityLayer.layer = null;
    _transformLayer.layer = null;
    super.dispose();
  }
}

/// A chapter label, not a second text system: the existing AppText stays on one
/// line in a horizontal viewport. Only an overflowing, currently visible label
/// schedules movement; pauses leave no frame ticker running.
class ReaderChapterTitle extends StatefulWidget {
  const ReaderChapterTitle({
    super.key,
    required this.text,
    this.style,
    this.textAlign = TextAlign.start,
    this.active = true,
    this.reduceMotion = false,
    this.chrome,
    this.showWithChrome = true,
  });
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final bool active, reduceMotion, showWithChrome;
  final Animation<double>? chrome;

  @override
  State<ReaderChapterTitle> createState() => _ReaderChapterTitleState();
}

class _ReaderChapterTitleState extends State<ReaderChapterTitle>
    with WidgetsBindingObserver {
  final _scroll = ScrollController(keepScrollOffset: false);
  Timer? _pause;
  int _ticket = 0;
  bool _queued = false, _resetPending = false, _running = false;
  bool _forward = true, _overflow = false, _dragging = false;
  bool _completedCycle = false, _wasVisible = false;
  late bool _foreground;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.chrome?.addListener(_visibilityChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _afterLayout();
  }

  @override
  void didUpdateWidget(ReaderChapterTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chrome != widget.chrome) {
      oldWidget.chrome?.removeListener(_visibilityChanged);
      widget.chrome?.addListener(_visibilityChanged);
    }
    _afterLayout(reset: oldWidget.text != widget.text);
  }

  bool get _visible {
    if (!widget.active ||
        !_foreground ||
        !TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    final chrome = widget.chrome;
    return chrome == null ||
        (widget.showWithChrome ? chrome.value >= .95 : chrome.value <= .05);
  }

  bool get _enabled =>
      _visible &&
      !_dragging &&
      !widget.reduceMotion &&
      !MediaQuery.disableAnimationsOf(context);

  void _visibilityChanged() {
    if (mounted) _synchronize();
  }

  void _afterLayout({bool reset = false}) {
    _resetPending |= reset;
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      if (_resetPending) {
        _resetPending = false;
        _stop();
        _forward = true;
        _completedCycle = false;
        if (_scroll.hasClients) _scroll.jumpTo(0);
      }
      _synchronize();
    });
  }

  void _stop() {
    _ticket++;
    _pause?.cancel();
    _pause = null;
    if (_running && _scroll.hasClients) _scroll.jumpTo(_scroll.offset);
    _running = false;
  }

  void _synchronize() {
    final visible = _visible;
    if (visible && !_wasVisible) {
      _completedCycle = false;
      _forward = true;
    }
    _wasVisible = visible;
    final overflow =
        _scroll.hasClients &&
        _scroll.position.hasContentDimensions &&
        _scroll.position.maxScrollExtent > 1;
    if (_overflow != overflow) setState(() => _overflow = overflow);
    if (!_enabled || !overflow || _completedCycle) {
      _stop();
      return;
    }
    if (_running) return;
    _running = true;
    final ticket = ++_ticket;
    _pause = Timer(const Duration(milliseconds: 1200), () => _travel(ticket));
  }

  void _manualStart(DragStartDetails details) {
    if (!_visible) return;
    _dragging = true;
    _stop();
  }

  void _manualUpdate(DragUpdateDetails details) {
    if (!_dragging || !_visible || !_scroll.hasClients) return;
    _scroll.jumpTo(
      (_scroll.offset - details.delta.dx).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      ),
    );
  }

  void _manualFinish() {
    _dragging = false;
    _completedCycle = false;
    _forward = true;
    _synchronize();
  }

  Future<void> _travel(int ticket) async {
    _pause = null;
    if (!mounted || ticket != _ticket || !_enabled || !_scroll.hasClients) {
      return;
    }
    final target = _forward ? _scroll.position.maxScrollExtent : 0.0;
    final distance = (target - _scroll.offset).abs();
    await _scroll.animateTo(
      target,
      duration: Duration(
        milliseconds: math.max(300, (distance / 28 * 1000).round()),
      ),
      curve: Curves.linear,
    );
    if (!mounted || ticket != _ticket || !_enabled) return;
    // Reveal a long title once, then leave the reading surface idle. A fresh
    // chapter, chrome reveal or deliberate horizontal drag starts another pass.
    if (!_forward) {
      _completedCycle = true;
      _running = false;
      return;
    }
    _forward = !_forward;
    _pause = Timer(const Duration(milliseconds: 1200), () => _travel(ticket));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) _synchronize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.chrome?.removeListener(_visibilityChanged);
    _pause?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _afterLayout();
      // This label overlays the reading surface. A translucent horizontal-only
      // recognizer keeps the original body in the arena for taps/vertical drags;
      // the scroll viewport itself must not become an opaque input dead zone.
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _overflow ? _manualStart : null,
        onHorizontalDragUpdate: _overflow ? _manualUpdate : null,
        onHorizontalDragEnd: _overflow ? (_) => _manualFinish() : null,
        onHorizontalDragCancel: _overflow ? _manualFinish : null,
        child: IgnorePointer(
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            primary: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: AppText(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textAlign: widget.textAlign,
                style: widget.style,
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A separate, finite entrance: recovering follow never changes article layout
/// or replays the main reader chrome. Live glass is clipped, not alpha-layered.
class ReaderFollowDock extends StatefulWidget {
  const ReaderFollowDock({
    super.key,
    required this.visible,
    required this.chrome,
    required this.onEnable,
    required this.controls,
    required this.hiddenExtent,
    this.reduceMotion = false,
  });
  final bool visible;
  final Animation<double> chrome;
  final VoidCallback onEnable;
  final Widget controls;

  /// Distance from this dock's bottom to the hidden reader information row.
  final double hiddenExtent;
  final bool reduceMotion;

  @override
  State<ReaderFollowDock> createState() => _ReaderFollowDockState();
}

class _ReaderFollowDockState extends State<ReaderFollowDock>
    with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController(
    vsync: this,
    duration: NovelMotion.enter,
    reverseDuration: NovelMotion.exit,
    value: widget.visible ? 1 : 0,
  )..addStatusListener(_entranceStatus);

  void _entranceStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ReaderFollowDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _entrance.forward();
    } else {
      _entrance.reverse();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showPrompt =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        (widget.visible || !_entrance.isDismissed);
    return Flow(
      delegate: _ReaderFollowPlacement(
        chrome: widget.chrome,
        hiddenExtent: widget.hiddenExtent,
        showPrompt: showPrompt,
      ),
      children: [
        widget.controls,
        if (showPrompt)
          IgnorePointer(
            ignoring: !widget.visible,
            child: ReaderChromeLayer(
              animation: _entrance,
              slide: const Offset(0, 1),
              paintPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              child: ControlMaterialScope.chrome(
                child: GlassTextButton(
                  key: const ValueKey('reader-enable-follow'),
                  onPressed: widget.onEnable,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ArchiveIcon(CupertinoIcons.location_fill, size: 17),
                      SizedBox(width: 8),
                      AppText('开启跟随'),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Repositions only paint. Chrome ticks never relayout the glass action, and
/// an absent prompt has neither a glass subtree nor an animation subscription.
class _ReaderFollowPlacement extends FlowDelegate {
  _ReaderFollowPlacement({
    required this.chrome,
    required this.hiddenExtent,
    required this.showPrompt,
  }) : super(repaint: showPrompt ? chrome : null);

  final Animation<double> chrome;
  final double hiddenExtent;
  final bool showPrompt;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints.loosen();

  @override
  void paintChildren(FlowPaintingContext context) {
    final controls = context.getChildSize(0)!;
    context.paintChild(
      0,
      transform: Matrix4.translationValues(
        (context.size.width - controls.width) / 2,
        context.size.height - controls.height,
        0,
      ),
    );
    if (!showPrompt) return;
    final prompt = context.getChildSize(1)!;
    final progress = NovelMotion.settle.transform(chrome.value);
    // Four points are already reserved below the action for its shadow.
    final bottom =
        hiddenExtent + (controls.height - hiddenExtent) * progress + 8 - 4;
    context.paintChild(
      1,
      transform: Matrix4.translationValues(
        (context.size.width - prompt.width) / 2,
        context.size.height - bottom - prompt.height,
        0,
      ),
    );
  }

  @override
  bool shouldRepaint(_ReaderFollowPlacement oldDelegate) =>
      oldDelegate.chrome != chrome ||
      oldDelegate.hiddenExtent != hiddenExtent ||
      oldDelegate.showPrompt != showPrompt;
}
