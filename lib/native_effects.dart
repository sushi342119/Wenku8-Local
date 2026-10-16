import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'easy_glass.dart';
import 'glass_sampling_budget.dart';
import 'performance_preferences.dart';

/// Runtime effects execute on Android's Impeller GPU, without frame copies,
/// platform-view overlays or a CPU bitmap blur.
abstract final class NativeEffects {
  /// A compile-time switch keeps the previous renderer available for the
  /// identical Profile workload when diagnosing a rendering regression.
  static const easyGlass = bool.fromEnvironment(
    'EASY_LIQUID_GLASS',
    defaultValue: true,
  );
  static ui.FragmentProgram? _progressive;
  static ui.FragmentProgram? _glass;
  static ui.Image? _srgbLut;
  static Future<void>? _loading;

  static Future<void> prepare() {
    if (!ui.ImageFilter.isShaderFilterSupported) return Future.value();
    return _loading ??= _load();
  }

  static Future<void> _load() async {
    if (easyGlass) await LiquidGlassShaders.ensureLoaded();
    final lut = _makeSrgbLut();
    final programs = await Future.wait([
      ui.FragmentProgram.fromAsset('shaders/continuous_blur.frag'),
      ui.FragmentProgram.fromAsset('shaders/analytic_glass.frag'),
    ]);
    _srgbLut = await lut;
    _progressive = programs[0];
    _glass = programs[1];
    // Compile the broad-panel Gaussian/downsample pipelines before the first
    // menu gesture, not halfway through its opening animation. GPU-only scratch
    // content; no app frame capture or pixel readback.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    void drawFiltered(ui.ImageFilter filter) {
      canvas.saveLayer(
        const ui.Rect.fromLTWH(0, 0, 32, 32),
        ui.Paint()..imageFilter = filter,
      );
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 32, 32),
        ui.Paint()..color = const ui.Color(0xff808080),
      );
      canvas.restore();
    }

    for (final sigma in [3.0, 8.0, 16.0, 32.0]) {
      drawFiltered(
        ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: ui.TileMode.clamp,
        ),
      );
    }
    // Warm the actual runtime programs as well. Loading a FragmentProgram
    // does not exercise its first draw/filter pipeline on every GPU backend.
    final scratchShaders = <ui.FragmentShader>[];
    ui.ImageFilter runtimeFilter(
      ui.FragmentProgram program,
      List<double> uniforms, {
      bool lut = false,
    }) {
      final shader = program.fragmentShader();
      scratchShaders.add(shader);
      for (var index = 0; index < uniforms.length; index++) {
        shader.setFloat(index + 2, uniforms[index]);
      }
      if (lut) shader.setImageSampler(1, _srgbLut!);
      return ui.ImageFilter.shader(shader);
    }

    const optics = <double>[
      0,
      0,
      32,
      32,
      8,
      4,
      1.45,
      0,
      0,
      0,
      0,
      0,
      .5,
      .01,
      1,
    ];
    ui.ImageFilter glass() => runtimeFilter(_glass!, optics);
    final cull =
        const bool.fromEnvironment(
          'GLASS_CULL_UNUSED_PIXELS',
          defaultValue: true,
        )
        ? 1.0
        : 0.0;
    ui.ImageFilter blur(
      double axis,
      double stage,
      double maximum,
      double seed,
    ) => runtimeFilter(_progressive!, [
      0,
      0,
      32,
      32,
      maximum,
      8,
      0,
      axis,
      seed,
      stage,
      32,
      32,
      32,
      32,
      cull,
      1,
    ], lut: true);
    drawFiltered(glass());
    // Match the composed graph as well: an intermediate MSAA render target can
    // select a different GPU pipeline from a standalone saveLayer filter.
    drawFiltered(
      ui.ImageFilter.compose(
        outer: glass(),
        inner: ui.ImageFilter.compose(
          outer: blur(1, 0, 0, 1.05),
          inner: blur(0, 0, 0, 1.05),
        ),
      ),
    );
    drawFiltered(
      ui.ImageFilter.compose(
        outer: ui.ImageFilter.compose(
          outer: blur(1, 1, 12, 3),
          inner: blur(0, 1, 12, 3),
        ),
        inner: ui.ImageFilter.compose(
          outer: blur(1, 0, 12, 3),
          inner: blur(0, 0, 12, 3),
        ),
      ),
    );
    drawFiltered(
      ui.ImageFilter.compose(
        outer: glass(),
        inner: ui.ImageFilter.blur(
          sigmaX: 32,
          sigmaY: 32,
          tileMode: ui.TileMode.clamp,
        ),
      ),
    );
    final picture = recorder.endRecording();
    final warmup = await picture.toImage(32, 32);
    warmup.dispose();
    picture.dispose();
    for (final shader in scratchShaders) {
      shader.dispose();
    }
  }

  static Future<ui.Image> _makeSrgbLut() {
    // Two 8-bit channels retain 16-bit linear-light precision. Bilinear
    // interpolation recovers a smooth EOTF without an expensive power for
    // every blur tap or dark-tone quantization in an 8-bit linear texture.
    const width = 1024;
    final pixels = Uint8List(width * 4);
    for (var index = 0; index < width; index++) {
      final srgb = index / (width - 1);
      final linear = srgb <= .04045
          ? srgb / 12.92
          : math.pow((srgb + .055) / 1.055, 2.4).toDouble();
      final code = (linear * 65535).round().clamp(0, 65535);
      pixels[index * 4] = code >> 8;
      pixels[index * 4 + 1] = code & 255;
      pixels[index * 4 + 3] = 255;
    }
    final result = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      1,
      ui.PixelFormat.rgba8888,
      result.complete,
    );
    return result.future;
  }
}

