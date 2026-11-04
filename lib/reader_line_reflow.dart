part of 'reader_reflow.dart';

/// Entering and departing rows inherit the nearest retained row's trajectory.
/// Newly exposed text therefore comes from outside the old reading window,
/// instead of appearing underneath lines that have not moved out of its way.
class _LineReflowPlan {
  _LineReflowPlan(ReaderReflowScope scope) {
    List<({(int, int, int) key, Offset at})> flatten(ReaderLeaf page) => [
      for (final fragment in page.fragments)
        for (final line in fragment.lines)
          (
            key: (fragment.paragraph, line.start, line.end),
            at: fragment.rect.topLeft + Offset(0, line.top),
          ),
    ];
    final before = flatten(scope.previous),
        after = flatten(scope.current ?? scope.previous);
    final oldByKey = {for (final row in before) row.key: row.at};
    final newByKey = {for (final row in after) row.key: row.at};
    incoming = _nearest([
      for (final row in after)
        oldByKey.containsKey(row.key)
            ? scope.originDelta + oldByKey[row.key]! - row.at
            : null,
    ]);
    outgoing = _nearest([
      for (final row in before)
        newByKey.containsKey(row.key)
            ? scope.originDelta + row.at - newByKey[row.key]!
            : null,
    ]);
  }
  late final List<Offset> incoming, outgoing;
  static List<Offset> _nearest(List<Offset?> rows) {
    final next = List<int>.filled(rows.length, -1);
    var nearest = -1;
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i] != null) nearest = i;
      next[i] = nearest;
    }
    var previous = -1;
    return [
      for (var i = 0; i < rows.length; i++)
        (() {
          if (rows[i] != null) {
            previous = i;
            return rows[i]!;
          }
          final following = next[i];
          final at =
              previous >= 0 && (following < 0 || i - previous <= following - i)
              ? previous
              : following;
          return at < 0 ? Offset.zero : rows[at]!;
        })(),
    ];
  }
}

class _ReaderLineMotion extends MultiChildRenderObjectWidget {
  _ReaderLineMotion({
    required this.scope,
    required this.fragment,
    required Widget child,
    this.previous,
    this.leaving = false,
    Widget? previousChild,
  }) : super(
         children: [
           child,
           if (previousChild != null)
             IgnorePointer(
               child: ExcludeSemantics(
                 child: SelectionContainer.disabled(child: previousChild),
               ),
             ),
         ],
       );
  final ReaderReflowScope scope;
  final ReaderPageFragment fragment;
  final ReaderPageFragment? previous;
  final bool leaving;

  @override
  RenderReaderLineMotion createRenderObject(BuildContext context) =>
      RenderReaderLineMotion._(this);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderLineMotion object,
  ) => object._update(this);
}

