import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Measure once at the target width, then move retained content from its actual
/// previous position. No bitmap readback, scaling of books, or per-frame layout.
class LibraryReflowController extends ChangeNotifier {
  final _parts = <LibraryReflowRender>{};
  Map<Object, Rect> _sources = const {};
  Animation<double> _clock = const AlwaysStoppedAnimation(1);
  LibraryReflowClipRender? _clip;
  Rect? _sourceViewport;
  bool active = false;
  int generation = 0;
  @visibleForTesting
  Animation<double> get debugClock => _clock;
  double get progress =>
      const Cubic(.18, .72, .18, 1).transform(_clock.value.clamp(0, 1));
  void begin(Animation<double> clock) {
    final viewport = _clip?.globalViewport;
    final sources = <Object, Rect>{};
    for (final part in _parts) {
      if (!part.relocate || !part.attached || !part.hasSize || part.hidden) {
        continue;
      }
      final rect = part.currentGlobalRect;
      if (viewport == null || viewport.overlaps(rect)) {
        sources[part.identity] = rect;
      }
    }
    _clock.removeListener(notifyListeners);
    _sources = sources;
    _sourceViewport = viewport;
    _clock = clock;
    active = true;
    generation++;
    clock.addListener(notifyListeners);
    notifyListeners();
  }

  void finish() {
    _clock.removeListener(notifyListeners);
    _clock = const AlwaysStoppedAnimation(1);
    active = false;
    _sources = const {};
    _sourceViewport = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _clock.removeListener(notifyListeners);
    super.dispose();
  }
}

class LibraryReflowScope extends InheritedWidget {
  const LibraryReflowScope({
    super.key,
    required this.controller,
    required this.enabled,
    required this.generation,
    required this.active,
    required super.child,
  });
  final LibraryReflowController controller;
  final bool enabled, active;
  final int generation;
  static LibraryReflowScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LibraryReflowScope>();
  static Clip clipOf(BuildContext context) =>
      of(context)?.active == true ? Clip.none : Clip.hardEdge;
  @override
  bool updateShouldNotify(LibraryReflowScope oldWidget) =>
      enabled != oldWidget.enabled ||
      active != oldWidget.active ||
      generation != oldWidget.generation;
}