enum NativeEffect { progressive, glass }

/// Controls on one already-composited background share its GPU snapshot.
/// Each keeps the established filter, clip, optics and foreground. Broad or
/// morphing overlays and partially transparent/overlapping planes stay apart.
class NativeGlassGroup extends StatefulWidget {
  const NativeGlassGroup({
    super.key,
    required this.child,
    this.enabled = true,
    this.inherit = true,
  });
  final Widget child;
  final bool enabled;
  final bool inherit;

  @override
  State<NativeGlassGroup> createState() => _NativeGlassGroupState();
}

class _NativeGlassGroupState extends State<NativeGlassGroup> {
  final _group = _GlassInputGroup();

  @override
  Widget build(BuildContext context) {
    if (widget.inherit && _GlassInputScope.maybeOf(context) != null) {
      return widget.child;
    }
    final enabled =
        widget.enabled &&
        const bool.fromEnvironment('GLASS_BATCH', defaultValue: true);
    final scope = _GlassInputScope(
      group: enabled ? _group : null,
      child: widget.child,
    );
    return NativeEffects.easyGlass
        ? LiquidGlassBatch(enabled: enabled, child: scope)
        : scope;
  }

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }
}

class _GlassInputScope extends InheritedWidget {
  const _GlassInputScope({required this.group, required super.child});
  final _GlassInputGroup? group;
  static _GlassInputScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassInputScope>();

  @override
  bool updateShouldNotify(_GlassInputScope oldWidget) =>
      group != oldWidget.group;
}

/// Only the pinned, non-overlapping scroll edges share this snapshot. Their
/// source (the page) is complete before either edge paints. Glass controls keep
/// their own group so they still refract the already-blurred header underneath.
class NativeScrollEdgeGroup extends StatefulWidget {
  const NativeScrollEdgeGroup({
    super.key,
    required this.child,
    this.enabled = true,
  });
  final Widget child;
  final bool enabled;
  @override
  State<NativeScrollEdgeGroup> createState() => _NativeScrollEdgeGroupState();
}

class _NativeScrollEdgeGroupState extends State<NativeScrollEdgeGroup> {
  final _group = _GlassInputGroup();
  @override
  Widget build(BuildContext context) =>
      _ScrollEdgeInputScope.maybeOf(context) != null
      ? widget.child
      : _ScrollEdgeInputScope(
          group:
              widget.enabled &&
                  const bool.fromEnvironment(
                    'SCROLL_EDGE_BATCH',
                    defaultValue: true,
                  )
              ? _group
              : null,
          child: widget.child,
        );
  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }
}

class _ScrollEdgeInputScope extends InheritedWidget {
  const _ScrollEdgeInputScope({required this.group, required super.child});
  final _GlassInputGroup? group;
  static _ScrollEdgeInputScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScrollEdgeInputScope>();
  @override
  bool updateShouldNotify(_ScrollEdgeInputScope oldWidget) =>
      group != oldWidget.group;
}

/// Optical properties follow a menu's growth at scene composition time.
/// The first frame uses the originating control, not an already frosted panel.
class NativeGlassMorph {
  const NativeGlassMorph({
    required this.animation,
    required this.radius,
    required this.thickness,
    required this.blur,
  });
  final Animation<double> animation;
  final double radius;
  final double thickness;
  final double blur;

  double get progress =>
      Curves.easeOutCubic.transform(animation.value.clamp(0.0, 1.0));
  double resolve(double source, double target) =>
      ui.lerpDouble(source, target, progress)!;
}

class NativeBackdrop extends StatefulWidget {
  const NativeBackdrop({
    super.key,
    required this.effect,
    required this.child,
    this.blur = 0,
    this.plateau = 0,
    this.fromBottom = false,
    this.radius = 28,
    this.thickness = 20,
    this.refractiveIndex = 1.45,
    this.tint = const ui.Color(0x00000000),
    this.activation = 0,
    this.touchPosition = .5,
    this.emission = 0,
    this.preserveOptics = false,
    this.morph,
    this.cullUnusedPixels = true,
    this.tightSampling = true,
    this.bypass = false,
    this.optimizedSampling = true,
    this.nativeEdgeBlur = true,
  });

