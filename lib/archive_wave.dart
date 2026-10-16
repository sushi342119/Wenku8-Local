import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'app_ui.dart';
import 'archive_scroll_simulation.dart';
import 'archive_shelf_geometry.dart';
import 'catalog.dart';
import 'performance_preferences.dart';

/// Scroll position is the single clock for the continuous extraction wave.
class ArchiveFileCarousel extends StatefulWidget {
  const ArchiveFileCarousel({
    super.key,
    required this.books,
    required this.onOpen,
    this.reduceMotion = false,
    this.animateEntrance = false,
  });
  final List<Novel> books;
  final void Function(Novel book, Object heroTag) onOpen;
  final bool reduceMotion;
  final bool animateEntrance;
  @override
  State<ArchiveFileCarousel> createState() => _ArchiveFileCarouselState();
}

class _ArchiveFileCarouselState extends State<ArchiveFileCarousel>
    with SingleTickerProviderStateMixin {
  ScrollController? _scroll;
  late final _WavePose _pose;
  late final ValueNotifier<int> _active;
  int? _targetIndex;
  int _command = 0;
  bool _reduced = false;
  bool _hapticGesture = false;
  int? _lastDetent;
  int _lastPulse = -1000;
  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
    value: widget.animateEntrance ? 0 : 1,
  )..addListener(_assemble);

  @visibleForTesting
  AnimationController get debugEntranceClock => _entrance;

  void _assemble() => _pose.present(_entrance.value);

  void _finishEntrance() {
    if (!_entrance.isCompleted) _entrance.value = 1;
  }

  Widget _entryLabel(Widget child, double start) => widget.animateEntrance
      ? RevealFromTop(animation: _entrance, start: start, end: 1, child: child)
      : child;

  @override
  void initState() {
    super.initState();
    _pose = _WavePose(widget.books.length, 0);
    _active = ValueNotifier(0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.reduceMotion ||
        !PerformanceScope.of(context).shelf3d ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _finishEntrance();
    } else if (!_entrance.isAnimating && !_entrance.isCompleted) {
      _pose.present(_entrance.value);
      _entrance.forward();
    }
  }

  @override
  void didUpdateWidget(ArchiveFileCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pose.count = widget.books.length;
    _pose.move(_pose.logicalFocus);
    _active.value = _pose.logicalFocus.round();
    if (widget.reduceMotion) _finishEntrance();
  }

  void _scrolled() {
    if (_scroll?.hasClients != true) return;
    _pose.move(_scroll!.offset / _pose.pitch);
    final lane = _pose.logicalFocus.round();
    if (_active.value != lane) {
      _active.value = lane;
    }
    // One light detent on entering a centre, not continuous vibration or one
    // pulse per rendered frame. Flutter respects the system haptic preference.
    final now =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMilliseconds;
    if (_hapticGesture &&
        widget.books.length > 1 &&
        (_pose.logicalFocus - lane).abs() < .12 &&
        lane != _lastDetent &&
        now - _lastPulse >= 65) {
      _lastDetent = lane;
      _lastPulse = now;
      unawaited(HapticFeedback.selectionClick());
    }
  }

  void _tap(int index) {
    if ((_pose.focus - index).abs() < .03 &&
        _scroll?.position.isScrollingNotifier.value == false) {
      _open(index);
    } else {
      unawaited(_centre(_pose.logicalLane(index)));
    }
  }

  Future<void> _centre(int index) async {
    if (widget.books.length < 2 || _scroll?.hasClients != true) {
      return;
    }
    _finishEntrance();
    final command = ++_command;
    _targetIndex = index;
    if (!_hapticGesture) _lastDetent = _pose.logicalFocus.round();
    _hapticGesture = true;
    final target = index * _pose.pitch;
    if (_reduced) {
      _scroll!.jumpTo(target);
    } else {
      await _scroll!.animateTo(
        target,
        duration: NovelMotion.enter,
        curve: const Cubic(.2, 1.06, .35, 1),
      );
    }
    if (mounted && command == _command) {
      _targetIndex = null;
      _hapticGesture = false;
    }
  }

  void _step(int delta) =>
      unawaited(_centre((_targetIndex ?? _active.value) + delta));
  void _open(int index) {
    if (widget.books.isEmpty) return;
    _finishEntrance();
    _command++;
    _targetIndex = null;
    _hapticGesture = false;
    if (_scroll?.hasClients == true) {
      (_scroll!.position as ScrollPositionWithSingleContext).goIdle();
    }
    final book = widget.books[_pose.bookIndex(index)];
    widget.onOpen(book, CoverHeroTag(this, book.id));
  }

  @override
  void dispose() {
    _scroll?.removeListener(_scrolled);
    _scroll?.dispose();
    _entrance.dispose();
    _pose.dispose();
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.books.isEmpty) return const SizedBox.shrink();
    if (!PerformanceScope.of(context).shelf3d) {
      return _FlatArchiveCarousel(books: widget.books, onOpen: widget.onOpen);
    }
    _reduced = widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final spine = _WavePose.spineFor(width);
        final pitch = _WavePose.pitchFor(width);
        final cover = _WavePose.coverFor(width);
        final height = ArchiveShelfGeometry.bodyHeight(cover);
        _pose.configure(width, pitch);
        _scroll ??= ScrollController(
          initialScrollOffset: _pose.logicalFocus * pitch,
          // This state owns the unbounded lane. Nested discovery PageStorage
          // must not restore vertical feed pixels into the horizontal bank.
          keepScrollOffset: false,
        )..addListener(_scrolled);
        final rowHeight = ArchiveShelfGeometry.rowHeight(cover, height);
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: rowHeight,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _finishEntrance();
                    _targetIndex = null;
                    _command++;
                    _hapticGesture = true;
                    _lastDetent = _pose.logicalFocus.round();
                  } else if (notification is ScrollStartNotification &&
                      _targetIndex != null) {
                    _hapticGesture = true;
                  } else if (notification is ScrollEndNotification) {
                    _hapticGesture = false;
                  }
                  return false;
                },
                child: Scrollable(
                  key: const ValueKey('archive-file-carousel'),
                  controller: _scroll,
                  axisDirection: AxisDirection.right,
                  physics: widget.books.length == 1
                      ? const NeverScrollableScrollPhysics()
                      : _ArchiveSnapPhysics(pose: _pose),
                  viewportBuilder: (context, offset) => _ShelfRow(
                    offset: offset,
                    pose: _pose,
                    spine: spine,
                    cover: cover,
                    height: height,
                    dark: dark,
                    children: [
                      for (var i = 0; i < _pose.poolCount; i++)
                        _volume(
                          context,
                          widget.books[_pose.bookIndex(i)],
                          i,
                          spine,
                          cover,
                          height,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // Only labels change at index crossings. Never rebuild the bank for
            // each scroll pixel, and never restart a separate extraction timer.
            _entryLabel(
              ValueListenableBuilder<int>(
                valueListenable: _active,
                builder: (context, index, _) {
                  final book = widget.books[index % widget.books.length];
                  final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
                  return SizedBox(
                    height: 16 + 17 * 1.35 * 2 * scale + 12 * 1.4 * scale,
                    child: JellyTapSurface(
                      key: const ValueKey('archive-shelf-open'),
                      onTap: () => _open(_pose.focus.round()),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    book.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      height: 1.35,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '${book.author} · ${book.isComplete ? '已完结' : '连载中'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.4,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(CupertinoIcons.arrow_up_right, size: 20),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              .52,
            ),
            _entryLabel(
              ValueListenableBuilder<int>(
                valueListenable: _active,
                builder: (context, index, _) => Row(
                  children: [
                    const Spacer(),
                    if (widget.books.length > 1) ...[
                      IconButton(
                        tooltip: '上一份档案',
                        onPressed: () => _step(-1),
                        icon: const Icon(CupertinoIcons.chevron_left, size: 13),
                        visualDensity: VisualDensity.compact,
                      ),
                      Semantics(
                        label:
                            '第 ${index % widget.books.length + 1} 本，共 ${widget.books.length} 本，循环浏览',
                        child: ArchiveCode(
                          '${(index % widget.books.length + 1).toString().padLeft(2, '0')} / ${widget.books.length.toString().padLeft(2, '0')}',
                        ),
                      ),
                      IconButton(
                        tooltip: '下一份档案',
                        onPressed: () => _step(1),
                        icon: const Icon(
                          CupertinoIcons.chevron_right,
                          size: 13,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
              ),
              .72,
            ),
          ],
        );
      },
    );
  }

  Widget _volume(
    BuildContext context,
    Novel book,
    int index,
    double spine,
    double cover,
    double height,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final number = _pose.bookIndex(index) + 1;
    void tap() => _tap(index);
    final glyphs = book.title.characters.toList();
    final title = [...glyphs.take(7), if (glyphs.length > 7) '…'].join('\n');
    return _BookVolume(
      key: ValueKey('archive-slot-$index'),
      pose: _pose,
      index: index,
      spine: spine,
      cover: cover,
      height: height,
      dark: dark,
      label: book.title,
      direction: Directionality.of(context),
      onTap: tap,
      children: [
        ExcludeSemantics(
          child: RepaintBoundary(
            child: ContentPanel(
              key: ValueKey('archive-spine-$index'),
              radius: 0,
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 9),
              // Solid physical faces occlude other files; milk comes from shading,
              // not alpha that lets readable rear text bleed through the surface.
              backgroundColor: dark
                  ? const Color(0xFF2D332D)
                  : const Color(0xFFF2F0E9),
              onTap: tap,
              child: MediaQuery.withNoTextScaling(
                child: Column(
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: ArchiveCode(number.toString().padLeft(2, '0')),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Center(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 9,
                            height: 1.08,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Icon(
                      CupertinoIcons.circle,
                      size: 6,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ExcludeSemantics(
          child: RepaintBoundary(
            child: ContentPanel(
              key: ValueKey('archive-cover-$index'),
              radius: 0,
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 8),
              backgroundColor: dark
                  ? const Color(0xFF292F29)
                  : ArchiveDesign.milk,
              onTap: tap,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ArchiveCode(
                      'NO.${number.toString().padLeft(3, '0')}',
                    ),
                  ),
                  const SizedBox(height: 7),
                  Expanded(
                    child: _LazyArchiveCover(
                      book: book,
                      pose: _pose,
                      index: index,
                      width: cover - 20,
                      height: (cover - 20) * 166 / 118,
                      // Only the focused copy participates in Hero. Its stable
                      // identity survives pool wrapping and viewport resizing.
                      heroTag: CoverHeroTag(this, book.id),
                      reduced: _reduced,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ArchiveCode(ArchiveDesign.fileCode(book.id)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A virtual, lazily built loop with no perspective mesh or extraction layers.
/// It keeps discovery's cover navigation available on the lightweight preset.
class _FlatArchiveCarousel extends StatefulWidget {
  const _FlatArchiveCarousel({required this.books, required this.onOpen});
  final List<Novel> books;
  final void Function(Novel book, Object heroTag) onOpen;
  @override
  State<_FlatArchiveCarousel> createState() => _FlatArchiveCarouselState();
}

class _FlatArchiveCarouselState extends State<_FlatArchiveCarousel> {
  final _heroSource = Object();
  late final _start = widget.books.length * 10000;
  late final _pages = PageController(
    initialPage: _start,
    viewportFraction: .62,
  );

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('archive-flat-carousel'),
    height: 300,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: PageView.builder(
          controller: _pages,
          physics: widget.books.length == 1
              ? const NeverScrollableScrollPhysics()
              : null,
          itemBuilder: (context, index) {
            final book = widget.books[index % widget.books.length];
            final tag = (_heroSource, index, book.id);
            return Semantics(
              label: '${book.title}，${book.author}',
              button: true,
              child: GestureDetector(
                onTap: () => widget.onOpen(book, tag),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: NovelCover(
                              book,
                              width: 154,
                              height: 220,
                              heroTag: tag,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: SizedBox(
                          width: 154,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  height: 1.4,
                                ),
                              ),
                              Text(
                                book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Keep only the crest and its two neighbours mounted as actual image widgets.
class _LazyArchiveCover extends StatefulWidget {
  const _LazyArchiveCover({
    required this.book,
    required this.pose,
    required this.index,
    required this.width,
    required this.height,
    required this.heroTag,
    required this.reduced,
  });
  final Novel book;
  final _WavePose pose;
  final int index;
  final double width, height;
  final Object heroTag;
  final bool reduced;
  @override
  State<_LazyArchiveCover> createState() => _LazyArchiveCoverState();
}

class _LazyArchiveCoverState extends State<_LazyArchiveCover> {
  bool get _near => (widget.pose.focus.round() - widget.index).abs() <= 1;
  bool get _focused => widget.pose.focus.round() == widget.index;
  late bool _lastNear, _lastFocused;
  @override
  void initState() {
    super.initState();
    _lastNear = _near;
    _lastFocused = _focused;
    widget.pose.addListener(_changed);
  }

  @override
  void didUpdateWidget(_LazyArchiveCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pose != widget.pose) {
      oldWidget.pose.removeListener(_changed);
      widget.pose.addListener(_changed);
    }
    _lastNear = _near;
    _lastFocused = _focused;
  }

  void _changed() {
    if (_near == _lastNear && _focused == _lastFocused) return;
    setState(() {
      _lastNear = _near;
      _lastFocused = _focused;
    });
  }

  @override
  void dispose() {
    widget.pose.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_near
      ? const SizedBox.expand()
      : Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations:
                    widget.reduced ||
                    !_focused ||
                    MediaQuery.disableAnimationsOf(context),
              ),
              child: TickerMode(
                enabled: _focused,
                child: NovelCover(
                  widget.book,
                  width: widget.width,
                  height: widget.height,
                  heroTag: widget.heroTag,
                ),
              ),
            ),
          ),
        );
}

class _ArchiveSnapPhysics extends ScrollPhysics {
  const _ArchiveSnapPhysics({
    required this.pose,
    super.parent = const ClampingScrollPhysics(),
  });
  final _WavePose pose;
  @override
  _ArchiveSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _ArchiveSnapPhysics(pose: pose, parent: buildParent(ancestor));
  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    // Preserve fractional focus during layout instead of jumping a frame later.
    if (!oldPosition.hasViewportDimension ||
        oldPosition.viewportDimension <= 0) {
      return newPosition.pixels.clamp(
        newPosition.minScrollExtent,
        newPosition.maxScrollExtent,
      );
    }
    // Infinite extents keep extentBefore/After unchanged, so the framework's
    // last metrics can hold old pixels. Use live pixels with the old pitch.
    final focus =
        newPosition.pixels / _WavePose.pitchFor(oldPosition.viewportDimension);
    if (!isScrolling &&
        oldPosition.viewportDimension != newPosition.viewportDimension) {
      pose.holdLayoutFocus = true;
    }
    return (focus * _WavePose.pitchFor(newPosition.viewportDimension)).clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (pose.holdLayoutFocus && velocity == 0) {
      pose.holdLayoutFocus = false;
      return null;
    }
    pose.holdLayoutFocus = false;
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final pitch = _WavePose.pitchFor(position.viewportDimension);
    final simulation = ArchiveScrollSimulation(
      position: position.pixels,
      velocity: velocity,
      pitch: pitch,
      minimumVelocity: minFlingVelocity,
      tolerance: toleranceFor(position),
    );
    if ((simulation.target - position.pixels).abs() < .01 && velocity == 0) {
      return null;
    }
    return simulation;
  }
}

class _WavePose extends ChangeNotifier {
  _WavePose(this.count, this.logicalFocus);
  int count;
  double logicalFocus;
  double viewport = 340, pitch = pitchFor(340);
  int edgeSlots = 15;
  bool holdLayoutFocus = false;
  double entrance = 1;
  double get focus => count < 2 ? 0 : edgeSlots + logicalFocus % count;
  int get poolCount => count < 2 ? count : count + edgeSlots * 2;
  int bookIndex(int slot) => count < 2 ? 0 : (slot - edgeSlots) % count;
  int logicalLane(int slot) =>
      count < 2 ? 0 : (logicalFocus / count).floor() * count + slot - edgeSlots;
  static const depthX = ArchiveShelfGeometry.depthX;
  static const depthY = ArchiveShelfGeometry.depthY;
  static const radius = 1.48;
  static double spineFor(double width) => ArchiveShelfGeometry.spineFor(width);
  static double pitchFor(double width) => ArchiveShelfGeometry.pitchFor(width);
  static double coverFor(double width) => ArchiveShelfGeometry.coverFor(width);
  static double footprint(double spine, double cover) =>
      ArchiveShelfGeometry.footprint(spine, cover);
  static double pullDistance(double cover) =>
      ArchiveShelfGeometry.pullDistance(cover);
  static double baseY(double cover, double height) =>
      ArchiveShelfGeometry.baseY(cover, height);
  void configure(double width, double nextPitch) {
    viewport = width;
    pitch = nextPitch;
    final cover = coverFor(width);
    edgeSlots =
        ((width / 2 +
                    footprint(spineFor(width), cover) +
                    pullDistance(cover) * depthX) /
                pitch)
            .ceil() +
        2;
  }

  void move(double next, {bool notify = true}) {
    if (count < 2) next = 0;
    if ((logicalFocus - next).abs() < .000001) return;
    logicalFocus = next;
    if (notify) notifyListeners();
  }

  void present(double value) {
    if (entrance == value) return;
    entrance = value;
    notifyListeners();
  }

  Offset assemblyOffset(int slot) {
    if (entrance == 1) return Offset.zero;
    // Assemble from the back along each parallel solid's depth axis. Stagger
    // only the visible bank, never the number of logical loop occurrences.
    final order = ((slot - focus) + viewport / pitch / 2 + 2).clamp(0.0, 16.0);
    final start = order * .018;
    final progress = Interval(
      start,
      start + .52,
      curve: Curves.easeOutCubic,
    ).transform(entrance);
    return const Offset(depthX, depthY) * (56 * (1 - progress));
  }

  double railY(int slot) {
    return ArchiveShelfGeometry.railY(slot - focus);
  }

  double weight(int index) {
    final distance = (index - focus).abs();
    if (distance >= radius) return 0;
    final value = math.cos(distance / radius * math.pi / 2);
    final crest = entrance == 1
        ? 1.0
        : const Interval(
            .38,
            1,
            curve: Curves.easeOutCubic,
          ).transform(entrance);
    return value * value * crest;
  }
}

class _ShelfRow extends MultiChildRenderObjectWidget {
  const _ShelfRow({
    required this.offset,
    required this.pose,
    required this.spine,
    required this.cover,
    required this.height,
    required this.dark,
    required super.children,
  });
  final ViewportOffset offset;
  final _WavePose pose;
  final double spine, cover, height;
  final bool dark;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      ArchiveShelfSceneRender._(offset, pose, spine, cover, height, dark);
  @override
  void updateRenderObject(
    BuildContext context,
    ArchiveShelfSceneRender renderObject,
  ) => renderObject._update(offset, pose, spine, cover, height, dark);
}

class _ShelfParentData extends ContainerBoxParentData<RenderBox> {}

/// Parallel x-separated solids have a fixed occlusion order. Sorting by lift or
/// selected index causes impossible intersections and mid-scroll order pops.
class ArchiveShelfSceneRender extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ShelfParentData>
    implements PaperCoverOcclusionSource {
  ArchiveShelfSceneRender._(
    this._scrollOffset,
    this._pose,
    this._spine,
    this._cover,
    this._height,
    this._dark,
  );
  ViewportOffset _scrollOffset;
  _WavePose _pose;
  double _spine, _cover, _height;
  bool _dark;
  final _boxes = <RenderBox>[];
  final _x = <double>[];
  final _clipLayer = LayerHandle<ClipRectLayer>();
  int debugLayoutCount = 0;
  double get debugFocus => _pose.logicalFocus;
  int get debugCentreSlot => _pose.focus.round();
  int get debugPoolCount => _pose.poolCount;
  double get debugPitch => _pose.pitch;
  double get debugEntranceProgress => _pose.entrance;
  Offset debugAssemblyOffset(int slot) => _pose.assemblyOffset(slot);
  List<int> get debugPaintOrder => _visible;
  @override
  Path? coverOcclusion(RenderBox face) {
    RenderObject? volume = face;
    while (volume != null && volume.parent != this) {
      volume = volume.parent;
    }
    if (volume is! RenderBox) return null;
    final slot = _boxes.indexOf(volume);
    if (slot < 0) return null;
    final faceBounds = MatrixUtils.transformRect(
      face.getTransformTo(null),
      Offset.zero & face.size,
    );
    var mask = Path();
    var occluded = false;
    for (final i in _visible.where((i) => i > slot)) {
      final box = _boxes[i] as ArchiveBoxDepthRender;
      final path = box._solidPath.transform(box.getTransformTo(null).storage);
      if (!path.getBounds().overlaps(faceBounds)) continue;
      // Top and side faces have opposite winding. A mere addPath can cancel
      // overlapping foreground silhouettes and expose holes in the flight.
      mask = Path.combine(PathOperation.union, mask, path);
      occluded = true;
    }
    return occluded ? mask : null;
  }

  Rect get _viewport => Offset.zero & size;
  Offset _offset(int i) =>
      Offset(_x[i] - _pose.focus * _pose.pitch, _pose.railY(i)) +
      _pose.assemblyOffset(i);
  List<int> get _visible => [
    for (var i = 0; i < _boxes.length; i++)
      if (_viewport.overlaps(_boxes[i].paintBounds.shift(_offset(i)))) i,
  ];
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ShelfParentData) {
      child.parentData = _ShelfParentData();
    }
  }

  void _update(
    ViewportOffset offset,
    _WavePose pose,
    double spine,
    double cover,
    double height,
    bool dark,
  ) {
    _scrollOffset = offset;
    if (_pose != pose) {
      if (attached) _pose.removeListener(_changed);
      _pose = pose;
      if (attached) _pose.addListener(_changed);
    }
    _spine = spine;
    _cover = cover;
    _height = height;
    _dark = dark;
    markNeedsLayout();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pose.addListener(_changed);
  }

  @override
  void detach() {
    _pose.removeListener(_changed);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    _scrollOffset.applyViewportDimension(size.width);
    // A resized viewport may correct its pixels on the first attempt. Accept
    // the new dimensions before deriving the pool's fractional lane.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_scrollOffset.applyContentDimensions(
        _pose.count < 2 ? 0 : double.negativeInfinity,
        _pose.count < 2 ? 0 : double.infinity,
      )) {
        break;
      }
    }
    _pose.move(_scrollOffset.pixels / _pose.pitch, notify: false);
    _boxes.clear();
    _x.clear();
    final start =
        _pose.viewport / 2 -
        _WavePose.footprint(_spine, _cover) / 2 +
        _WavePose.pullDistance(_cover) * _WavePose.depthX;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tight(Size(_spine + _cover, size.height)));
      _x.add(start + _boxes.length * _pose.pitch);
      _boxes.add(child);
      child = childAfter(child);
    }
    debugLayoutCount++;
  }

  void _floor(Canvas canvas, Offset offset, List<int> visible) {
    final ink = _dark ? ArchiveDesign.milk : const Color(0xFF8A806B);
    final depth = Offset(_cover * _WavePose.depthX, _cover * _WavePose.depthY);
    for (final i in visible) {
      final origin =
          offset +
          _offset(i) +
          Offset(0, _WavePose.baseY(_cover, _height) + _height);
      final path = Path()
        ..addPolygon([
          origin,
          origin + Offset(_spine, 1.4),
          origin + Offset(_spine, 1.4) + depth,
          origin + depth,
          origin + depth + const Offset(-10, 10),
          origin + const Offset(-10, 10),
        ], true);
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [ink.withValues(alpha: .10), ink.withValues(alpha: 0)],
          ).createShader(path.getBounds()),
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final visible = _visible;
    _clipLayer.layer = context.pushClipRect(
      needsCompositing,
      offset,
      _viewport,
      (context, offset) {
        _floor(context.canvas, offset, visible);
        for (final i in visible) {
          context.paintChild(_boxes[i], offset + _offset(i));
        }
      },
      oldLayer: _clipLayer.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final i in _visible.reversed) {
      if (result.addWithPaintOffset(
        offset: _offset(i),
        position: position,
        hitTest: (result, position) =>
            _boxes[i].hitTest(result, position: position),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _offset(_boxes.indexOf(child));
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  Rect describeApproximatePaintClip(RenderObject child) => _viewport;

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }
}

class _BookVolume extends MultiChildRenderObjectWidget {
  const _BookVolume({
    super.key,
    required this.pose,
    required this.index,
    required this.spine,
    required this.cover,
    required this.height,
    required this.dark,
    required this.label,
    required this.direction,
    required this.onTap,
    required super.children,
  });
  final _WavePose pose;
  final int index;
  final double spine, cover, height;
  final bool dark;
  final String label;
  final TextDirection direction;
  final VoidCallback onTap;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      ArchiveBoxDepthRender._(
        pose,
        index,
        spine,
        cover,
        height,
        dark,
        label,
        direction,
        onTap,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    ArchiveBoxDepthRender renderObject,
  ) => renderObject._update(
    pose,
    index,
    spine,
    cover,
    height,
    dark,
    label,
    direction,
    onTap,
  );
}

class _ArchiveCapHitEntry extends BoxHitTestEntry {
  _ArchiveCapHitEntry(super.target, super.localPosition);
}

/// The top, front and projected side share exactly the same physical vertices.
class ArchiveBoxDepthRender extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ShelfParentData> {
  ArchiveBoxDepthRender._(
    this._pose,
    this._index,
    this._spine,
    this._cover,
    this._height,
    this._dark,
    this._label,
    this._direction,
    this._onTap,
  ) {
    _capTap = TapGestureRecognizer(debugOwner: this)
      ..onTap = () {
        HapticFeedback.selectionClick();
        _onTap();
      };
  }
  _WavePose _pose;
  int _index;
  double _spine, _cover, _height;
  bool _dark;
  String _label;
  TextDirection _direction;
  VoidCallback _onTap;
  late final TapGestureRecognizer _capTap;
  final _spineLayer = LayerHandle<TransformLayer>();
  final _coverLayer = LayerHandle<TransformLayer>();
  int debugLayoutCount = 0;
  double get debugOpenFraction => _pose.weight(_index);
  bool get debugSelected => _pose.focus.round() == _index;
  Matrix4 get debugTransform => _coverTransform.clone();
  Matrix4 get debugSpineTransform => _base.clone();
  double get debugFootprint => _WavePose.footprint(_spine, _cover);
  Offset get _origin {
    return ArchiveShelfGeometry.origin(_cover, _height, debugOpenFraction);
  }

  Matrix4 get _base {
    final origin = _origin;
    return Matrix4.identity()
      ..setEntry(0, 2, _WavePose.depthX)
      ..setEntry(1, 2, _WavePose.depthY)
      ..setEntry(1, 0, .10)
      ..setEntry(0, 3, origin.dx)
      ..setEntry(1, 3, origin.dy);
  }

  Matrix4 get _coverTransform {
    final origin = _origin;
    return Matrix4.identity()
      ..setEntry(0, 0, _WavePose.depthX)
      ..setEntry(1, 0, _WavePose.depthY)
      ..setEntry(0, 3, origin.dx + _spine)
      ..setEntry(1, 3, origin.dy + _spine * .10);
  }

  Path get _topPath {
    final origin = _origin;
    final front = Offset(_spine, _spine * .10);
    final depth = Offset(_cover * _WavePose.depthX, _cover * _WavePose.depthY);
    return Path()..addPolygon([
      origin,
      origin + front,
      origin + front + depth,
      origin + depth,
    ], true);
  }

  Path get _solidPath {
    List<Offset> face(Matrix4 matrix, double width) => [
      for (final point in [
        Offset.zero,
        Offset(width, 0),
        Offset(width, _height),
        Offset(0, _height),
      ])
        MatrixUtils.transformPoint(matrix, point),
    ];
    return Path()
      ..addPath(_topPath, Offset.zero)
      ..addPolygon(face(_base, _spine), true)
      ..addPolygon(face(_coverTransform, _cover), true);
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ShelfParentData) {
      child.parentData = _ShelfParentData();
    }
  }

  void _update(
    _WavePose pose,
    int index,
    double spine,
    double cover,
    double height,
    bool dark,
    String label,
    TextDirection direction,
    VoidCallback onTap,
  ) {
    if (_pose != pose) {
      if (attached) _pose.removeListener(_changed);
      _pose = pose;
      if (attached) _pose.addListener(_changed);
    }
    if (_spine != spine || _cover != cover || _height != height) {
      _spine = spine;
      _cover = cover;
      _height = height;
      markNeedsLayout();
    }
    _index = index;
    _dark = dark;
    _label = label;
    _direction = direction;
    _onTap = onTap;
    _changed();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pose.addListener(_changed);
  }

  @override
  void detach() {
    _pose.removeListener(_changed);
    _spineLayer.layer = null;
    _coverLayer.layer = null;
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    firstChild!.layout(BoxConstraints.tight(Size(_spine, _height)));
    lastChild!.layout(BoxConstraints.tight(Size(_cover, _height)));
    debugLayoutCount++;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _coverLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _coverTransform,
      (context, offset) => context.paintChild(lastChild!, offset),
      oldLayer: _coverLayer.layer,
    );
    final top = _topPath.shift(offset);
    context.canvas.drawPath(
      top,
      Paint()
        ..shader = LinearGradient(
          colors: _dark
              ? [const Color(0xFF41473D), const Color(0xFF2D332C)]
              : [const Color(0xFFE3DFD3), ArchiveDesign.milk],
        ).createShader(top.getBounds()),
    );
    context.canvas.drawPath(
      top,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .4
        ..color = (_dark ? ArchiveDesign.milk : const Color(0xFF9A927F))
            .withValues(alpha: .24),
    );
    _spineLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _base,
      (context, offset) => context.paintChild(firstChild!, offset),
      oldLayer: _spineLayer.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _base,
        position: position,
        hitTest: (result, position) =>
            firstChild!.hitTest(result, position: position),
      ) ||
      result.addWithPaintTransform(
        transform: _coverTransform,
        position: position,
        hitTest: (result, position) =>
            lastChild!.hitTest(result, position: position),
      );
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!paintBounds.contains(position)) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    if (_topPath.contains(position)) {
      result.add(_ArchiveCapHitEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) {
    if (entry is _ArchiveCapHitEntry && event is PointerDownEvent) {
      _capTap.addPointer(event);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(child == firstChild ? _base : _coverTransform);
  @override
  Rect get paintBounds => semanticBounds.inflate(.5);
  @override
  Rect get semanticBounds {
    // Exact projected solid bounds without allocating matrices/paths for every
    // offscreen volume during each culling pass.
    final origin = _origin;
    return Rect.fromLTRB(
      origin.dx,
      origin.dy + _cover * _WavePose.depthY,
      origin.dx + debugFootprint,
      origin.dy + _height + _spine * .10,
    );
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.isButton = true;
    config.isSelected = debugSelected;
    config.label = _label;
    config.textDirection = _direction;
    config.onTap = _onTap;
    config.hint = debugSelected ? '中心档案，点按打开书籍' : '点按滚动到中心';
  }

  @override
  void dispose() {
    _capTap.dispose();
    _spineLayer.layer = null;
    _coverLayer.layer = null;
    super.dispose();
  }
}
