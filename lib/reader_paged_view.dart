import 'dart:async';
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'library_state.dart';
import 'reader_book_layout.dart';
import 'reader_content.dart';
import 'reader_pagination.dart';
import 'reader_preferences.dart';
import 'reader_reflow.dart';
import 'reader_turn_motion.dart';
import 'reader_illustrations.dart';
import 'reader_page_anchor.dart';
import 'reader_page_physics.dart';
import 'reader_sheet_motion.dart';
import 'reader_spine_turn.dart';
import 'reader_status.dart';
import 'reader_scroll_location.dart';
import 'reader_chrome.dart';

TextStyle _chapterHeadingStyle(TextStyle style) => style.copyWith(
  fontSize: 13,
  height: 1.4,
  color: style.color?.withValues(alpha: .6),
);

List<String> _localImagePriority(ReaderContent content, int? paragraph) {
  final local = content.illustrations.where(
    (url) => url.startsWith('wenku-local:'),
  );
  if (paragraph == null || paragraph <= 0) return local.take(4).toList();
  if (local.isEmpty) return const [];
  final order = content.readingOrder;
  final count = order?.length ?? content.paragraphs.length;
  final center = order?.indexOf(paragraph) ?? paragraph;
  if (center < 0 || center >= count) return local.take(4).toList();
  final result = <String>{};
  void add(int index) {
    if (index < 0 || index >= count) return;
    final url = readerIllustrationUrl(
      content.paragraphs[order?[index] ?? index],
    );
    if (url != null && url.startsWith('wenku-local:')) result.add(url);
  }

  for (
    var distance = 0;
    result.length < 4 && (center + distance < count || center - distance >= 0);
    distance++
  ) {
    add(center + distance);
    if (distance > 0 && result.length < 4) add(center - distance);
  }
  return result.toList(growable: false);
}

Offset _bodyOrigin(
  BuildContext context,
  String title,
  TextStyle style,
  EdgeInsets padding,
  double width,
) {
  final painter = TextPainter(
    text: TextSpan(text: title, style: _chapterHeadingStyle(style)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: width);
  final origin = Offset(padding.left, padding.top + painter.height + 8);
  painter.dispose();
  return origin;
}

class ReaderPagedController {
  _ReaderPagedViewState? _owner;
  bool get ready =>
      _owner?._pagination != null &&
      _owner?._layingOut == false &&
      _owner?._chapterOutgoing == null &&
      _owner?._boundaryLanding == null;
  ReaderTextAnchor? get anchor =>
      _owner?._readingAnchor ?? _owner?._firstVisibleAnchor;
  double get fraction {
    final owner = _owner, count = owner?._spreadCount ?? 0;
    return count < 2 ? 0 : owner!._spreadFor(owner._page) / (count - 1);
  }

  int get page => _owner?._page ?? 0;
  int get pageCount => _owner?._pagination?.pages.length ?? 0;
  Size? get pageSize => _owner?._pagination?.size;
  int get pagesPerSpread => _owner?._bookLayout?.count ?? 1;
  List<int> get visiblePages => _owner?._visiblePages ?? const [];
  @visibleForTesting
  int get debugLayoutGeneration => _owner?._generation ?? 0;
  @visibleForTesting
  int get debugParagraphMeasurements =>
      _owner?._textLayout.paragraphMeasurements ?? 0;
  @visibleForTesting
  int get debugPageBodyBuilds => _owner?._pageBodyBuilds ?? 0;
  @visibleForTesting
  int get debugAdjacentLayoutStarts => _owner?._adjacentLayoutStarts ?? 0;
  @visibleForTesting
  bool adjacentReady(int direction) =>
      _owner?._adjacentLayouts.containsKey(direction.sign) ?? false;
  @visibleForTesting
  ReaderLeaf? get debugLeaf => _owner?._leaf;
  @visibleForTesting
  ReaderPagination? get debugPagination => _owner?._pagination;
  @visibleForTesting
  ReaderBookLayout? get debugBookLayout => _owner?._bookLayout;
  @visibleForTesting
  ReaderTextAnchor? get debugFirstVisibleAnchor {
    final owner = _owner;
    if (owner == null || owner._visiblePages.isEmpty) return null;
    return owner._firstVisibleAnchor;
  }

  bool pageBy(int direction) {
    final owner = _owner;
    if (owner == null || !ready) return false;
    final spread = owner._spreadFor(owner._target) + direction;
    if (spread < 0 || spread >= owner._spreadCount) {
      return owner._moveBoundary(direction);
    }
    final target = (spread * pagesPerSpread - owner._leadingPages).clamp(
      0,
      pageCount - 1,
    );
    owner._pendingPosition = null;
    owner._pendingFraction = null;
    owner._move(target, animate: true);
    return true;
  }

  void seek(double fraction) {
    if (!ready) return;
    final owner = _owner!;
    owner._pendingPosition = null;
    owner._pendingFraction = fraction.clamp(0, 1);
    owner._move(
      owner._pendingFraction == 1
          ? pageCount - 1
          : (owner._pendingFraction! * (owner._spreadCount - 1)).round() *
                    pagesPerSpread -
                owner._leadingPages,
    );
    // Keep the requested fraction through any coalesced viewport reflow.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (owner.mounted && !owner._layingOut) owner._pendingFraction = null;
    });
  }

  void restore(ReadingPosition position) => _owner?._restore(position);

  /// Includes the destination of an in-flight programmatic turn. Audio ticks
  /// must not restart that same turn before it reaches the next spread.
  bool isRevealed(ReaderTextAnchor anchor) {
    final owner = _owner;
    if (!ready || owner == null) return false;
    final destination = owner._programmaticTurn ? owner._target : owner._page;
    return owner._spreadFor(owner._pagination!.pageFor(anchor)) ==
        owner._spreadFor(destination);
  }

  void reveal(ReaderTextAnchor anchor) {
    final owner = _owner;
    if (owner?._pagination != null) {
      owner!._pendingFraction = null;
      owner._pendingPosition = null;
      owner._move(
        owner._pagination!.pageFor(anchor),
        animate: true,
        anchor: anchor,
      );
    }
  }
}

/// Fully prepared prose for the preceding/following chapter. It is paginated
/// ahead of time and joins the current PageView, rather than starting another
/// animation after the user's edge gesture has finished.
class ReaderPagedChapter {
  const ReaderPagedChapter({
    required this.key,
    required this.content,
    required this.title,
    required this.pageBuilder,
    this.pageBuilderKey,
    this.titleForAnchor,
  });
  final Object key;
  final ReaderContent content;
  final String title;
  final Widget Function(ReaderLeaf page) pageBuilder;
  final Object? pageBuilderKey;
  final String Function(ReaderTextAnchor)? titleForAnchor;
}

class _AdjacentLayout {
  _AdjacentLayout(
    this.chapter,
    this.key,
    this.pagination,
    this.bookLayout,
    this.padding,
    this.headingExtent,
  );
  ReaderPagedChapter chapter;
  final Object key;
  final ReaderPagination pagination;
  final ReaderBookLayout bookLayout;
  final EdgeInsets padding;
  final double headingExtent;
  final bodies = <int, Widget>{};
}