  final NativeEffect effect;
  final Widget child;
  final double blur;
  final double plateau;
  final bool fromBottom;
  final double radius;
  final double thickness;
  final double refractiveIndex;
  final ui.Color tint;
  final double activation;
  final double touchPosition;
  final double emission;

  /// A menu stretches its bounds, not its physical meniscus/blur thickness.
  final bool preserveOptics;
  final NativeGlassMorph? morph;

  /// Disable dead-output culling for pixel and Profile comparisons.
  final bool cullUnusedPixels;

  /// Keep the legacy wide halo for native pixel/Profile comparisons.
  final bool tightSampling;

  /// A live settings preview paints only its child, without a backdrop pass.
  final bool bypass;

  /// Retains the reference kernel for native pixel-parity checks.
  final bool optimizedSampling;

  /// Keep the previous continuous-radius solver available for A/B diagnosis.
  /// The default preserves live blur and a smooth feather using the GPU's
  /// native Gaussian/downsample path instead of repeated runtime convolution.
  final bool nativeEdgeBlur;
  bool get _nativeEdge =>
      effect == NativeEffect.progressive &&
      nativeEdgeBlur &&
      const bool.fromEnvironment('NATIVE_SCROLL_EDGE_BLUR', defaultValue: true);

  NativeBackdrop withoutBlur() => NativeBackdrop(
    effect: effect,
    plateau: plateau,
    fromBottom: fromBottom,
    radius: radius,
    thickness: thickness,
    refractiveIndex: refractiveIndex,
    tint: tint,
    activation: activation,
    touchPosition: touchPosition,
    emission: emission,
    preserveOptics: preserveOptics,
    morph: morph == null
        ? null
        : NativeGlassMorph(
            animation: morph!.animation,
            radius: morph!.radius,
            thickness: morph!.thickness,
            blur: 0,
          ),
    cullUnusedPixels: cullUnusedPixels,
    tightSampling: tightSampling,
    bypass: bypass,
    optimizedSampling: optimizedSampling,
    nativeEdgeBlur: nativeEdgeBlur,
    child: child,
  );

  @override
  State<NativeBackdrop> createState() => _NativeBackdropState();
}

class _NativeBackdropState extends State<NativeBackdrop> {
  bool _preparing = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preferences = PerformanceScope.of(context);
    final needsRuntime = widget.effect == NativeEffect.progressive
        ? preferences.edgeBlur && widget.blur > 0
        : preferences.glass && widget.thickness > 0;
    if (needsRuntime &&
        !_preparing &&
        ui.ImageFilter.isShaderFilterSupported &&
        NativeEffects._glass == null) {
      _preparing = true;
      NativeEffects.prepare().then(
        (_) {
          if (mounted) setState(() {});
        },
        onError: (Object _) {
          // Keep the bounded native blur fallback if a GPU cannot load shaders.
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bypass) return widget.child;
    final preferences = PerformanceScope.of(context);
    if (widget.effect == NativeEffect.progressive && !preferences.edgeBlur) {
      return widget.child;
    }
    if (widget.effect == NativeEffect.glass && !preferences.glass) {
      return _lightweightGlass(preferences.blur);
    }
    final config = widget.effect == NativeEffect.glass && !preferences.blur
        ? widget.withoutBlur()
        : widget;
    return _buildEffect(context, config);
  }

  Widget _lightweightGlass(bool blurEnabled) {
    Widget buildSurface() {
      final sigma = blurEnabled
          ? widget.morph?.resolve(widget.morph!.blur, widget.blur) ??
                widget.blur
          : 0.0;
      final surface = Theme.of(context).colorScheme.surface;
      final tint = ui.Color.alphaBlend(
        widget.tint,
        surface.withValues(alpha: sigma > 0 ? .72 : .96),
      );
      Widget content = ColoredBox(color: tint, child: widget.child);
      if (sigma > 0) {
        content = BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: content,
        );
      }
      return widget.morph == null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(widget.radius),
              child: content,
            )
          : ClipRRect(
              clipper: _MorphGlassClipper(widget, context),
              child: content,
            );
    }