/// Shapes each paragraph once, then moves its existing ink in line-sized bands.
/// Reflow neither splits Text into one widget per line nor relayouts on ticks:
/// justification, rich spans, selection offsets and ruby keep their native text.
class RenderReaderLineMotion extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  RenderReaderLineMotion._(_ReaderLineMotion config) : _config = config {
    _prepare();
  }
  _ReaderLineMotion _config;
  late List<ReaderPageLine> _lines, _oldLines;
  late Map<(int, int), int> _oldBySource;
  late List<int> _departingOld;
  late int _rank, _count, _oldRank, _oldCount;
  ReaderReflowScope get _scope => _config.scope;
  // Start at the leading edge of travel. Rows moving down settle bottom-first;
  // rows moving up settle top-first, so their ink never overtakes the next row.
  bool get _reverse => (_scope._linePlan.incoming.firstOrNull?.dy ?? 0) < 0;

  @visibleForTesting
  int get debugLineCount => _lines.length;
  @visibleForTesting
  double debugLineProgress(int index) =>
      _scope.progressFor(_rank + index, _count, reverse: _reverse);
  @visibleForTesting
  Offset debugLineDisplacement(int index) {
    final p = debugLineProgress(index);
    return _scope._linePlan.incoming[_rank + index] * (1 - p);
  }

  void _prepare() {
    _lines = _config.fragment.lines.toList(growable: false);
    _oldLines = _config.previous?.lines.toList(growable: false) ?? const [];
    _oldBySource = {
      for (var i = 0; i < _oldLines.length; i++)
        (_oldLines[i].start, _oldLines[i].end): i,
    };
    final current = {for (final line in _lines) (line.start, line.end)};
    _departingOld = [
      for (var i = 0; i < _oldLines.length; i++)
        if (!current.contains((_oldLines[i].start, _oldLines[i].end))) i,
    ];
    _rank = _scope.lineIndex(_config.fragment, departing: _config.leaving);
    _count = _scope.lineCount(departing: _config.leaving);
    _oldRank = _config.previous == null
        ? 0
        : _scope.lineIndex(_config.previous!, departing: true);
    _oldCount = _scope.lineCount(departing: true);
  }

  void _update(_ReaderLineMotion value) {
    final clock = _scope.animation;
    if (attached && clock != value.scope.animation) {
      clock.removeListener(markNeedsPaint);
      value.scope.animation.addListener(markNeedsPaint);
    }
    _config = value;
    _prepare();
    markNeedsLayout();
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scope.animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _scope.animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _LineParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_config.fragment.rect.size);
  @override
  void performLayout() {
    size = computeDryLayout(constraints);
    firstChild!.layout(BoxConstraints.tight(size));
    if (childCount > 1) {
      lastChild!.layout(BoxConstraints.tight(_config.previous!.rect.size));
    }
  }

  @override
  Rect get paintBounds {
    var bounds = Offset.zero & size;
    if (_config.previous case final old?) {
      bounds = bounds.expandToInclude(
        (_scope.originDelta +
                old.rect.topLeft -
                _config.fragment.rect.topLeft) &
            old.rect.size,
      );
    } else if (_config.leaving) {
      bounds = bounds.expandToInclude(bounds.shift(_scope.originDelta));
    }
    return bounds.inflate(24);
  }

  Rect _band(List<ReaderPageLine> lines, int i, double width) => Rect.fromLTRB(
    -8,
    i == 0 ? -24 : lines[i].top,
    width + 8,
    lines[i].top + lines[i].height + (i == lines.length - 1 ? 4 : 0),
  );
  void _paintBand(
    PaintingContext context,
    RenderBox child,
    Offset offset,
    Rect clip, {
    double opacity = 1,
  }) {
    if (clip.isEmpty || opacity <= 0) return;
    context.pushClipRect(needsCompositing, offset, clip, (context, at) {
      if (opacity >= 1) {
        context.paintChild(child, at);
      } else {
        context.pushOpacity(at, (255 * opacity).round(), (context, at) {
          context.paintChild(child, at);
        });
      }
    });
  }

  void _depart(
    PaintingContext context,
    RenderBox child,
    Offset origin,
    List<ReaderPageLine> lines,
    int i,
    int rank,
    int count,
  ) {
    final p = _scope.progressFor(rank + i, count, reverse: _reverse);
    if (p >= 1) return;
    final box = _band(lines, i, child.size.width);
    _paintBand(
      context,
      child,
      origin - _scope._linePlan.outgoing[rank + i] * p,
      box,
      opacity: 1 - p,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = firstChild!;
    if (_scope.animation.value >= 1) {
      if (!_config.leaving) context.paintChild(child, offset);
      return;
    }
    if (_config.leaving) {
      for (var i = 0; i < _lines.length; i++) {
        _depart(
          context,
          child,
          offset + _scope.originDelta,
          _lines,
          i,
          _rank,
          _count,
        );
      }
      return;
    }
    final oldChild = childCount > 1 ? lastChild : null;
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i], p = debugLineProgress(i);
      final band = _band(_lines, i, size.width);
      final oldIndex = _oldBySource[(line.start, line.end)];
      final origin = offset + debugLineDisplacement(i);
      if (oldIndex == null) {
        _paintBand(context, child, origin, band, opacity: p);
        continue;
      }
      if (oldChild == null) {
        _paintBand(context, child, origin, band);
        continue;
      }
      final before = _oldLines[oldIndex];
      final delta = line.top - before.top;
      final oldBand = _band(_oldLines, oldIndex, oldChild.size.width);
      final owned = band.expandToInclude(oldBand.shift(Offset(0, delta)));
      final seam = lerpDouble(owned.top, owned.bottom, p)!;
      _paintBand(
        context,
        child,
        origin,
        band.intersect(Rect.fromLTRB(owned.left, owned.top, owned.right, seam)),
      );
      _paintBand(
        context,
        oldChild,
        origin + Offset(0, delta),
        oldBand.intersect(
          Rect.fromLTRB(
            owned.left,
            seam - delta,
            owned.right,
            owned.bottom - delta,
          ),
        ),
      );
    }
    if (oldChild != null) {
      final origin =
          offset +
          _scope.originDelta +
          _config.previous!.rect.topLeft -
          _config.fragment.rect.topLeft;
      for (final i in _departingOld) {
        _depart(context, oldChild, origin, _oldLines, i, _oldRank, _oldCount);
      }
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_config.leaving) return false;
    for (var i = 0; i < _lines.length; i++) {
      final shift = debugLineDisplacement(i);
      if (!_band(_lines, i, size.width).shift(shift).contains(position)) {
        continue;
      }
      if (result.addWithPaintOffset(
        offset: shift,
        position: position,
        hitTest: (result, point) =>
            firstChild!.hitTest(result, position: point),
      )) {
        return true;
      }
    }
    return false;
  }
}

class _LineParentData extends ContainerBoxParentData<RenderBox> {}