class ReaderPageSkeleton extends StatelessWidget {
  const ReaderPageSkeleton({
    super.key,
    required this.title,
    required this.padding,
    required this.style,
    required this.vertical,
    this.margin = 26,
  });
  final String title;
  final EdgeInsets padding;
  final TextStyle style;
  final bool vertical;
  final double margin;
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _chapterHeadingStyle(style),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = ReaderBookLayout.resolve(
                viewport: constraints.biggest,
                margin: margin,
                features: MediaQuery.displayFeaturesOf(context),
                origin: _bodyOrigin(
                  context,
                  title,
                  style,
                  padding,
                  constraints.maxWidth,
                ),
              );
              return ReaderBookSpread(
                layout: layout,
                rightToLeft: vertical,
                pages: [
                  for (var i = 0; i < layout.count; i++)
                    ReaderSkeleton(vertical: vertical, expand: true),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class ReaderPagedView extends StatefulWidget {
  const ReaderPagedView({
    super.key,
    required this.content,
    required this.preferences,
    required this.style,
    required this.controller,
    required this.title,
    required this.padding,
    required this.pageBuilder,
    required this.onReady,
    required this.onChanged,
    required this.onUserScroll,
    required this.onBoundary,
    this.position,
    this.reduceMotion = false,
    this.showPageCount = true,
    this.preservePositionStart = false,
    this.pageBuilderKey,
    this.status,
    this.titleForAnchor,
    this.backgroundBuilder,
    this.chapterKey,
    this.chapterTurnDirection = 0,
    this.previousChapter,
    this.nextChapter,
    this.onChapterTurned,
    this.bookTitle,
    this.chrome,
  });
  final ReaderContent content;
  final ReaderPreferences preferences;
  final TextStyle style;
  final ReaderPagedController controller;
  final String title;
  final String? bookTitle;
  final Animation<double>? chrome;
  final EdgeInsets padding;
  final Widget Function(ReaderLeaf page) pageBuilder;
  final Object? pageBuilderKey;
  final Object? chapterKey;

  /// A deliberate boundary turn: +1 to the next chapter, -1 to the previous.
  /// Opening a catalogue/bookmark target leaves this at zero.
  final int chapterTurnDirection;
  final ReaderPagedChapter? previousChapter, nextChapter;

  /// The adjacent sheet has settled on screen. Adopt it without replaying the
  /// completed turn; onBoundary remains the request path for an unready edge.
  final ValueChanged<int>? onChapterTurned;

  /// Reader-owned status is part of the turning sheet, not pinned chrome.
  final Widget? status;
  final String Function(ReaderTextAnchor)? titleForAnchor;
  final Widget Function(Widget child)? backgroundBuilder;
  final VoidCallback onReady, onChanged, onUserScroll;
  final ValueChanged<int> onBoundary;
  final ReadingPosition? position;
  final bool reduceMotion;
  final bool showPageCount;

  /// Explicit typography-scope changes keep the current reading line at top.
  final bool preservePositionStart;
  @override
  State<ReaderPagedView> createState() => _ReaderPagedViewState();
}

class _ReaderPagedViewState extends State<ReaderPagedView>
    with TickerProviderStateMixin {
  late final _turn =
      AnimationController(
        vsync: this,
        duration: ReaderTurnScope.duration,
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed &&
            mounted &&
            _chapterOutgoing != null) {
          setState(() => _chapterOutgoing = null);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.onReady();
              widget.onChanged();
            }
          });
        }
      });
  bool _programmaticTurn = false;
  bool _swipeFeedbackSent = false;
  bool _swipeCancelled = false;
  int? _turnSpread, _swipeOrigin;
  double _turnDirection = 1;
  Widget? _chapterOutgoing;
  double _chapterTurnDirection = 1;
  bool _chapterTurnForward = true;
  int? _boundaryLanding;
  _AdjacentLayout? _landingLayout;
  bool _adjacentPreparationQueued = false;
  Size? _adjacentFrame;
  TextScaler? _adjacentScaler;
  int _adjacentLayoutStarts = 0;
  int get _edgeSlots => widget.onChapterTurned == null ? 0 : 1;
  int get _restingSpread => _boundaryLanding == null
      ? _spreadFor(_page)
      : _boundaryLanding! < 0
      ? -1
      : _spreadCount;
  final _adjacentLayouts = <int, _AdjacentLayout>{};
  final _adjacentRequests = <int, Object>{};
  late final _paperClock = ReaderPaperClock(_turn);
  late final _arrival =
      AnimationController(vsync: this, duration: NovelMotion.enter, value: 1)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed &&
              mounted &&
              (_previousPage != null ||
                  _previousSize != null ||
                  _initialArrival)) {
            setState(() {
              _previousPage = null;
              _previousSize = null;
              _previousLeaves = const [];
              _previousLeafSize = null;
              _initialArrival = false;
              _modeReconfiguration = false;
            });
          }
        });
  Widget? _previousPage;
  Size? _previousSize;
  Size? _previousLeafSize;
  List<ReaderLeaf> _previousLeaves = const [];
  ReaderBookLayout? _bookLayout;
  bool _bookReconfiguration = false;
  bool _modeReconfiguration = false;
  double _modeDirection = 1;
  ReaderMode? _publishedMode;
  Offset _originDelta = Offset.zero;
  EdgeInsets? _publishedPadding;
  double? _publishedHeadingExtent;
  late TextStyle _layoutStyle;
  bool _initialArrival = false;
  ReaderPagination? _pagination;
  ReaderContent? _publishedContent;
  Object? _publishedChapterKey;
  String? _publishedTitle;
  String Function(ReaderTextAnchor)? _publishedTitleForAnchor;
  PageController? _pager;
  Object? _layoutKey;
  ReadingPosition? _pendingPosition;
  // Reflow maps the reading coordinate into a page, never the other way round.
  // Taking each newly displayed page's first character as the next coordinate
  // quantizes the position backwards on every change of viewport.
  ReaderTextAnchor? _readingAnchor;
  // Only an explicit typography-scope request may introduce a page break.
  // It is a fixed layout input, not a new break at every visible page start.
  ReaderTextAnchor? _pageBreakAnchor;
  double? _pendingFraction;
  int _generation = 0, _page = 0, _target = 0;
  int _leadingPages = 0;
  double _overscroll = 0;
  bool _crossedBoundary = false;
  bool _layoutFailed = false;
  bool _layingOut = false;
  final _pageBodies = <int, Widget>{};
  int _pageBodyBuilds = 0;
  final _textLayout = ReaderTextLayoutCache();
  // Pagination is canonical for its content, geometry and typography inputs.
  // This bounded cache saves work; evicting it must not change page boundaries.
  final _layouts =
      <Object, ({ReaderPagination pagination, int leadingPages})>{};
  ReaderLeaf? get _leaf => _pagination?.pages[_page];
  bool get _motionEnabled =>
      !widget.reduceMotion && !MediaQuery.disableAnimationsOf(context);
  ReaderPageEffect get _effect =>
      _motionEnabled ? widget.preferences.pageEffect : ReaderPageEffect.none;
  EdgeInsets get _pageInsets => EdgeInsets.only(
    left: (_publishedPadding ?? widget.padding).left,
    right: (_publishedPadding ?? widget.padding).right,
  );
  Size get _frameSize => Size(
    _bookLayout!.viewport.width + _pageInsets.horizontal,
    _bookLayout!.viewport.height +
        (_publishedPadding ?? widget.padding).vertical +
        (_publishedHeadingExtent ?? _headingExtent),
  );
  double get _headingExtent => _headingExtentFor(widget.title);
  double _headingExtentFor(String title) {
    if (widget.bookTitle != null) return 0;
    final painter = TextPainter(
      text: TextSpan(text: title, style: _chapterHeadingStyle(widget.style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height + 8;
    painter.dispose();
    return height;
  }

  ReaderBookLayout _layoutFor(Size frame, String title) =>
      ReaderBookLayout.resolve(
        viewport: Size(
          (frame.width - widget.padding.horizontal).clamp(1, double.infinity),
          (frame.height - widget.padding.vertical - _headingExtentFor(title))
              .clamp(1, double.infinity),
        ),
        margin: widget.preferences.bindingMargin,
        features: MediaQuery.displayFeaturesOf(context),
        origin: widget.bookTitle != null
            ? Offset(widget.padding.left, widget.padding.top)
            : _bodyOrigin(
                context,
                title,
                widget.style,
                widget.padding,
                (frame.width - widget.padding.horizontal).clamp(
                  1,
                  double.infinity,
                ),
              ),
      );

  int get _perSpread => _bookLayout?.count ?? 1;
  double get _reflowOverflow =>
      _previousSize == null || _bookReconfiguration || _modeReconfiguration
      ? 0
      : ((_previousLeafSize?.height ?? 0) - (_pagination?.size.height ?? 0))
                .clamp(0.0, double.infinity) +
            _originDelta.dy.abs();
  int get _spreadCount =>
      (((_pagination?.pages.length ?? 0) + _leadingPages) / _perSpread).ceil();
  int _spreadFor(int page) => (page + _leadingPages) ~/ _perSpread;
  List<int> get _visiblePages {
    final first = _spreadFor(_page) * _perSpread - _leadingPages;
    return [
      for (var i = first; i < first + _perSpread; i++)
        if (i >= 0 && i < (_pagination?.pages.length ?? 0)) i,
    ];
  }

  ReaderTextAnchor? get _firstVisibleAnchor => _visiblePages.isEmpty
      ? null
      : _pagination!.pages[_visiblePages.first].anchor;

  @override
  void initState() {
    super.initState();
    widget.controller._owner = this;
    _layoutStyle = widget.style;
    _pendingPosition = widget.position;
    if (widget.preservePositionStart) {
      _pageBreakAnchor = _anchorFor(widget.position);
    }
  }

  @override
  void didUpdateWidget(ReaderPagedView old) {
    super.didUpdateWidget(old);
    if (old.preferences.chapterEntrance &&
        !widget.preferences.chapterEntrance &&
        _initialArrival) {
      _initialArrival = false;
      _arrival.value = 1;
    }
    final styleLayout =
        old.style.compareTo(widget.style) == RenderComparison.layout;
    if (styleLayout) _layoutStyle = widget.style;
    final contentChanged =
        !identical(old.content, widget.content) ||
        old.chapterKey != widget.chapterKey;
    final reflow =
        styleLayout ||
        old.preferences.layoutKey != widget.preferences.layoutKey ||
        old.padding != widget.padding ||
        contentChanged;
    if ((old.pageBuilderKey != widget.pageBuilderKey ||
            widget.pageBuilderKey == null &&
                old.pageBuilder != widget.pageBuilder ||
            old.style != widget.style) &&
        !reflow) {
      _pageBodies.clear();
    }
    if (old.controller != widget.controller) {
      old.controller._owner = null;
      widget.controller._owner = this;
    }
    for (final direction in [-1, 1]) {
      final ready = _adjacentLayouts[direction];
      final chapter = direction < 0
          ? widget.previousChapter
          : widget.nextChapter;
      if (ready != null &&
          chapter != null &&
          ready.chapter.key == chapter.key &&
          identical(ready.chapter.content, chapter.content)) {
        if (ready.chapter.pageBuilderKey != chapter.pageBuilderKey) {
          ready.bodies.clear();
        }
        ready.chapter = chapter;
      }
    }
    if (contentChanged) {
      _readingAnchor = null;
      _layingOut = true;
      _pendingPosition = widget.position;
      _pageBreakAnchor = widget.preservePositionStart
          ? _anchorFor(widget.position)
          : null;
    } else {
      // Naming/TOC metadata can be corrected without changing any line breaks.
      _publishedTitle = widget.title;
      _publishedTitleForAnchor = widget.titleForAnchor;
      if (styleLayout ||
          old.preferences.layoutKey != widget.preferences.layoutKey) {
        _pageBreakAnchor = null;
      }
      if (!identical(old.position, widget.position) &&
          widget.position != null) {
        if (widget.preservePositionStart) {
          _pageBreakAnchor = _anchorFor(widget.position);
        }
        _restore(widget.position!);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    if (widget.controller._owner == this) widget.controller._owner = null;
    _pager?.dispose();
    _arrival.dispose();
    _paperClock.dispose();
    _turn.dispose();
    super.dispose();
  }

  ReaderTextAnchor? _anchorFor(ReadingPosition? position) {
    if (position == null || position.paragraphIndex == null) return null;
    final paragraph = position.paragraphIndex!;
    if (paragraph < 0 || paragraph >= widget.content.paragraphs.length) {
      return null;
    }
    final text = widget.content.paragraphs[paragraph];
    return ReaderTextAnchor(
      paragraph,
      (position.textOffset ??
              (position.paragraphFraction * text.length).round())
          .clamp(0, text.length),
    );
  }

  void _restore(ReadingPosition position) {
    _pendingFraction = null;
    _pendingPosition = position;
    final layout = _pagination;
    if (layout == null) return;
    final anchor = _anchorFor(position);
    _move(
      anchor == null
          ? position.fraction == 1
                ? layout.pages.length - 1
                : (position.fraction * (_spreadCount - 1)).round() *
                          _perSpread -
                      _leadingPages
          : layout.pageFor(anchor),
      anchor: anchor,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady();
    });
  }

  ReaderTextAnchor? _anchorForPage(int page) {
    final pagination = _pagination;
    if (pagination == null) return null;
    final first = (_spreadFor(page) * _perSpread - _leadingPages).clamp(
      0,
      pagination.pages.length - 1,
    );
    return pagination.pages[first].anchor;
  }

  void _move(int page, {bool animate = false, ReaderTextAnchor? anchor}) {
    final pager = _pager;
    if (_pagination == null || pager == null) return;
    final previousPage = _page;
    _target = page.clamp(0, _pagination!.pages.length - 1);
    _readingAnchor = anchor ?? _anchorForPage(_target);
    if (!pager.hasClients) return;
    final destination = _spreadFor(_target);
    final current = pager.page == null
        ? _spreadFor(previousPage).toDouble()
        : pager.page! - _edgeSlots;
    if ((destination - current).abs() < .00001) {
      if (!animate) {
        _programmaticTurn = false;
        _turn.stop();
        _turn.value = 1;
      }
      setState(() {
        _page = _target;
        if (!animate) {
          _turnSpread = null;
          _swipeOrigin = null;
        }
      });
      widget.onChanged();
      return;
    }
    if (animate && _effect != ReaderPageEffect.none) {
      _animateSpread(destination);
    } else {
      _programmaticTurn = false;
      _turn.stop();
      _swipeOrigin = null;
      _turn.value = 1;
      setState(() {
        _turnSpread = null;
      });
      pager.jumpToPage(destination + _edgeSlots);
    }
  }

  void _animateSpread(int spread) {
    final pager = _pager!;
    final current = (pager.page ?? 0) - _edgeSlots;
    setState(() {
      _swipeOrigin ??= current.round();
      _programmaticTurn = true;
    });
    unawaited(
      pager.animateToPage(
        spread + _edgeSlots,
        duration: widget.preferences.pageSpeed.durationFor(_effect),
        curve: Curves.linear,
      ),
    );
  }

  bool _moveBoundary(int direction) {
    if (widget.onChapterTurned == null ||
        !_adjacentLayouts.containsKey(direction.sign) ||
        _pager?.hasClients != true) {
      return false;
    }
    final spread = direction < 0 ? -1 : _spreadCount;
    if (_effect == ReaderPageEffect.none) {
      _pager!.jumpToPage(spread + _edgeSlots);
      _finishBoundary(direction.sign);
    } else {
      _animateSpread(spread);
    }
    return true;
  }

  void _acknowledgePageCommit(int page) {
    final origin = _swipeOrigin;
    if (!mounted ||
        origin == null ||
        _programmaticTurn ||
        _swipeFeedbackSent ||
        _swipeCancelled ||
        page - _edgeSlots == origin) {
      return;
    }
    // Acknowledge the accepted release, not the spring's final settling frame.
    // Re-evaluated ballistics and the later ScrollEnd must never replay it.
    _swipeFeedbackSent = true;
    AppHaptics.play(context, HapticCue.pageTurn);
  }

  void _finishBoundary(int direction) {
    if (_boundaryLanding != null) return;
    final landed = _adjacentLayouts[direction];
    if (landed == null) return;
    setState(() {
      _landingLayout = landed;
      _boundaryLanding = direction;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _boundaryLanding == direction &&
          identical(_landingLayout, landed)) {
        widget.onChapterTurned?.call(direction);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Object _paginationKey(
    Object? chapter,
    ReaderContent content,
    ReaderBookLayout layout,
    TextScaler scaler,
    ReaderTextAnchor? pageBreak,
  ) => (
    chapter,
    content,
    layout.key,
    _layoutStyle,
    widget.preferences.layoutKey,
    scaler.scale(widget.style.fontSize ?? 19),
    (pageBreak?.paragraph, pageBreak?.offset),
  );

  void _rememberLayout(
    Object key,
    ReaderPagination pagination,
    int leadingPages,
  ) {
    _layouts.remove(key);
    _layouts[key] = (pagination: pagination, leadingPages: leadingPages);
    // Current and neighbouring chapters may reuse the open/closed controls
    // geometries. One bounded cache serves both paths; no three full reflows.
    while (_layouts.length > 6) {
      _layouts.remove(_layouts.keys.first);
    }
  }

  void _scheduleAdjacent(Size frame, TextScaler scaler) {
    _adjacentFrame = frame;
    _adjacentScaler = scaler;
    if (_adjacentPreparationQueued) return;
    _adjacentPreparationQueued = true;
    void afterFrame(Duration _) {
      if (!mounted) return;
      if (_layingOut || _boundaryLanding != null || _swipeOrigin != null) {
        WidgetsBinding.instance.addPostFrameCallback(afterFrame);
        return;
      }
      final needsLayout = _prepareAdjacent(
        _adjacentFrame!,
        _adjacentScaler!,
        allowLayout: !_arrival.isAnimating,
      );
      if (needsLayout) {
        // Borrow the active reflow's frames; never start a timer/ticker just to
        // prepaginate an offscreen chapter while the reader is moving.
        WidgetsBinding.instance.addPostFrameCallback(afterFrame);
      } else {
        _adjacentPreparationQueued = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(afterFrame);
  }

  bool _prepareAdjacent(
    Size frame,
    TextScaler scaler, {
    required bool allowLayout,
  }) {
    var deferred = false, changed = false;
    for (final direction in [-1, 1]) {
      final chapter = direction < 0
          ? widget.previousChapter
          : widget.nextChapter;
      if (chapter == null || widget.onChapterTurned == null) {
        _adjacentRequests.remove(direction);
        changed = _adjacentLayouts.remove(direction) != null || changed;
        continue;
      }
      final heading = _headingExtentFor(chapter.title);
      final layout = _layoutFor(frame, chapter.title);
      final key = _paginationKey(
        chapter.key,
        chapter.content,
        layout,
        scaler,
        null,
      );
      final ready = _adjacentLayouts[direction];
      if (ready?.key == key) {
        if (ready!.chapter.pageBuilderKey != chapter.pageBuilderKey) {
          ready.bodies.clear();
        }
        ready.chapter = chapter;
        continue;
      }
      if (_adjacentRequests[direction] == key) continue;
      final cached = _layouts[key];
      if (cached != null) {
        _adjacentRequests[direction] = key;
        _adjacentLayouts[direction] = _AdjacentLayout(
          chapter,
          key,
          cached.pagination,
          layout,
          widget.padding,
          heading,
        );
        changed = true;
        continue;
      }
      if (!allowLayout) {
        deferred = true;
        continue;
      }
      _adjacentRequests[direction] = key;
      changed = _adjacentLayouts.remove(direction) != null || changed;
      _adjacentLayoutStarts++;
      final padding = widget.padding,
          style = _layoutStyle,
          prefs = widget.preferences;
      unawaited(() async {
        bool current() => mounted && _adjacentRequests[direction] == key;
        try {
          final images = await ReaderIllustrationCache.shared
              .measureLocalImages(
                chapter.content.illustrations,
                current: current,
                prioritize: direction < 0
                    ? chapter.content.illustrations.reversed.take(4)
                    : const [],
              );
          if (!current()) return;
          final pages = await paginateReader(
            content: chapter.content,
            size: layout.pageSize,
            style: style,
            preferences: prefs,
            scaler: scaler,
            current: current,
            localImageSizes: images,
          );
          if (!current() || pages == null) return;
          _rememberLayout(key, pages, 0);
          setState(
            () => _adjacentLayouts[direction] = _AdjacentLayout(
              chapter,
              key,
              pages,
              layout,
              padding,
              heading,
            ),
          );
        } catch (_) {
          // The normal request/retry path remains available at an unready edge.
        }
      }());
    }
    if (changed) setState(() {});
    return deferred;
  }

  void _scrubTurn(PageMetrics metrics) {
    final origin = _swipeOrigin;
    final position = metrics.page == null ? null : metrics.page! - _edgeSlots;
    if (origin == null ||
        position == null ||
        _effect == ReaderPageEffect.none) {
      return;
    }
    final delta = position - origin;
    if (delta.abs() < .00001) {
      _turn.value = 0;
      return;
    }
    final forward = delta > 0;
    final incoming = (forward ? position.ceil() : position.floor()).clamp(
      _adjacentLayouts.containsKey(-1) ? -1 : 0,
      _spreadCount - 1 + (_adjacentLayouts.containsKey(1) ? 1 : 0),
    );
    final progress = forward
        ? position - incoming + 1
        : incoming + 1 - position;
    final direction =
        (forward ? 1.0 : -1.0) *
        (widget.preferences.mode == ReaderMode.vertical ? -1 : 1);
    if (_turnSpread != incoming || _turnDirection != direction) {
      setState(() {
        _turnSpread = incoming;
        _turnDirection = direction;
      });
    }
    _turn.value = progress.clamp(0.0, 1.0);
  }

  Future<void> _layout(
    ReaderBookLayout bookLayout,
    TextScaler scaler,
    Object key,
  ) async {
    final size = bookLayout.pageSize;
    final ticket = ++_generation;
    final content = widget.content;
    final preferences = widget.preferences;
    final padding = widget.padding;
    final landed = _landingLayout;
    final reuseLanded =
        landed != null &&
        identical(landed.chapter.content, content) &&
        landed.bookLayout.key == bookLayout.key &&
        _pageBreakAnchor == null;
    final chapterChanged =
        _publishedContent != null &&
        (widget.chapterKey == null
            ? !identical(_publishedContent, content)
            : _publishedChapterKey != widget.chapterKey);
    final oldAnchor = chapterChanged
        ? null
        : _readingAnchor ?? _firstVisibleAnchor;
    final pageBreak = _pageBreakAnchor;
    final retained = _layouts[key];
    // Keep the last fully laid-out page while a slider previews the next
    // typography. Replacing it with skeletons on every drag tick flickers and
    // hides the very text the transparent settings panel is meant to preview.
    _layingOut = true;
    _layoutFailed = false;
    ReaderPagination? result;
    try {
      if (retained != null || reuseLanded) {
        // _layout starts inside LayoutBuilder; publish outside its build even
        // when no image measurement or pagination work is necessary.
        await Future<void>.value();
        result = retained?.pagination ?? landed!.pagination;
      } else {
        final imageSizes = await ReaderIllustrationCache.shared
            .measureLocalImages(
              content.illustrations,
              current: () => mounted && ticket == _generation,
              prioritize: _localImagePriority(
                content,
                (_anchorFor(_pendingPosition) ?? _readingAnchor ?? oldAnchor)
                    ?.paragraph,
              ),
              retainPriority: true,
            );
        if (!mounted || ticket != _generation) return;
        result = await paginateReader(
          content: content,
          size: size,
          style: _layoutStyle,
          preferences: preferences,
          scaler: scaler,
          current: () => mounted && ticket == _generation,
          pageBreak: pageBreak,
          cache: _textLayout,
          localImageSizes: imageSizes,
        );
      }
    } catch (_) {
      if (mounted && ticket == _generation) {
        setState(() {
          _layoutFailed = true;
          _layingOut = false;
        });
      }
      return;
    }
    if (!mounted || ticket != _generation || result == null) return;
    final position = _pendingPosition;
    final anchor = _anchorFor(position) ?? _readingAnchor ?? oldAnchor;
    final anchorPage = anchor == null ? null : result.pageFor(anchor);
    // An explicit scope landing starts on the first leaf of a spread. Ordinary
    // viewport changes never shift the book's global start or page boundaries.
    final originPage = pageBreak == null ? null : result.pageFor(pageBreak);
    final leadingPages =
        retained?.leadingPages ??
        (originPage != null
            ? (bookLayout.count - originPage % bookLayout.count) %
                  bookLayout.count
            : 0);
    final spreadCount =
        ((result.pages.length + leadingPages) / bookLayout.count).ceil();
    final page =
        (_pendingFraction != null
                ? _pendingFraction == 1
                      ? result.pages.length - 1
                      : (_pendingFraction! * (spreadCount - 1)).round() *
                                bookLayout.count -
                            leadingPages
                : anchor != null
                ? anchorPage!
                : position?.fraction == 1
                ? result.pages.length - 1
                : ((position?.fraction ?? 0) * (spreadCount - 1)).round() *
                          bookLayout.count -
                      leadingPages)
            .clamp(0, result.pages.length - 1);
    final first =
        ((page + leadingPages) ~/ bookLayout.count * bookLayout.count -
                leadingPages)
            .clamp(0, result.pages.length - 1);
    final readingAnchor = _pendingFraction == null && anchor != null
        ? anchor
        : result.pages[first].anchor;
    final oldPager = _pager;
    final firstLayout = _pagination == null;
    // Reflow only relates two layouts of the same chapter. Its fragment
    // identities are chapter-local and must never carry ink into another one.
    final viewportChanged =
        !chapterChanged &&
        _pagination != null &&
        _bookLayout?.key != bookLayout.key;
    final modeChanged =
        !chapterChanged &&
        _publishedMode != null &&
        _publishedMode != preferences.mode;
    final bookReconfiguration =
        viewportChanged &&
        (_bookLayout?.count != bookLayout.count ||
            _pagination?.size.width != result.size.width);
    final animate =
        !widget.reduceMotion && !MediaQuery.disableAnimationsOf(context);
    final boundaryTurn =
        chapterChanged && (widget.chapterTurnDirection != 0 || reuseLanded);
    final animateBoundary =
        boundaryTurn &&
        !reuseLanded &&
        animate &&
        _effect != ReaderPageEffect.none;
    final chapterArrival =
        (firstLayout || chapterChanged) &&
        preferences.chapterEntrance &&
        !boundaryTurn;
    final boundaryDirection =
        widget.chapterTurnDirection.sign.toDouble() *
        (preferences.mode == ReaderMode.vertical ? -1 : 1);
    final chapterOutgoing = animateBoundary
        ? _spreadBody(
            _spreadFor(_page),
            reflow: false,
            chapterOutgoing: true,
            chapterDirection: boundaryDirection,
          )
        : null;
    final modeDirection = (_publishedMode?.index ?? 0) < preferences.mode.index
        ? 1.0
        : -1.0;
    Widget? previous = animate && (bookReconfiguration || modeChanged)
        ? _spreadBody(
            _spreadFor(_page),
            reflow: false,
            turn: false,
            mode: _publishedMode,
          )
        : null;
    if (previous != null && modeChanged) {
      previous = ReaderTurnScope(
        animation: _arrival,
        direction: modeDirection,
        outgoing: true,
        child: previous,
      );
    }
    final previousSize = _bookLayout == null ? null : _frameSize;
    final previousLeafSize = _pagination?.size;
    final previousLeaves = [
      for (final i in _visiblePages) _pagination!.pages[i],
    ];
    final previousPadding = _publishedPadding ?? padding;
    _turn.stop();
    _swipeOrigin = null;
    _programmaticTurn = false;
    _rememberLayout(key, result, leadingPages);
    setState(() {
      _turnSpread = null;
      _pagination = result;
      _chapterOutgoing = chapterOutgoing;
      _boundaryLanding = null;
      _landingLayout = null;
      if (chapterChanged || viewportChanged || modeChanged) {
        _adjacentLayouts.clear();
        _adjacentRequests.clear();
      }
      _chapterTurnDirection = boundaryDirection;
      _chapterTurnForward = widget.chapterTurnDirection > 0;
      _publishedContent = content;
      _publishedChapterKey = widget.chapterKey;
      _publishedTitle = widget.title;
      _publishedTitleForAnchor = widget.titleForAnchor;
      _previousPage = previous;
      _previousSize = animate && viewportChanged ? previousSize : null;
      _previousLeafSize = animate && viewportChanged ? previousLeafSize : null;
      _previousLeaves = animate && viewportChanged ? previousLeaves : const [];
      _bookReconfiguration = bookReconfiguration;
      _modeReconfiguration = modeChanged && animate;
      _modeDirection = modeDirection;
      _bookLayout = bookLayout;
      _leadingPages = leadingPages;
      _originDelta = Offset(0, previousPadding.top - padding.top);
      _publishedPadding = padding;
      _publishedHeadingExtent = _headingExtent;
      _publishedMode = preferences.mode;
      _initialArrival = chapterArrival && animate;
      _layingOut = false;
      _pageBodies.clear();
      if (reuseLanded) _pageBodies.addAll(landed.bodies);
      _page = _target = page;
      _pager = PageController(initialPage: _spreadFor(page) + _edgeSlots);
      _readingAnchor = readingAnchor;
      _pendingPosition = null;
      _pendingFraction = null;
    });
    if (animateBoundary) {
      _turn.duration = preferences.pageSpeed.durationFor(_effect);
      _turn.forward(from: 0);
    } else {
      _turn.value = 1;
    }
    if ((chapterArrival || viewportChanged || modeChanged) && animate) {
      _arrival.forward(from: 0);
    } else {
      _arrival.value = 1;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldPager?.dispose();
      if (mounted && ticket == _generation) {
        widget.onReady();
        widget.onChanged();
      }
    });
  }

  Widget _spreadBody(
    int spread, {
    bool reflow = true,
    bool turn = true,
    ReaderMode? mode,
    bool? chapterOutgoing,
    double? chapterDirection,
  }) {
    final adjacent =
        _boundaryLanding != null &&
            (spread < 0
                    ? -1
                    : spread >= _spreadCount
                    ? 1
                    : 0) ==
                _boundaryLanding
        ? _landingLayout
        : spread < 0
        ? _adjacentLayouts[-1]
        : spread >= _spreadCount
        ? _adjacentLayouts[1]
        : null;
    if ((spread < 0 || spread >= _spreadCount) && adjacent == null) {
      return const SizedBox.expand();
    }
    final pagination = adjacent?.pagination ?? _pagination!;
    final layout = adjacent?.bookLayout ?? _bookLayout!;
    final localSpread = adjacent == null
        ? spread
        : spread < 0
        ? (pagination.pages.length / layout.count).ceil() - 1
        : 0;
    final first =
        localSpread * layout.count - (adjacent == null ? _leadingPages : 0);
    final padding = adjacent?.padding ?? _publishedPadding ?? widget.padding;
    final frameInsets = padding.copyWith(
      top:
          padding.top +
          (adjacent?.headingExtent ??
              _publishedHeadingExtent ??
              _headingExtent),
    );
    final rtl =
        (mode ?? _publishedMode ?? widget.preferences.mode) ==
        ReaderMode.vertical;
    final boundary = chapterOutgoing != null;
    final direction = chapterDirection ?? _turnDirection;
    final active = boundary || _swipeOrigin != null && _turnSpread != null;
    final incoming = boundary ? !chapterOutgoing : spread == _turnSpread;
    Widget paper(Widget page, int slot) {
      if (_effect == ReaderPageEffect.paper) {
        final physical = rtl ? layout.count - 1 - slot : slot;
        final frame = layout.frameFor(physical, frameInsets);
        final bodyRect = layout.pages[physical].shift(
          Offset(frameInsets.left - frame.left, frameInsets.top),
        );
        page = Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: -frame.left,
              top: 0,
              width: _frameSize.width,
              height: _frameSize.height,
              child: _surface(
                _furniture(
                  spread,
                  physicalLeaf: physical,
                  leaves: layout.count,
                  chapterOutgoing: chapterOutgoing,
                  chapterDirection: chapterDirection,
                  adjacent: adjacent,
                ),
              ),
            ),
            Positioned.fromRect(rect: bodyRect, child: page),
          ],
        );
      }
      return ReaderSpineTurn(
        animation: _turn,
        clock: _paperClock,
        active:
            _effect == ReaderPageEffect.paper &&
            active &&
            (boundary || spread == _swipeOrigin || spread == _turnSpread),
        incoming: incoming,
        left: rtl ? slot == 1 : slot == 0,
        single: layout.count == 1,
        gap: layout.count == 2
            ? (layout.pages[1].left - layout.pages[0].right) / 2
            : 0,
        fromRight: direction > 0,
        paper: widget.preferences.background(
          Theme.of(context).brightness == Brightness.dark,
        ),
        child: page,
      );
    }

    final pages = <Widget>[];
    for (var slot = 0; slot < layout.count; slot++) {
      final index = first + slot;
      if (index < 0 || index >= pagination.pages.length) {
        // A blank final/leading leaf still has paper and the page furniture.
        pages.add(
          _effect == ReaderPageEffect.paper
              ? paper(const SizedBox.shrink(), slot)
              : const SizedBox.shrink(),
        );
        continue;
      }
      final body = (adjacent?.bodies ?? _pageBodies).putIfAbsent(index, () {
        _pageBodyBuilds++;
        return RepaintBoundary(
          child: (adjacent?.chapter.pageBuilder ?? widget.pageBuilder)(
            pagination.pages[index],
          ),
        );
      });
      Widget page =
          reflow &&
              adjacent == null &&
              spread == _spreadFor(_page) &&
              spread != _turnSpread &&
              !_bookReconfiguration &&
              slot < _previousLeaves.length &&
              _previousLeafSize != null
          ? ReaderReflowScope(
              animation: _arrival,
              previous: _previousLeaves[slot],
              current: pagination.pages[index],
              size: pagination.size,
              previousSize: _previousLeafSize!,
              originDelta: _originDelta,
              child: body,
            )
          : body;
      final entering =
          !boundary &&
          (_initialArrival || _modeReconfiguration) &&
          spread == _spreadFor(_page);
      final outgoing =
          chapterOutgoing ??
          (_swipeOrigin != null &&
              spread == _swipeOrigin &&
              spread != _turnSpread &&
              _turnSpread != null);
      final showPlaceholder =
          turn && _initialArrival && spread == _spreadFor(_page);
      final skeleton = <Widget>[];
      if (showPlaceholder) {
        final leaf = pagination.pages[index];
        final vertical = widget.preferences.mode == ReaderMode.vertical;
        final divisions = vertical
            ? (leaf.glyphs
                  .map((g) => pagination.size.width - g.rect.right)
                  .toSet()
                  .toList()
                ..sort())
            : leaf.fragments.map((f) => f.rect.top).toList();
        skeleton.add(
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: ReaderTurnPlaceholder(
                  divisions: divisions,
                  vertical: vertical,
                  child: ReaderSkeleton(vertical: vertical, expand: true),
                ),
              ),
            ),
          ),
        );
      }
      // Keep the retained article under the same parent when its skeleton
      // finishes; selection/render caches must not remount at the handoff.
      page = Stack(
        fit: StackFit.expand,
        children: [
          ...skeleton,
          KeyedSubtree(
            key: ValueKey('reader-retained-leaf-$index'),
            child: page,
          ),
        ],
      );
      page = ReaderTurnScope(
        animation: entering ? _arrival : _turn,
        direction: entering
            ? (_modeReconfiguration
                  ? _modeDirection
                  : widget.preferences.mode == ReaderMode.vertical
                  ? -1
                  : 1)
            : direction,
        enabled:
            turn &&
            (entering ||
                _effect == ReaderPageEffect.staggered &&
                    (incoming || outgoing)),
        outgoing: outgoing,
        relay: !entering && (outgoing || incoming),
        vertical:
            (_publishedMode ?? widget.preferences.mode) == ReaderMode.vertical,
        leafSize: pagination.size,
        travelWidth: _frameSize.width,
        slot: slot,
        slots: layout.count,
        child: page,
      );
      pages.add(paper(page, slot));
    }
    final book = ReaderBookSpread(
      key: ValueKey('reader-book-spread-$spread'),
      layout: layout,
      frameInsets: _effect == ReaderPageEffect.paper ? frameInsets : null,
      edgeOverflow: _effect == ReaderPageEffect.staggered && active
          ? (padding.left > padding.right ? padding.left : padding.right)
          : 0,
      verticalOverflow: _reflowOverflow,
      clipLeaves: !(_effect == ReaderPageEffect.paper && active),
      rightToLeft:
          (mode ?? _publishedMode ?? widget.preferences.mode) ==
          ReaderMode.vertical,
      pages: pages,
    );
    return SizedBox(
      key: ValueKey('reader-page-frame-$spread'),
      width: _frameSize.width,
      height: _frameSize.height,
      child: _effect == ReaderPageEffect.paper
          ? book
          : _surface(
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Padding(padding: frameInsets, child: book),
                  ),
                  Positioned.fill(
                    child: _furniture(
                      spread,
                      chapterOutgoing: chapterOutgoing,
                      chapterDirection: chapterDirection,
                      adjacent: adjacent,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _furniture(
    int spread, {
    int physicalLeaf = 0,
    int leaves = 1,
    bool? chapterOutgoing,
    double? chapterDirection,
    _AdjacentLayout? adjacent,
  }) {
    final padding = adjacent?.padding ?? _publishedPadding ?? widget.padding;
    final pagination = adjacent?.pagination ?? _pagination!;
    final perSpread = adjacent?.bookLayout.count ?? _perSpread;
    final countSpreads = adjacent == null
        ? _spreadCount
        : (pagination.pages.length / perSpread).ceil();
    final localSpread = adjacent == null
        ? spread
        : spread < 0
        ? countSpreads - 1
        : 0;
    final rawFirst =
        localSpread * perSpread - (adjacent == null ? _leadingPages : 0);
    final first = rawFirst.clamp(0, pagination.pages.length - 1);
    final last = (rawFirst + perSpread - 1).clamp(
      first,
      pagination.pages.length - 1,
    );
    final fraction = countSpreads < 2 ? 0 : localSpread / (countSpreads - 1);
    final anchor = pagination.pages[first].anchor;
    final title = adjacent == null
        ? _publishedTitleForAnchor?.call(anchor) ??
              _publishedTitle ??
              widget.title
        : adjacent.chapter.titleForAnchor?.call(anchor) ??
              adjacent.chapter.title;
    Key key(String name, {int leaf = 0}) => ValueKey(
      spread == _restingSpread && physicalLeaf == leaf
          ? name
          : '$name-$spread-$physicalLeaf',
    );
    final count = widget.bookTitle == null
        ? perSpread == 1
              ? '${first + 1}/${pagination.pages.length}页 · ${(fraction * 100).round()}%'
              : '${first + 1}–${last + 1}/${pagination.pages.length}页 · ${(fraction * 100).round()}%'
        : perSpread == 1
        ? '${first + 1} / ${pagination.pages.length} 页 · ${(fraction * 100).round()}%'
        : '${first + 1}–${last + 1} / ${pagination.pages.length} 页 · ${(fraction * 100).round()}%';
    Widget part(Widget child) => ReaderTurnPart(
      motion: ReaderTurnScope(
        animation: _turn,
        direction: chapterDirection ?? _turnDirection,
        outgoing: chapterOutgoing ?? spread == _swipeOrigin,
        enabled:
            _effect == ReaderPageEffect.staggered &&
            (chapterOutgoing != null ||
                (_swipeOrigin != null &&
                    _turnSpread != null &&
                    (spread == _swipeOrigin || spread == _turnSpread))),
        relay: true,
        leafSize: _frameSize,
        child: const SizedBox.shrink(),
      ),
      bounds: Rect.fromLTWH(0, 0, _frameSize.width, 1),
      child: child,
    );
    Widget information(Widget child, {bool interactive = false}) =>
        widget.chrome == null
        ? interactive
              ? child
              : IgnorePointer(child: child)
        : ReaderLocationLayer(
            chrome: widget.chrome!,
            interactive: interactive,
            child: child,
          );
    final informationStyle = TextStyle(
      fontSize: 13,
      height: 1.4,
      color: widget.preferences
          .controlForeground(Theme.of(context).brightness == Brightness.dark)
          .withValues(alpha: .72),
    );
    final statusInsets =
        widget.bookTitle != null && widget.preferences.hideSystemStatus
        ? ReaderStatusFooter.horizontalInsetsFor(
            context,
            extra: widget.preferences.statusSideInset,
            fontSize: widget.preferences.statusFontSize,
          )
        : EdgeInsets.zero;
    return IgnorePointer(
      ignoring: spread != _restingSpread,
      child: SelectionContainer.disabled(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.status != null && widget.bookTitle == null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: part(widget.status!),
              ),
            if (widget.bookTitle == null || widget.preferences.showReaderStatus)
              Positioned(
                top: widget.bookTitle == null
                    ? padding.top
                    : widget.preferences.statusTopOffset,
                left: padding.left > statusInsets.left
                    ? padding.left
                    : statusInsets.left,
                right: padding.right > statusInsets.right
                    ? padding.right
                    : statusInsets.right,
                child: part(
                  information(
                    widget.bookTitle != null
                        ? ReaderStatusFooter(
                            key: key('reader-chapter-location'),
                            compact: true,
                            statusBand: true,
                            fontSize: widget.preferences.statusFontSize,
                            timeAtEnd: false,
                            showBattery: widget.preferences.hideSystemStatus,
                            ink: informationStyle.color,
                          )
                        : Row(
                            key: key('reader-chapter-location'),
                            children: [
                              Expanded(
                                child: ReaderChapterTitle(
                                  text: title,
                                  key: key('reader-chapter-title'),
                                  style: _chapterHeadingStyle(widget.style),
                                  active: spread == _restingSpread,
                                  chrome: widget.chrome,
                                  showWithChrome: false,
                                  reduceMotion: widget.reduceMotion,
                                ),
                              ),
                              if (widget.showPageCount) ...[
                                const SizedBox(width: 12),
                                IgnorePointer(
                                  child: AppText(
                                    count,
                                    key: key(
                                      'reader-page-count',
                                      leaf: leaves - 1,
                                    ),
                                    maxLines: 1,
                                    textAlign: TextAlign.end,
                                    style: widget.style.copyWith(
                                      fontSize: 11,
                                      height: 1.3,
                                      color: widget.style.color?.withValues(
                                        alpha: .55,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                    interactive: true,
                  ),
                ),
              ),
            if (widget.bookTitle != null)
              Positioned(
                left: padding.left,
                right: padding.right,
                bottom:
                    (padding.bottom - ReaderScrollLocation.extentOf(context))
                        .clamp(0.0, double.infinity),
                child: part(
                  information(
                    Row(
                      key: key('reader-bottom-location'),
                      children: [
                        Expanded(
                          child: ReaderChapterTitle(
                            text: title,
                            key: key('reader-bottom-chapter-title'),
                            style: informationStyle,
                            active: spread == _restingSpread,
                            chrome: widget.chrome,
                            showWithChrome: false,
                            reduceMotion: widget.reduceMotion,
                          ),
                        ),
                        if (widget.showPageCount) ...[
                          const SizedBox(width: 12),
                          AppText(
                            count,
                            key: key('reader-page-count', leaf: leaves - 1),
                            maxLines: 1,
                            style: informationStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _surface(Widget child) => _effect == ReaderPageEffect.staggered
      ? child
      : widget.backgroundBuilder?.call(child) ??
            ColoredBox(
              color: widget.preferences.background(
                Theme.of(context).brightness == Brightness.dark,
              ),
              child: child,
            );

  Widget _chapterSheet(Widget child, {required bool incoming}) {
    if (_effect == ReaderPageEffect.slide) {
      return SlideTransition(
        position: _turn.drive(
          Tween<Offset>(
            begin: Offset(incoming ? _chapterTurnDirection : 0, 0),
            end: Offset(incoming ? 0 : -_chapterTurnDirection, 0),
          ),
        ),
        child: child,
      );
    }
    if (_effect == ReaderPageEffect.cover || _effect == ReaderPageEffect.fade) {
      return ReaderSheetMotion(
        animation: _turn,
        effect: _effect,
        direction: _chapterTurnDirection,
        incoming: incoming,
        front: incoming == _chapterTurnForward,
        active: true,
        paper: widget.preferences.background(
          Theme.of(context).brightness == Brightness.dark,
        ),
        child: child,
      );
    }
    return child;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final bookLayout = _layoutFor(size, widget.title);
      final scaler = MediaQuery.textScalerOf(context);
      final key = _paginationKey(
        widget.chapterKey,
        widget.content,
        bookLayout,
        scaler,
        _pageBreakAnchor,
      );
      if (_layoutKey != key) {
        _layoutKey = key;
        unawaited(_layout(bookLayout, scaler, key));
      }
      _scheduleAdjacent(size, scaler);
      final pagination = _pagination;
      if (_layoutFailed) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppText('本章排版失败'),
              GlassTextButton(
                key: const ValueKey('reader-pagination-retry'),
                onPressed: () => setState(() => _layoutKey = null),
                child: const AppText('重试'),
              ),
            ],
          ),
        );
      }
      if (pagination == null) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ReaderPageSkeleton(
              title: widget.title,
              padding: widget.padding,
              style: widget.style,
              vertical: widget.preferences.mode == ReaderMode.vertical,
              margin: widget.preferences.bindingMargin,
            ),
            if (widget.status != null)
              Positioned(left: 0, right: 0, top: 0, child: widget.status!),
          ],
        );
      }
      final pendingViewport = _layingOut && _bookLayout!.key != bookLayout.key;
      final pager = _pager!;
      final pageView = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (!mounted ||
              !identical(_pager, pager) ||
              notification.depth != 0) {
            return false;
          }
          if (notification is ScrollStartNotification &&
              notification.dragDetails != null) {
            _turn.stop();
            setState(() {
              _turnSpread = null;
              _swipeOrigin = ((pager.page ?? _edgeSlots) - _edgeSlots).round();
              _programmaticTurn = false;
            });
            _overscroll = 0;
            _crossedBoundary = false;
            _swipeFeedbackSent = false;
            _swipeCancelled = false;
            _target = _page;
            _pendingFraction = null;
            _pendingPosition = null;
            widget.onUserScroll();
          }
          if (notification is ScrollUpdateNotification &&
              notification.metrics is PageMetrics) {
            _scrubTurn(notification.metrics as PageMetrics);
          }
          if (notification is ScrollEndNotification && _swipeOrigin != null) {
            final position = (pager.page ?? _edgeSlots) - _edgeSlots;
            final spread = position.round();
            // Touching a ballistic page puts Scrollable into a hold activity,
            // which also emits ScrollEnd. It is not a completed turn: keep the
            // live sheet/clock until it really snaps, or the next drag can still
            // be attached to a rail that was replaced by a premature handoff.
            if ((position - spread).abs() > .0001) return false;
            final boundary = spread < 0
                ? -1
                : spread >= _spreadCount
                ? 1
                : 0;
            if (boundary != 0 && _adjacentLayouts.containsKey(boundary)) {
              _finishBoundary(boundary);
            }
            setState(() {
              _swipeOrigin = null;
              _programmaticTurn = false;
              _target = _page;
              _turn.value = 1;
              _turnSpread = null;
            });
          }
          if (notification is OverscrollNotification &&
              notification.dragDetails != null &&
              !_crossedBoundary) {
            _overscroll += notification.overscroll;
            if (_overscroll.abs() > 36) {
              _crossedBoundary = true;
              widget.onBoundary(_overscroll > 0 ? 1 : -1);
            }
          }
          return false;
        },
        child: Listener(
          key: const ValueKey('reader-page-pointer-listener'),
          onPointerDown: (event) {
            if (!mounted) return;
            _paperClock.touchY = event.localPosition.dy / _frameSize.height;
          },
          onPointerCancel: (_) {
            // A cancelled pointer may still snap its rail to a safe page, but
            // it is not an accepted release and must not acknowledge a turn.
            _swipeCancelled = true;
          },
          onPointerMove: (event) {
            // A pointer keeps its original hit-test path until up or
            // cancel, even if navigation has already disposed this page.
            if (!mounted) return;
            if (_effect == ReaderPageEffect.paper && _swipeOrigin != null) {
              _paperClock.touchY = event.localPosition.dy / _frameSize.height;
            }
          },
          child: PageView.builder(
            key: GlobalObjectKey(pagination),
            controller: pager,
            reverse:
                (_publishedMode ?? widget.preferences.mode) ==
                ReaderMode.vertical,
            clipBehavior: Clip.none,
            pageSnapping: false,
            physics: ReaderPagePhysics(
              onUserPageCommitted: _acknowledgePageCommit,
              liveDurationScale: () =>
                  widget.preferences.pageSpeed.durationScale,
              // The short-stroke limit belongs to finger gestures. A
              // follow/bookmark landing can cross several spreads; its
              // final ballistic phase must not snap back to origin + 1.
              origin: () => _programmaticTurn || _swipeOrigin == null
                  ? null
                  : _swipeOrigin! + _edgeSlots,
              pageBounds: _edgeSlots == 0
                  ? null
                  : () => (
                      first: _adjacentLayouts.containsKey(-1) ? 0 : 1,
                      last:
                          _spreadCount +
                          (_adjacentLayouts.containsKey(1) ? 1 : 0),
                    ),
              parent: const ClampingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
            ),
            itemCount: _spreadCount + _edgeSlots * 2,
            onPageChanged: (value) {
              if (!mounted || !identical(_pager, pager)) return;
              value -= _edgeSlots;
              if (value < 0 || value >= _spreadCount) return;
              setState(() {
                _page = _spreadFor(_target) == value
                    ? _target
                    : (value * _perSpread - _leadingPages).clamp(
                        0,
                        _pagination!.pages.length - 1,
                      );
                if (!_programmaticTurn) _target = _page;
                if (_swipeOrigin != null && !_programmaticTurn) {
                  _readingAnchor = _firstVisibleAnchor;
                }
              });
              _pageBodies.removeWhere(
                (index, _) => (_spreadFor(index) - value).abs() > 1,
              );
              widget.onChanged();
            },
            itemBuilder: (context, index) {
              index -= _edgeSlots;
              final chapter =
                  _chapterOutgoing != null && index == _spreadFor(_page);
              final body = _spreadBody(
                index,
                chapterOutgoing: chapter ? false : null,
                chapterDirection: chapter ? _chapterTurnDirection : null,
              );
              final incoming = index == _turnSpread;
              final turning = _swipeOrigin != null && _turnSpread != null;
              final visible =
                  _effect == ReaderPageEffect.none || _swipeOrigin == null
                  ? index == _restingSpread
                  : index == _swipeOrigin || incoming;
              final sheet = chapter
                  ? _chapterSheet(body, incoming: true)
                  : _effect == ReaderPageEffect.cover ||
                        _effect == ReaderPageEffect.fade
                  ? ReaderSheetMotion(
                      animation: _turn,
                      effect: _effect,
                      direction: _turnDirection,
                      incoming: incoming,
                      front:
                          incoming ==
                          ((_turnSpread ?? 0) > (_swipeOrigin ?? 0)),
                      active: turning,
                      paper: widget.preferences.background(
                        Theme.of(context).brightness == Brightness.dark,
                      ),
                      child: body,
                    )
                  : body;
              final anchored = _effect == ReaderPageEffect.slide
                  ? sheet
                  : ReaderPageAnchor(
                      offset: Scrollable.of(context).position,
                      index: index + _edgeSlots,
                      reverse:
                          (_publishedMode ?? widget.preferences.mode) ==
                          ReaderMode.vertical,
                      visible: visible,
                      child: sheet,
                    );
              return ExcludeSemantics(
                excluding: index != _restingSpread,
                child: ReaderPageSelection(
                  enabled: index == _restingSpread,
                  child: anchored,
                ),
              );
            },
          ),
        ),
      );
      final turning = KeyedSubtree(
        key: const ValueKey('reader-turn-incoming'),
        child: ClipRect(
          child: IgnorePointer(
            ignoring:
                _layingOut ||
                _chapterOutgoing != null ||
                _boundaryLanding != null,
            child: pageView,
          ),
        ),
      );
      final outgoingChapter = _chapterOutgoing == null
          ? null
          : IgnorePointer(
              key: const ValueKey('reader-chapter-outgoing'),
              child: ExcludeSemantics(
                child: SelectionContainer.disabled(
                  child: _chapterSheet(_chapterOutgoing!, incoming: false),
                ),
              ),
            );
      final chapterFrame = Stack(
        key: const ValueKey('reader-chapter-transition'),
        fit: StackFit.expand,
        children: [
          if (outgoingChapter != null && _chapterTurnForward) outgoingChapter,
          turning,
          if (outgoingChapter != null && !_chapterTurnForward) outgoingChapter,
        ],
      );
      final reconfigured = _modeReconfiguration && _previousPage != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: ExcludeSemantics(
                    child: SelectionContainer.disabled(
                      child: KeyedSubtree(
                        key: const ValueKey('reader-mode-outgoing'),
                        child: _previousPage!,
                      ),
                    ),
                  ),
                ),
                ReaderTurnScope(
                  key: const ValueKey('reader-mode-incoming'),
                  animation: _arrival,
                  direction: _modeDirection,
                  child: chapterFrame,
                ),
              ],
            )
          : _bookReconfiguration && _previousPage != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: ExcludeSemantics(
                    child: SelectionContainer.disabled(
                      child: ArchivePlaneTransition(
                        key: const ValueKey('reader-book-outgoing'),
                        animation: _arrival,
                        kind: ArchivePlaneKind.outgoing,
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: _previousSize!.width,
                          maxWidth: _previousSize!.width,
                          minHeight: _previousSize!.height,
                          maxHeight: _previousSize!.height,
                          child: _previousPage!,
                        ),
                      ),
                    ),
                  ),
                ),
                ArchivePlaneTransition(
                  key: const ValueKey('reader-book-incoming'),
                  animation: _arrival,
                  child: ColoredBox(
                    color: widget.preferences.background(
                      Theme.of(context).brightness == Brightness.dark,
                    ),
                    child: chapterFrame,
                  ),
                ),
              ],
            )
          : chapterFrame;
      final viewport = ReaderIncrementalViewport(
        key: const ValueKey('reader-incremental-viewport'),
        animation: pendingViewport
            ? const AlwaysStoppedAnimation(0)
            : _previousSize == null
            ? const AlwaysStoppedAnimation(1)
            : _arrival,
        fromSize: pendingViewport ? _frameSize : _previousSize ?? size,
        toSize: size,
        // The paper now owns the complete screen. Only the body reflow scope
        // changes its inset; shifting the screen clip would cut off furniture.
        originDelta: Offset.zero,
        // Each paragraph/vertical column owns its outgoing ink. A
        // second full-page tail paints the same glyphs twice while
        // the viewport shrinks, darkening them for one transition.
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _frameSize.width,
          maxWidth: _frameSize.width,
          minHeight: _frameSize.height,
          maxHeight: _frameSize.height,
          child: reconfigured,
        ),
      );
      return viewport;
    },
  );
}