    return widget.morph == null
        ? buildSurface()
        : AnimatedBuilder(
            animation: widget.morph!.animation,
            builder: (context, _) => buildSurface(),
          );
  }

  Widget _buildEffect(BuildContext context, NativeBackdrop config) {
    if (config.effect == NativeEffect.progressive && config.blur <= 0) {
      return widget.child;
    }
    if (config._nativeEdge) {
      return EasyScrollEdge(
        blur: config.blur,
        plateau: config.plateau,
        fromBottom: config.fromBottom,
        child: config.child,
      );
    }
    if (config.effect == NativeEffect.glass && config.thickness <= 0) {
      if (widget.morph != null) {
        return AnimatedBuilder(
          animation: widget.morph!.animation,
          child: ColoredBox(color: widget.tint, child: widget.child),
          builder: (context, child) => ClipRRect(
            clipper: _MorphGlassClipper(widget, context),
            child: child,
          ),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: ColoredBox(color: widget.tint, child: widget.child),
      );
    }
    if (config.effect == NativeEffect.glass && NativeEffects.easyGlass) {
      Widget surface() {
        final morph = config.morph;
        final surface = EasyGlassSurface(
          radius: morph?.resolve(morph.radius, config.radius) ?? config.radius,
          thickness:
              morph?.resolve(morph.thickness, config.thickness) ??
              config.thickness,
          blur: morph?.resolve(morph.blur, config.blur) ?? config.blur,
          refractiveIndex: config.refractiveIndex,
          tint: config.tint,
          emission: config.emission,
          activation: config.activation,
          independent:
              config.preserveOptics || morph != null || config.activation > 0,
          physicalOptics: config.preserveOptics,
          child: config.child,
        );
        return config.preserveOptics
            ? ClipRRect(
                clipper: _MorphGlassClipper(config, context),
                child: surface,
              )
            : surface;
      }

      return config.morph == null
          ? surface()
          : AnimatedBuilder(
              animation: config.morph!.animation,
              builder: (context, _) => surface(),
            );
    }
    final program = config.effect == NativeEffect.progressive
        ? NativeEffects._progressive
        : NativeEffects._glass;
    if (program == null) {
      final morph = config.morph;
      if (widget.effect == NativeEffect.glass && morph != null) {
        return AnimatedBuilder(
          animation: morph.animation,
          child: widget.child,
          builder: (context, child) {
            final blur = morph.resolve(morph.blur, config.blur);
            return ClipRRect(
              clipper: _MorphGlassClipper(widget, context),
              child: DecoratedBox(
                decoration: BoxDecoration(color: widget.tint),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      if (widget.emission > 0)
                        Positioned.fill(
                          child: ColoredBox(
                            color: const ui.Color(
                              0xFFFFFFFF,
                            ).withValues(alpha: widget.emission),
                          ),
                        ),
                      child!,
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }
      final backdrop = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: config.blur, sigmaY: config.blur),
        child: widget.child,
      );
      if (widget.effect == NativeEffect.glass) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: DecoratedBox(
            decoration: BoxDecoration(color: widget.tint),
            child: widget.emission <= 0
                ? backdrop
                : BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: config.blur,
                      sigmaY: config.blur,
                    ),
                    child: Stack(
                      fit: StackFit.passthrough,
                      children: [
                        Positioned.fill(
                          child: ColoredBox(
                            color: const ui.Color(
                              0xFFFFFFFF,
                            ).withValues(alpha: widget.emission),
                          ),
                        ),
                        widget.child,
                      ],
                    ),
                  ),
          ),
        );
      }
      // Other renderers have a smooth fallback too, never disjoint bands.
      return ClipRect(
        child: ShaderMask(
          blendMode: ui.BlendMode.dstIn,
          shaderCallback: (rect) => ui.Gradient.linear(
            widget.fromBottom ? rect.bottomCenter : rect.topCenter,
            widget.fromBottom ? rect.topCenter : rect.bottomCenter,
            const [
              ui.Color(0xFFFFFFFF),
              ui.Color(0xFFFFFFFF),
              ui.Color(0x00FFFFFF),
            ],
            [0, (widget.plateau / rect.height).clamp(0.0, 1.0), 1],
          ),
          child: backdrop,
        ),
      );
    }
    return _NativeBackdropWidget(
      key: ValueKey(widget.effect),
      config: config,
      program: program,
      dpr: MediaQuery.devicePixelRatioOf(context),
      viewport: View.of(context).physicalSize,
      group: config.effect == NativeEffect.progressive
          ? _ScrollEdgeInputScope.maybeOf(context)?.group
          : _GlassInputScope.maybeOf(context)?.group,
      child: widget.child,
    );
  }
}

/// Keep a physical circular source on non-runtime-filter renderers as well.
/// A local circular radius would become an ellipse under the menu transform.
class _MorphGlassClipper extends CustomClipper<ui.RRect> {
  _MorphGlassClipper(this.config, this.context);
  final NativeBackdrop config;
  final BuildContext context;

  @override
  ui.RRect getClip(ui.Size size) {
    final box = context.findRenderObject()! as RenderBox;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      ui.Offset.zero & size,
    );
    final radius = math.min(
      config.morph?.resolve(config.morph!.radius, config.radius) ??
          config.radius,
      rect.shortestSide / 2,
    );
    return ui.RRect.fromRectAndRadius(
      ui.Offset.zero & size,
      ui.Radius.elliptical(
        radius * size.width / rect.width,
        radius * size.height / rect.height,
      ),
    );
  }

  @override
  bool shouldReclip(covariant _MorphGlassClipper oldClipper) => true;
}

