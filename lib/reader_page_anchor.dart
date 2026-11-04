import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class ReaderPageSelection extends StatelessWidget {
  const ReaderPageSelection({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;
  @override
  Widget build(BuildContext context) => SelectionRegistrarScope(
    registrar:
        (enabled ? SelectionContainer.maybeOf(context) : null) ??
        const _InactivePageRegistrar(),
    child: child,
  );
}

class _InactivePageRegistrar implements SelectionRegistrar {
  const _InactivePageRegistrar();
  @override
  void add(Selectable selectable) {}
  @override
  void remove(Selectable selectable) {}
}

/// PageView retains native drag, fling, cancellation and accessibility physics.
/// Cancel only its page-plane translation; paragraph/column layers own the move.
class ReaderPageAnchor extends SingleChildRenderObjectWidget {
  const ReaderPageAnchor({
    super.key,
    required this.offset,
    required this.index,
    required this.reverse,
    this.visible = true,
    required super.child,
  });
  final ViewportOffset offset;
  final int index;
  final bool reverse;
  final bool visible;
  @override
  ReaderPageAnchorRender createRenderObject(BuildContext context) =>
      ReaderPageAnchorRender(offset, index, reverse, visible);
  @override
  void updateRenderObject(
    BuildContext context,
    ReaderPageAnchorRender renderObject,
  ) => renderObject.update(offset, index, reverse, visible);
}

class ReaderPageAnchorRender extends RenderProxyBox {
  ReaderPageAnchorRender(this.offset, this.index, this.reverse, this.visible);
  ViewportOffset offset;
  int index;
  bool reverse;
  bool visible;
  final _layer = LayerHandle<TransformLayer>();
  int debugLayoutCount = 0;
  double get displacement => offset.hasPixels
      ? (offset.pixels - index * size.width) * (reverse ? -1 : 1)
      : 0;
  Matrix4 get _transform => Matrix4.translationValues(displacement, 0, 0);
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    offset.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    offset.removeListener(markNeedsPaint);
    super.detach();
  }

  void update(
    ViewportOffset next,
    int nextIndex,
    bool nextReverse,
    bool nextVisible,
  ) {
    if (offset != next && attached) {
      offset.removeListener(markNeedsPaint);
      next.addListener(markNeedsPaint);
    }
    offset = next;
    index = nextIndex;
    reverse = nextReverse;
    visible = nextVisible;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void performLayout() {
    super.performLayout();
    assert(() {
      debugLayoutCount++;
      return true;
    }());
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Neighbour pages are retained by PageView before their turn scope is
    // assigned. Cancelling their translation must not expose that idle text.
    if (!visible) return;
    _layer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      super.paint,
      oldLayer: _layer.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      visible &&
      result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, position) =>
            super.hitTest(result, position: position),
      );
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (visible) super.visitChildrenForSemantics(visitor);
  }

  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }
}