class LibraryReflowPart extends StatelessWidget {
  const LibraryReflowPart({
    super.key,
    this.id,
    this.relocate = true,
    this.order = 0,
    required this.child,
  });
  final Object? id;
  final bool relocate;
  final int order;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scope = LibraryReflowScope.of(context);
    // Keep the render/child topology across portrait, landscape and reduced
    // motion changes; replacing this wrapper recreates inner Scrollables.
    if (scope == null ||
        context.getInheritedWidgetOfExactType<_PartScope>() != null) {
      return child;
    }
    return _PartScope(
      child: _Part(
        controller: scope.controller,
        id: id,
        relocate: relocate,
        order: order,
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

class _PartScope extends InheritedWidget {
  const _PartScope({required super.child});
  @override
  bool updateShouldNotify(_PartScope oldWidget) => false;
}

class _Part extends SingleChildRenderObjectWidget {
  const _Part({
    required this.controller,
    this.id,
    required this.relocate,
    required this.order,
    required super.child,
  });
  final LibraryReflowController controller;
  final Object? id;
  final bool relocate;
  final int order;
  @override
  LibraryReflowRender createRenderObject(BuildContext context) =>
      LibraryReflowRender(controller, id, relocate, order);
  @override
  void updateRenderObject(
    BuildContext context,
    LibraryReflowRender renderObject,
  ) => renderObject.update(controller, id, relocate, order);
}

class LibraryReflowRender extends RenderProxyBox {
  LibraryReflowRender(this.controller, this.id, this.relocate, this.order);
  LibraryReflowController controller;
  Object? id;
  bool relocate;
  int order;
  Object get identity => id ?? this;
  final _translation = LayerHandle<TransformLayer>();
  final _clip = LayerHandle<ClipRectLayer>();
  final _opacity = LayerHandle<OpacityLayer>();
  int _originGeneration = -1;
  Offset _targetOrigin = Offset.zero;
  Offset get _origin {
    if (!controller.active) return localToGlobal(Offset.zero);
    if (_originGeneration != controller.generation) {
      _originGeneration = controller.generation;
      _targetOrigin = localToGlobal(Offset.zero);
    }
    return _targetOrigin;
  }

  @override
  void performLayout() {
    _originGeneration = -1;
    super.performLayout();
  }

  Rect? get _source => controller.active ? controller._sources[identity] : null;
  double get _progress => !controller.active
      ? 1
      : relocate
      ? controller.progress
      : ((controller.progress - (order % 9) * .025) / (1 - (order % 9) * .025))
            .clamp(0.0, 1.0);
  Offset get displacement => !relocate
      ? Offset(0, 10 * (1 - _progress))
      : _source == null
      ? Offset.zero
      : (_source!.topLeft - _origin) * (1 - controller.progress);
  Size get _visibleSize => _source == null
      ? size
      : Size.lerp(_source!.size, size, controller.progress)!;
  Rect get currentGlobalRect => (_origin + displacement) & _visibleSize;
  bool get hidden {
    for (
      RenderObject? ancestor = parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor is RenderOffstage && ancestor.offstage) return true;
    }
    return false;
  }

  void update(
    LibraryReflowController next,
    Object? nextId,
    bool nextRelocate,
    int nextOrder,
  ) {
    _originGeneration = -1;
    if (next != controller && attached) {
      _leave();
      controller = next;
      _join();
    } else {
      controller = next;
    }
    id = nextId;
    relocate = nextRelocate;
    order = nextOrder;
    markNeedsPaint();
  }

  void _join() {
    controller._parts.add(this);
    controller.addListener(markNeedsPaint);
  }

  void _leave() {
    controller._parts.remove(this);
    controller.removeListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _join();
  }

  @override
  void detach() {
    _leave();
    super.detach();
  }

  Matrix4 get _transform =>
      Matrix4.translationValues(displacement.dx, displacement.dy, 0);
  @override
  Rect get paintBounds => (Offset.zero & size).expandToInclude(
    (Offset.zero & _visibleSize).shift(displacement),
  );
  @override
  void paint(PaintingContext context, Offset offset) {
    if (!controller.active || relocate && _source == null) {
      super.paint(context, offset);
      return;
    }
    _translation.layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) {
        if (!relocate) {
          _opacity.layer = context.pushOpacity(
            offset,
            (_progress * 255).round(),
            super.paint,
            oldLayer: _opacity.layer,
          );
          return;
        }
        _clip.layer = context.pushClipRect(
          needsCompositing,
          offset,
          Offset.zero & _visibleSize,
          super.paint,
          oldLayer: _clip.layer,
        );
      },
      oldLayer: _translation.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, position) =>
            super.hitTest(result, position: position),
      );
  @override
  void dispose() {
    _translation.layer = null;
    _clip.layer = null;
    _opacity.layer = null;
    super.dispose();
  }
}

class LibraryReflowClip extends SingleChildRenderObjectWidget {
  const LibraryReflowClip({
    super.key,
    required this.controller,
    required super.child,
  });
  final LibraryReflowController controller;
  @override
  LibraryReflowClipRender createRenderObject(BuildContext context) =>
      LibraryReflowClipRender(controller);
}

class LibraryReflowClipRender extends RenderProxyBox {
  LibraryReflowClipRender(this.controller);
  final LibraryReflowController controller;
  final _layer = LayerHandle<ClipRectLayer>();
  Rect get globalViewport => viewport.shift(localToGlobal(Offset.zero));
  Rect get viewport {
    final source = controller.active ? controller._sourceViewport : null;
    return source == null
        ? Offset.zero & size
        : Rect.lerp(
            source.shift(-localToGlobal(Offset.zero)),
            Offset.zero & size,
            controller.progress,
          )!;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller._clip = this;
    controller.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    if (controller._clip == this) controller._clip = null;
    controller.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  Rect get paintBounds => (Offset.zero & size).expandToInclude(viewport);
  @override
  void paint(PaintingContext context, Offset offset) =>
      _layer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        viewport,
        super.paint,
        oldLayer: _layer.layer,
      );
  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }
}