class _NativeBackdropWidget extends SingleChildRenderObjectWidget {
  const _NativeBackdropWidget({
    super.key,
    required this.config,
    required this.program,
    required this.dpr,
    required this.viewport,
    required this.group,
    required super.child,
  });

  final NativeBackdrop config;
  final ui.FragmentProgram program;
  final double dpr;
  final ui.Size viewport;
  final _GlassInputGroup? group;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _NativeBackdropRender(config, dpr, viewport, program, group);

  @override
  void updateRenderObject(BuildContext context, _NativeBackdropRender render) {
    render.update(config, dpr, viewport, group);
  }
}

class _NativeBackdropRender extends RenderProxyBox {
  _NativeBackdropRender(
    this.config,
    this.dpr,
    this.viewport,
    ui.FragmentProgram program,
    this.group,
  ) : first = program.fragmentShader(),
      second = config.effect == NativeEffect.progressive
          ? program.fragmentShader()
          : null {
    for (final shader in [
      if (config.effect == NativeEffect.progressive) first,
      ?second,
    ]) {
      shader.setImageSampler(1, NativeEffects._srgbLut!);
    }
  }

  NativeBackdrop config;
  double dpr;
  ui.Size viewport;
  _GlassInputGroup? group;
  final ui.FragmentShader first;
  final ui.FragmentShader? second;
  ui.FragmentShader? _prefilterHorizontal;
  ui.FragmentShader? _prefilterVertical;
  // Clear controls and native Gaussian panels never allocate unused runtime
  // convolution programs. Reuse each shader once its path actually needs it.
  ui.FragmentShader get prefilterHorizontal =>
      _prefilterHorizontal ??= NativeEffects._progressive!.fragmentShader()
        ..setImageSampler(1, NativeEffects._srgbLut!);
  ui.FragmentShader get prefilterVertical =>
      _prefilterVertical ??= NativeEffects._progressive!.fragmentShader()
        ..setImageSampler(1, NativeEffects._srgbLut!);
  ui.FragmentShader? _denseHorizontal;
  ui.FragmentShader? _denseVertical;
  int _debugPixelCulling = 0;
  final _effectLayer = LayerHandle<_NativeBackdropLayer>();
  final _clipLayer = LayerHandle<ClipRectLayer>();
  ui.ImageFilter? _cachedFilter;
  ui.Rect? _filterBounds;
  double? _filterMorphProgress;
  int _debugFilterBuildCount = 0;
  int _debugFilterReuseCount = 0;

  int get debugFilterBuildCount => _debugFilterBuildCount;
  int get debugFilterReuseCount => _debugFilterReuseCount;
  int get debugPixelCulling => _debugPixelCulling;
  bool get debugUsesSharedGlass => _effectLayer.layer?.backdropKey != null;
  Object? get debugSharedGlassKey => _effectLayer.layer?.backdropKey;
  int get debugShaderCount =>
      1 +
      (second == null ? 0 : 1) +
      (_prefilterHorizontal == null ? 0 : 1) +
      (_prefilterVertical == null ? 0 : 1) +
      (_denseHorizontal == null ? 0 : 1) +
      (_denseVertical == null ? 0 : 1);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    group?.add(this);
  }

  @override
  void detach() {
    group?.remove(this);
    super.detach();
  }

  void update(
    NativeBackdrop value,
    double ratio,
    ui.Size viewSize,
    _GlassInputGroup? nextGroup,
  ) {
    if (group != nextGroup) {
      if (attached) group?.remove(this);
      group = nextGroup;
      if (attached) group?.add(this);
      markNeedsPaint();
    }
    final changed =
        dpr != ratio ||
        viewport != viewSize ||
        config.effect != value.effect ||
        config.blur != value.blur ||
        config.plateau != value.plateau ||
        config.fromBottom != value.fromBottom ||
        config.radius != value.radius ||
        config.thickness != value.thickness ||
        config.refractiveIndex != value.refractiveIndex ||
        config.tint != value.tint ||
        config.activation != value.activation ||
        config.touchPosition != value.touchPosition ||
        config.emission != value.emission;
    final opticsChanged =
        config.preserveOptics != value.preserveOptics ||
        config.morph != value.morph ||
        config.cullUnusedPixels != value.cullUnusedPixels ||
        config.tightSampling != value.tightSampling ||
        config.optimizedSampling != value.optimizedSampling;
    config = value;
    dpr = ratio;
    viewport = viewSize;
    if (changed || opticsChanged) {
      _cachedFilter = null;
      group?.invalidate();
      markNeedsPaint();
    }
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    _clipLayer.layer = context.pushClipRect(true, offset, Offset.zero & size, (
      context,
      offset,
    ) {
      final layer = _effectLayer.layer ??= _NativeBackdropLayer(this);
      context.pushLayer(layer, super.paint, offset);
    }, oldLayer: _clipLayer.layer);
  }

  ui.ImageFilter filter() {
    // Resolve at scene composition, not widget build. Retained layers can move
    // during a route/selection animation without repainting their contents.
    final rect = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    final physical = ui.Rect.fromLTRB(
      rect.left * dpr,
      rect.top * dpr,
      rect.right * dpr,
      rect.bottom * dpr,
    );
    final morph = config.morph;
    final morphProgress = morph?.progress;
    final radius = morph?.resolve(morph.radius, config.radius) ?? config.radius;
    final thickness =
        morph?.resolve(morph.thickness, config.thickness) ?? config.thickness;
    final blur = morph?.resolve(morph.blur, config.blur) ?? config.blur;
    // Scrolling changes the backdrop pixels, not a pinned header's uniforms.
    // Reuse its filter graph; the layer still samples the live scene each frame.
    // A moving/deforming glass plane or changed material invalidates the graph.
    if (_cachedFilter != null &&
        _filterBounds == physical &&
        _filterMorphProgress == morphProgress) {
      assert(() {
        _debugFilterReuseCount++;
        return true;
      }());
      return _cachedFilter!;
    }
    assert(() {
      _debugFilterBuildCount++;
      return true;
    }());
    ui.ImageFilter remember(ui.ImageFilter filter) {
      _filterBounds = physical;
      _filterMorphProgress = morphProgress;
      return _cachedFilter = filter;
    }

    final scale = config.preserveOptics ? dpr : physical.height / size.height;
    final cull =
        config.cullUnusedPixels &&
        const bool.fromEnvironment(
          'GLASS_CULL_UNUSED_PIXELS',
          defaultValue: true,
        );
    assert(() {
      _debugPixelCulling = cull ? 1 : 0;
      return true;
    }());
    void bounds(ui.FragmentShader shader) {
      shader
        ..setFloat(2, physical.left)
        ..setFloat(3, physical.top)
        ..setFloat(4, physical.width)
        ..setFloat(5, physical.height);
    }

    bounds(first);
    final optimized =
        config.optimizedSampling &&
        const bool.fromEnvironment(
          'GLASS_OPTIMIZED_SHADER',
          defaultValue: true,
        );
    if (config.effect == NativeEffect.glass) {
      void optics(ui.FragmentShader shader) {
        bounds(shader);
        shader
          ..setFloat(6, radius * scale)
          ..setFloat(7, thickness * scale)
          ..setFloat(8, config.refractiveIndex)
          ..setFloat(9, config.tint.r)
          ..setFloat(10, config.tint.g)
          ..setFloat(11, config.tint.b)
          ..setFloat(12, config.tint.a)
          ..setFloat(13, config.activation.clamp(0, 1))
          ..setFloat(14, config.touchPosition.clamp(0, 1))
          ..setFloat(15, config.emission.clamp(0, .05))
          ..setFloat(16, optimized ? 1 : 0);
      }

      optics(first);
      final glass = ui.ImageFilter.shader(first);
      // The clear, lightweight control material needs only the refraction
      // pass. Do not prepare convolution uniforms or a sampling halo here.
      if (blur <= 0) return remember(glass);
      // Menus/sheets need stronger source softening than small navigation
      // controls. Seed wide kernels densely so letters never reappear as
      // sparse-tap copies behind the overlay's own labels.
      // Ramp in the dense seed continuously; crossing sigma=3 must not
      // introduce a sudden change in the backdrop during a material morph.
      final dense = math.min(3.0, math.max(0.0, blur - 3)) * scale;
      final maximum = blur * scale;
      final residual = math.sqrt(
        math.max(0, maximum * maximum - dense * dense),
      );
      final opticalHalo = thickness * scale * 4 + 2;
      final padding =
          config.tightSampling &&
              const bool.fromEnvironment(
                'GLASS_TIGHT_SAMPLING',
                defaultValue: true,
              ) &&
              config.activation == 0 &&
              morph == null &&
              config.blur <= 3
          ? glassSamplingHalo(
              size: physical.size,
              radius: radius * scale,
              thickness: thickness * scale,
              refractiveIndex: config.refractiveIndex,
            )
          : ui.Offset(opticalHalo, opticalHalo);
      void uniformBlur(
        ui.FragmentShader shader,
        double axis,
        double sigma,
        double paddingX,
        double paddingY,
      ) {
        bounds(shader);
        shader
          ..setFloat(6, 0)
          ..setFloat(7, 0)
          ..setFloat(8, 0)
          ..setFloat(9, axis)
          ..setFloat(10, sigma)
          ..setFloat(11, 0)
          ..setFloat(12, viewport.width)
          ..setFloat(13, viewport.height)
          ..setFloat(14, paddingX)
          ..setFloat(15, paddingY);
        // Cull only pixels outside every downstream sampling dependency.
        // Preserve all offsets, accumulation order and both intermediates.
        shader.setFloat(16, cull ? 1 : 0);
        shader.setFloat(17, optimized ? 1 : 0);
      }

      // Keep the established clear-core optics for navigation/controls. Broad
      // overlay softening uses Impeller's optimized, downsampled Gaussian path.
      if (const bool.fromEnvironment('GLASS_NATIVE_BLUR', defaultValue: true) &&
          config.blur > 3) {
        // A menu starts with the exact original small-control kernel. Reduce
        // that seed continuously while growing the native kernel, rather than
        // changing color space/kernel abruptly when resolved blur crosses 3dp.
        final sourceBlur = morph != null && morph.blur > 0 && morph.blur <= 3
            ? morph.blur
            : 0.0;
        final handoff = sourceBlur <= 0
            ? 1.0
            : ((blur - sourceBlur) / math.max(1.0, 3 - sourceBlur)).clamp(
                0.0,
                1.0,
              );
        final seed = sourceBlur * (1 - Curves.easeOutCubic.transform(handoff));
        final nativeSigma =
            math.sqrt(math.max(0.0, blur * blur - seed * seed)) * scale;
        ui.ImageFilter? softened;
        if (seed > 0) {
          for (final (shader, axis) in [
            (prefilterHorizontal, 0.0),
            (prefilterVertical, 1.0),
          ]) {
            uniformBlur(
              shader,
              axis,
              seed * scale,
              opticalHalo + 3 * nativeSigma,
              opticalHalo +
                  3 * nativeSigma +
                  (axis == 0 ? 3 * seed * scale : 0),
            );
          }
          softened = ui.ImageFilter.compose(
            outer: ui.ImageFilter.shader(prefilterVertical),
            inner: ui.ImageFilter.shader(prefilterHorizontal),
          );
        }
        if (nativeSigma > 0) {
          final native = ui.ImageFilter.blur(
            sigmaX: nativeSigma,
            sigmaY: nativeSigma,
            tileMode: ui.TileMode.clamp,
          );
          softened = softened == null
              ? native
              : ui.ImageFilter.compose(outer: native, inner: softened);
        }
        return remember(
          softened == null
              ? glass
              : ui.ImageFilter.compose(outer: glass, inner: softened),
        );
      }

      // Keep the input coordinate system unchanged. Composing native blur with
      // a runtime filter can shift its intermediate texture bounds.
      for (final (shader, axis) in [
        (prefilterHorizontal, 0.0),
        (prefilterVertical, 1.0),
      ]) {
        uniformBlur(
          shader,
          axis,
          residual,
          padding.dx,
          padding.dy + (axis == 0 ? 3 * residual : 0),
        );
      }
      var softened = ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(prefilterVertical),
        inner: ui.ImageFilter.shader(prefilterHorizontal),
      );
      if (dense > 0) {
        if (_denseHorizontal == null) {
          _denseHorizontal = NativeEffects._progressive!.fragmentShader()
            ..setImageSampler(1, NativeEffects._srgbLut!);
          _denseVertical = NativeEffects._progressive!.fragmentShader()
            ..setImageSampler(1, NativeEffects._srgbLut!);
        }
        for (final (shader, axis) in [
          (_denseHorizontal!, 0.0),
          (_denseVertical!, 1.0),
        ]) {
          uniformBlur(
            shader,
            axis,
            dense,
            opticalHalo + 3 * residual,
            opticalHalo + 3 * residual + (axis == 0 ? 3 * dense : 0),
          );
        }
        softened = ui.ImageFilter.compose(
          outer: softened,
          inner: ui.ImageFilter.compose(
            outer: ui.ImageFilter.shader(_denseVertical!),
            inner: ui.ImageFilter.shader(_denseHorizontal!),
          ),
        );
      }
      return remember(ui.ImageFilter.compose(outer: glass, inner: softened));
    }
    // Small underlays already have dense taps; they need no extra prefilter.
    final prefilter = config.blur <= 3 ? 0.0 : 3 * scale;
    final maximum = config.blur * scale;
    final residual = (maximum * maximum - prefilter * prefilter).clamp(
      0.0,
      double.infinity,
    );
    final halo = 3 * math.sqrt(residual);
    for (final (shader, axis, stage) in [
      if (prefilter > 0) ...[
        (prefilterHorizontal, 0.0, 0.0),
        (prefilterVertical, 1.0, 0.0),
      ],
      (first, 0.0, 1.0),
      (second!, 1.0, 1.0),
    ]) {
      bounds(shader);
      shader
        ..setFloat(6, config.blur * scale)
        ..setFloat(7, config.plateau * scale)
        ..setFloat(8, config.fromBottom ? 1 : 0)
        ..setFloat(9, axis)
        ..setFloat(10, prefilter)
        ..setFloat(11, stage)
        ..setFloat(12, viewport.width)
        ..setFloat(13, viewport.height)
        ..setFloat(14, stage == 0 ? halo + 2 : 2)
        ..setFloat(
          15,
          stage == 0
              ? halo + (axis == 0 ? 3 * prefilter : 0) + 2
              : (axis == 0 ? halo : 0) + 2,
        )
        ..setFloat(16, cull ? 1 : 0)
        ..setFloat(17, optimized ? 1 : 0);
    }
    // Average linear light inside each pass, but store its result in sRGB.
    // Storing dark linear values in an 8-bit intermediate texture causes
    // visible tonal steps. The dense prefilter also prevents sparse-tap copies.
    final continuous = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(second!),
      inner: ui.ImageFilter.shader(first),
    );
    if (prefilter == 0) return remember(continuous);
    return remember(
      ui.ImageFilter.compose(
        outer: continuous,
        inner: ui.ImageFilter.compose(
          outer: ui.ImageFilter.shader(prefilterVertical),
          inner: ui.ImageFilter.shader(prefilterHorizontal),
        ),
      ),
    );
  }

  @override
  void dispose() {
    group?.remove(this);
    _effectLayer.layer = null;
    _clipLayer.layer = null;
    _cachedFilter = null;
    first.dispose();
    second?.dispose();
    _prefilterHorizontal?.dispose();
    _prefilterVertical?.dispose();
    _denseHorizontal?.dispose();
    _denseVertical?.dispose();
    super.dispose();
  }
}

class _GlassInputGroup {
  final _members = <_NativeBackdropRender>{};
  final _eligible = <_NativeBackdropRender>{};
  final _key = BackdropKey();
  ui.SceneBuilder? _scene;

  void add(_NativeBackdropRender render) {
    _members.add(render);
    invalidate();
  }

  void remove(_NativeBackdropRender render) {
    _members.remove(render);
    _eligible.remove(render);
    invalidate();
  }

  void invalidate() => _scene = null;

  BackdropKey? keyFor(_NativeBackdropRender render, ui.SceneBuilder scene) {
    if (!identical(_scene, scene)) {
      _scene = scene;
      _eligible.clear();
      final planes = <_NativeBackdropRender, ui.Rect>{};
      for (final member in _members) {
        final config = member.config;
        if (!member.attached ||
            !member.hasSize ||
            member.size.isEmpty ||
            config.effect != render.config.effect ||
            (config.effect == NativeEffect.glass && config.thickness <= 0) ||
            config.morph != null ||
            (config.effect == NativeEffect.glass && config.blur > 3)) {
          continue;
        }
        var visible = true;
        for (
          RenderObject? ancestor = member.parent;
          ancestor != null;
          ancestor = ancestor.parent
        ) {
          if (ancestor is RenderOffstage && ancestor.offstage ||
              ancestor is RenderOpacity && ancestor.opacity != 1 ||
              ancestor is RenderAnimatedOpacity &&
                  ancestor.opacity.value != 1) {
            visible = false;
            break;
          }
        }
        if (!visible) continue;
        final transform = member.getTransformTo(null);
        if (transform.storage[1].abs() > .000001 ||
            transform.storage[4].abs() > .000001 ||
            transform.storage[3].abs() > .000001 ||
            transform.storage[7].abs() > .000001) {
          continue;
        }
        final rect = MatrixUtils.transformRect(
          transform,
          Offset.zero & member.size,
        );
        if (!rect.overlaps(Offset.zero & (member.viewport / member.dpr))) {
          continue;
        }
        planes[member] = rect;
      }
      final members = planes.keys.toList(growable: false);
      for (var i = 0; i < members.length; i++) {
        var overlaps = false;
        for (var j = 0; j < members.length; j++) {
          if (i != j && planes[members[i]]!.overlaps(planes[members[j]]!)) {
            overlaps = true;
            break;
          }
        }
        if (!overlaps) _eligible.add(members[i]);
      }
    }
    return _eligible.length >= 2 && _eligible.contains(render) ? _key : null;
  }

  void dispose() {
    _members.clear();
    _eligible.clear();
    _scene = null;
  }
}

class _NativeBackdropLayer extends BackdropFilterLayer {
  _NativeBackdropLayer(this.render)
    : super(filter: ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0));
  final _NativeBackdropRender render;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void markNeedsAddToScene() {
    // Composition is already unconditional, including retained transforms.
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    filter = render.filter();
    backdropKey = render.group?.keyFor(render, builder);
    super.addToScene(builder);
  }
}
