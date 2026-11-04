import 'dart:async';
import 'dart:math' as math;
import 'library_reflow.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'archive_design.dart';
import 'archive_icons.dart';
import 'app_haptics.dart';
import 'app_window_insets.dart';
import 'catalog.dart';
import 'cover_arrival.dart';
import 'glass_optics.dart';
import 'glass_palette.dart';
import 'app_palette.dart';
import 'glass_controls.dart';
import 'app_language.dart';
export 'app_language.dart';
import 'legacy_cover.dart';
import 'loading_ui.dart';
import 'motion_ui.dart';
import 'native_effects.dart';
import 'performance_preferences.dart';
import 'scroll_edge_blur.dart';
import 'route_identity.dart';
import 'dock_layout.dart';
import 'control_material_scope.dart';

export 'scroll_edge_blur.dart' show ProgressiveBlur, ScrollEdgeProfile;
export 'loading_ui.dart';
export 'motion_ui.dart';
export 'archive_design.dart';
export 'archive_icons.dart';
export 'app_haptics.dart';
export 'glass_controls.dart';
export 'control_material_scope.dart';

const ink = Color(0xFF181818);
const accent = Color(0xFF202020);
const canvas = ArchiveDesign.background;
const hairline = Color(0xFFD8DBD5);

Future<T?> showDialogWithControllers<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required List<ChangeNotifier> controllers,
}) => showDialog<T>(
  context: context,
  builder: (context) => _DialogControllerLifetime(
    controllers: controllers,
    child: builder(context),
  ),
);

class _DialogControllerLifetime extends StatefulWidget {
  const _DialogControllerLifetime({
    required this.controllers,
    required this.child,
  });
  final List<ChangeNotifier> controllers;
  final Widget child;

  @override
  State<_DialogControllerLifetime> createState() =>
      _DialogControllerLifetimeState();
}

class _DialogControllerLifetimeState extends State<_DialogControllerLifetime> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Live appearance values are shared by controls, navigation and scroll edges.
class GlassAppearance extends InheritedWidget {
  const GlassAppearance({
    super.key,
    required super.child,
    this.blur = 8,
    this.opacity = .87,
  });

  final double blur;
  final double opacity;

  static GlassAppearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassAppearance>() ??
      const GlassAppearance(child: SizedBox.shrink());

  static Color tintOf(BuildContext context, {required double opacity}) =>
      Theme.of(context).extension<GlassPalette>()?.tint ??
      Theme.of(context).extension<AppTonalColors>()?.tint(
        Theme.of(context).brightness,
        opacity,
      ) ??
      ArchiveDesign.glassTint(Theme.of(context).brightness, opacity: opacity);

  @override
  bool updateShouldNotify(GlassAppearance oldWidget) =>
      blur != oldWidget.blur || opacity != oldWidget.opacity;
}

/// System icons follow the app's resolved theme, including a manual theme
/// choice that differs from Android's setting. Page backgrounds paint below
/// transparent bars; SafeArea only insets interactive/readable content.
SystemUiOverlayStyle novelSystemUiStyle(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: brightness,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  );
}

ThemeData novelTheme(
  Brightness brightness, {
  String? fontFamily,
  List<String>? fontFamilyFallback,
  AppPalettePreferences palette = const AppPalettePreferences(),
  SystemTonalColors? systemColors,
}) {
  final dark = brightness == Brightness.dark;
  final original =
      palette.source == AppPaletteSource.original ||
      palette.source == AppPaletteSource.system && systemColors == null;
  late final baseScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    primary: dark ? Colors.white : ink,
    onPrimary: dark ? ink : Colors.white,
    surface: dark ? ArchiveDesign.darkSurface : ArchiveDesign.surface,
    onSurface: dark ? ArchiveDesign.darkInk : ink,
    onSurfaceVariant: dark ? ArchiveDesign.darkMuted : const Color(0xFF646B62),
  );
  late final classicScheme = dark
      ? baseScheme.copyWith(
          surfaceDim: ArchiveDesign.darkBackground,
          surfaceBright: ArchiveDesign.darkRaisedHigh,
          surfaceContainerLowest: ArchiveDesign.darkBackground,
          surfaceContainerLow: ArchiveDesign.darkSurface,
          surfaceContainer: ArchiveDesign.darkRaised,
          surfaceContainerHigh: const Color(0xFF333333),
          surfaceContainerHighest: ArchiveDesign.darkRaisedHigh,
          outline: const Color(0xFF7A7A7A),
          outlineVariant: ArchiveDesign.darkOutline,
          surfaceTint: Colors.transparent,
        )
      : baseScheme;
  final scheme = original
      ? classicScheme
      : palette.source == AppPaletteSource.system
      ? systemColors!.scheme(brightness)
      : ColorScheme.fromSeed(
          seedColor: palette.color,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
        ).copyWith(surfaceTint: Colors.transparent);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: original
        ? (dark ? ArchiveDesign.darkBackground : canvas)
        : scheme.surface,
    extensions: [AppTonalColors.forScheme(scheme, original: original)],
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: scheme.primary,
      primaryContrastingColor: scheme.onPrimary,
      scaffoldBackgroundColor: scheme.surface,
    ),
    splashFactory: InkRipple.splashFactory,
    textTheme: ThemeData(brightness: brightness).textTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      bodyColor: original ? (dark ? Colors.white : ink) : scheme.onSurface,
      displayColor: original ? (dark ? Colors.white : ink) : scheme.onSurface,
    ),
    dividerColor: original
        ? (dark ? const Color(0xFF353C35) : hairline)
        : scheme.outlineVariant,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
        borderSide: BorderSide(
          color: original
              ? (dark ? const Color(0xFF353C35) : hairline)
              : scheme.outlineVariant,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface, height: 1.5),
      actionTextColor: scheme.onInverseSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
      ),
    ),
  );
}

/// The package's controls share the app's milk/stone palette and optics.
abstract final class AppControls {
  static Color _accent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (MediaQuery.highContrastOf(context)) return const Color(0xFF747474);
    if (Theme.of(context).extension<AppTonalColors>() case final colors?) {
      return colors.active;
    }
    return Color.lerp(
      scheme.onSurface,
      scheme.surface,
      scheme.brightness == Brightness.dark ? .46 : .48,
    )!;
  }

  static Color _track(BuildContext context) {
    if (Theme.of(context).extension<AppTonalColors>() case final colors?) {
      return colors.track;
    }
    final scheme = Theme.of(context).colorScheme;
    return Color.lerp(
      scheme.surface,
      scheme.onSurface,
      scheme.brightness == Brightness.dark ? .16 : .10,
    )!;
  }

  static easy.LiquidGlassStyle _material(
    BuildContext context, {
    bool plate = false,
  }) {
    final appearance = GlassAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    return easy.LiquidGlassStyle(
      shape: const easy.LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 100,
      ),
      specular: const easy.LiquidGlassLight.specular(
        intensity: 0,
        thickness: 0,
      ),
      glow: const easy.LiquidGlassLight.glow(intensity: 0, thickness: 0),
      refractionIndex: 1.03,
      refractionWidth: plate ? 16 : 8,
      dispersion: 0,
      blur: 0,
      color: GlassAppearance.tintOf(context, opacity: appearance.opacity)
          .withValues(
            alpha: highContrast
                ? 1
                : plate
                ? appearance.opacity
                : .10,
          ),
      shadow: plate
          ? null
          : const easy.LiquidGlassShadow(blur: 6, opacity: .12, inset: 3),
      liteGlass: !PerformanceScope.of(context).glass || highContrast,
    );
  }

  static AppGlassSwitch toggle(
    BuildContext context, {
    Key? key,
    required bool value,
    required FutureOr<void> Function(bool)? onChanged,
    bool haptics = true,
  }) {
    return AppGlassSwitch(
      key: key,
      value: value,
      onChanged: onChanged,
      haptics: haptics,
      activeColor: _accent(context),
      inactiveColor: _track(context),
      thumbColor:
          Theme.of(context).extension<GlassPalette>()?.thumb ??
          ArchiveDesign.milk,
      style: _material(context),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  static AppGlassSlider slider(
    BuildContext context, {
    Key? key,
    required double value,
    required ValueChanged<double>? onChanged,
    double min = 0,
    double max = 1,
    int? divisions,
    bool haptics = true,
    bool compact = false,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
  }) {
    return AppGlassSlider(
      key: key,
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      haptics: haptics,
      compact: compact,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      activeColor: _accent(context),
      inactiveColor: _track(context),
      thumbColor:
          Theme.of(context).extension<GlassPalette>()?.thumb ??
          ArchiveDesign.milk,
      style: _material(context),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  static Widget segments<T extends Object>(
    BuildContext context, {
    Key? key,
    required T? groupValue,
    required Map<T, Widget> children,
    required ValueChanged<T?> onValueChanged,
    Set<T> disabledChildren = const {},
    bool haptics = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTextStyle.merge(
      style: TextStyle(
        color: scheme.onSurface,
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w500,
      ),
      child: AppGlassSegments<T>(
        key: key,
        groupValue: groupValue,
        children: children,
        disabledChildren: disabledChildren,
        haptics: haptics,
        onValueChanged: onValueChanged,
        foregroundColor: scheme.onSurface,
        style: _material(context, plate: true),
        pillStyle: easy.LiquidGlassSegmentedPillStyle(
          animated: !MediaQuery.disableAnimationsOf(context),
          glass: PerformanceScope.of(context).glass,
          duration: NovelMotion.enter,
          glassStyle: _material(context),
          restStyle: easy.LiquidGlassStyle(
            color: scheme.onSurface.withValues(alpha: .065),
          ),
        ),
      ),
    );
  }
}

class Atmosphere extends StatelessWidget {
  const Atmosphere({
    super.key,
    required this.child,
    this.headerBackground,
    this.shareGlass = false,
    this.archiveBackdrop = true,
  });
  final Widget child;
  final Widget? headerBackground;
  final bool shareGlass;
  final bool archiveBackdrop;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final content = headerBackground == null
        ? child
        : Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(child: headerBackground),
                ),
              ),
              child,
            ],
          );
    final background = archiveBackdrop
        ? Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(child: ArchiveBackdrop()),
              content,
            ],
          )
        : content;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [ArchiveDesign.darkBackground, const Color(0xFF171B17)]
              : [ArchiveDesign.surface, ArchiveDesign.background],
        ),
      ),
      child: NativeScrollEdgeGroup(
        child: shareGlass ? NativeGlassGroup(child: background) : background,
      ),
    );
  }
}

/// Route titles are centered on the navigation plane, not on the space left
/// over after the back button. Both sides reserve the wider control group.
class ArchiveHeaderBar extends StatelessWidget {
  const ArchiveHeaderBar({
    super.key,
    required this.title,
    required this.leading,
    this.actions = const [],
  });

  final Widget title;
  final Widget leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: CustomMultiChildLayout(
      delegate: _ArchiveHeaderLayout(),
      children: [
        LayoutId(id: 'leading', child: leading),
        LayoutId(id: 'title', child: title),
        LayoutId(
          id: 'actions',
          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
      ],
    ),
  );
}

class _ArchiveHeaderLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final sideConstraints = BoxConstraints(
      maxWidth: size.width / 2,
      maxHeight: size.height,
    );
    final leading = layoutChild('leading', sideConstraints);
    final actions = layoutChild('actions', sideConstraints);
    positionChild('leading', Offset(0, (size.height - leading.height) / 2));
    positionChild(
      'actions',
      Offset(size.width - actions.width, (size.height - actions.height) / 2),
    );
    final gutter = math.max(leading.width, actions.width) + 8;
    final title = layoutChild(
      'title',
      BoxConstraints(
        maxWidth: math.max(0, size.width - gutter * 2),
        maxHeight: size.height,
      ),
    );
    positionChild(
      'title',
      Offset((size.width - title.width) / 2, (size.height - title.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_ArchiveHeaderLayout oldDelegate) => false;
}

/// Content may bounce under this header; its controls never join the scroll
/// viewport's transform or stretching overscroll layer.
class FrostedHeader extends StatelessWidget {
  const FrostedHeader({
    super.key,
    required this.child,
    this.blurBackground = true,
    this.extraHeight = 0,
  });

  static const toolbarHeight = 56.0;
  static const featherHeight = 56.0;
  final Widget child;
  final bool blurBackground;
  final double extraHeight;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    // SafeArea can clear MediaQuery.padding, but the physical status bar still
    // needs a blurred backdrop. Insets are for controls, not the blur's clip.
    final statusHeight = math.max(
      padding.top,
      AppWindowInsets.viewPaddingOf(context).top,
    );
    final appearance = GlassAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    return SizedBox(
      key: const ValueKey('frosted-navigation-plane'),
      height: statusHeight + toolbarHeight + extraHeight + featherHeight,
      child: Stack(
        children: [
          if (!highContrast && blurBackground)
            Positioned.fill(
              child: ProgressiveBlur(
                maxSigma: appearance.blur,
                plateauHeight: statusHeight,
                shadeOpacity: DockLayout.topEdgeShadeOpacity,
              ),
            ),
          if (highContrast)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Theme.of(context).colorScheme.surface),
              ),
            ),
          Positioned(
            top: statusHeight,
            left: padding.left + 24,
            right: padding.right + 24,
            height: toolbarHeight + extraHeight,
            child: ControlMaterialScope.chrome(
              child: NativeGlassGroup(child: GlassForeground(child: child)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable pinned navigation plane. The blur paints after the scrollable,
/// while its feather is pointer-transparent and never covers a button's hitbox.
class GlassHeaderLayout extends StatelessWidget {
  const GlassHeaderLayout({
    super.key,
    required this.body,
    required this.header,
    this.showHeader = true,
  });

  final Widget body;
  final Widget header;
  final bool showHeader;

  @override
  Widget build(BuildContext context) => !showHeader
      ? body
      : Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FrostedHeader(child: header),
            ),
          ],
        );
}

/// A light scroll-edge treatment below the dock, not another glass plate.
/// It extends to the gesture area without adding an opaque footer or hitbox.
class DockUnderlay extends StatelessWidget {
  const DockUnderlay({super.key, this.contentHeight});
  final double? contentHeight;

  @override
  Widget build(BuildContext context) {
    final blur = GlassAppearance.of(context).blur;
    return IgnorePointer(
      child: SizedBox(
        key: const ValueKey('dock-underlay'),
        height: DockLayout.underlayExtentOf(
          context,
          contentHeight: contentHeight,
        ),
        child: ProgressiveBlur(
          maxSigma: blur,
          plateauHeight: DockLayout.bottomPaddingOf(context, viewPadding: true),
          fromBottom: true,
        ),
      ),
    );
  }
}

class NovelScrollBehavior extends MaterialScrollBehavior {
  const NovelScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => axisDirectionToAxis(details.direction) == Axis.vertical
      ? AppScrollHaptics(child: child)
      : child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      getPlatform(context) == TargetPlatform.android
      ? const NovelAndroidScrollPhysics(
          parent: BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
        )
      : const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

/// Keep the accepted edge bounce, but not iOS's extra motion restart dead zone
/// and carried fling acceleration on Android. Gesture-arena touch slop stays
/// unchanged; accepted drag deltas, including tiny restarts, pass through.
class NovelAndroidScrollPhysics extends ScrollPhysics {
  const NovelAndroidScrollPhysics({super.parent});
  @override
  NovelAndroidScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      NovelAndroidScrollPhysics(parent: buildParent(ancestor));
  @override
  double? get dragStartDistanceMotionThreshold => null;
  @override
  double carriedMomentum(double existingVelocity) => 0;
}

/// Foreground stays crisp; the glass material itself carries the emission.
class GlassForeground extends StatelessWidget {
  const GlassForeground({super.key, required this.child});
  final Widget child;

  static List<Shadow> shadowsOf(BuildContext context) => const [];

  @override
  Widget build(BuildContext context) => child;
}

/// Navigation typography uses the same crisp foreground as glass controls.
class GlassText extends StatelessWidget {
  const GlassText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });
  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) => AppText(
    data,
    maxLines: maxLines,
    overflow: overflow,
    textAlign: textAlign,
    style: (style ?? const TextStyle()).copyWith(
      shadows: GlassForeground.shadowsOf(context),
    ),
  );
}

class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 28,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.haptic = HapticCue.action,
    this.semanticLabel,
    this.elevated = false,
    this.thickness = 20,
    this.blur,
    this.tintColor,
    this.tintOpacity,
    this.activation = 0,
    this.touchPosition = .5,
    this.shadowStrength = 1,
    this.preserveOptics = false,
    this.morph,
    this.transparent = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final HapticCue? haptic;
  final String? semanticLabel;
  final bool elevated;
  final double thickness;
  final double? blur;
  final Color? tintColor;
  final double? tintOpacity;
  final double activation;
  final double touchPosition;
  final double shadowStrength;
  final bool preserveOptics;
  final NativeGlassMorph? morph;
  final bool transparent;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  bool _pressed = false;
  bool _cancelledPress = false;
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final opaque = media.highContrast && !widget.transparent;
    final surface = Theme.of(context).colorScheme.surface;
    final appearance = GlassAppearance.of(context);
    final tintOpacity = widget.tintOpacity ?? appearance.opacity;
    final tint =
        widget.tintColor ??
        GlassAppearance.tintOf(context, opacity: tintOpacity);
    return AnimatedScale(
      scale: _pressed && !media.disableAnimations ? .97 : 1,
      duration: media.disableAnimations || _cancelledPress
          ? Duration.zero
          : _pressed
          ? NovelMotion.contact
          : NovelMotion.enter,
      curve: NovelMotion.settle,
      child: NativeBackdrop(
        bypass: widget.transparent,
        effect: NativeEffect.glass,
        radius: widget.radius,
        preserveOptics: widget.preserveOptics,
        morph: widget.morph,
        thickness: opaque || widget.transparent ? 0 : widget.thickness,
        // Small controls transmit the already-frosted live background without
        // two additional optical-blur passes. Overlays opt into their own
        // stronger softening; the page's scroll-edge blur remains independent.
        blur: opaque || widget.transparent ? 0 : widget.blur ?? 0,
        refractiveIndex: widget.transparent ? 1 : GlassOptics.refractiveIndex,
        activation: opaque ? 0 : widget.activation,
        touchPosition: widget.touchPosition,
        // A low, uniform lift across the entire material. No luminous rim,
        // outline, mask blur or glyph shadow; refraction remains transparent.
        emission: opaque || widget.transparent
            ? 0
            : (dark ? .024 : .010) *
                  (1 + .12 * math.max(widget.activation, _pressed ? 1 : 0)),
        tint: (opaque ? surface : tint).withValues(
          alpha: widget.transparent
              ? 0
              : opaque
              ? 1
              : tintOpacity,
        ),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            if (opaque) Positioned.fill(child: ColoredBox(color: surface)),
            Material(
              color: Colors.transparent,
              child: Semantics(
                button: widget.onTap != null,
                label: widget.semanticLabel,
                child: InkWell(
                  enableFeedback: false,
                  onTap: widget.onTap == null
                      ? null
                      : () {
                          AppHaptics.play(context, widget.haptic);
                          setState(() => _iconActivation++);
                          widget.onTap!();
                        },
                  onTapCancel: widget.onTap == null
                      ? null
                      : () => _cancelledPress = true,
                  onHighlightChanged: widget.onTap == null
                      ? null
                      : (pressed) => setState(() {
                          _pressed = pressed;
                          if (pressed) _cancelledPress = false;
                        }),
                  splashFactory: NoSplash.splashFactory,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  child: Padding(
                    padding: widget.padding,
                    child: ArchiveIconContact(
                      pressed: _pressed,
                      activation: _iconActivation,
                      child: GlassForeground(child: widget.child),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A softly refracting meniscus, with no painted selection fill.
class DockSelectionLens extends StatelessWidget {
  const DockSelectionLens({
    super.key,
    this.radius = 29,
    this.thickness = 24,
    this.activation = 0,
  });

  final double radius;
  final double thickness;
  final double activation;

  @override
  Widget build(BuildContext context) => LiquidGlass(
    radius: radius,
    thickness: thickness,
    activation: activation,
    // No duplicate optical blur or tint over the plate's live background.
    tintOpacity: 0,
    elevated: activation > 0,
    shadowStrength: activation * .65,
    child: const SizedBox.expand(),
  );
}

/// A compact icon action with the shared hit area, semantics and app haptic.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.haptic = HapticCue.action,
    this.liveGlass = true,
    this.transparent = false,
    this.pageHeight,
    this.compactMainPage = false,
  }) : child = null;

  /// Shares the standard hit area, glass and press response with icon actions.
  const GlassIconButton.custom({
    super.key,
    required this.child,
    required this.label,
    required this.onPressed,
    this.haptic = HapticCue.action,
    this.liveGlass = true,
    this.transparent = false,
    this.pageHeight,
    this.compactMainPage = false,
  }) : icon = null,
       color = null;

  final IconData? icon;
  final Widget? child;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final HapticCue? haptic;
  final bool liveGlass;
  final bool transparent;
  final double? pageHeight;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    final compact = compactMainPage || CompactMainPageControls.of(context);
    final geometry = _compactControlGeometry(context);
    final size = compact ? Size(48, geometry.hit) : const Size.square(46);
    final content = SizedBox(
      width: size.width,
      height: size.height,
      child: _unscaleCompactContent(
        compact: compact,
        scaleX: 40 / 48,
        scaleY: geometry.scale,
        child:
            child ??
            ArchiveIcon(
              icon,
              size: compact ? 20 : 21,
              color:
                  color ??
                  (onPressed == null ? Theme.of(context).disabledColor : null),
            ),
      ),
    );
    final semanticLabel = appText(context, label);
    final action = Semantics(
      button: true,
      enabled: onPressed != null,
      child: Tooltip(
        message: semanticLabel,
        triggerMode: TooltipTriggerMode.manual,
        excludeFromSemantics: true,
        child: _scaleCompactFace(
          compact: compact,
          scaleX: 40 / 48,
          scaleY: geometry.scale,
          child: liveGlass
              ? LiquidGlass(
                  radius: 24,
                  elevated: false,
                  semanticLabel: semanticLabel,
                  onTap: onPressed,
                  haptic: haptic,
                  child: content,
                )
              : _PaintedIconAction(
                  size: size,
                  transparent: transparent,
                  label: semanticLabel,
                  onPressed: onPressed,
                  haptic: haptic,
                  child: content,
                ),
        ),
      ),
    );
    return LibraryReflowPart(
      child: liveGlass ? action : MergeSemantics(child: action),
    );
  }
}

class _PaintedIconAction extends StatefulWidget {
  const _PaintedIconAction({
    required this.label,
    required this.onPressed,
    required this.haptic,
    required this.child,
    required this.size,
    this.transparent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final HapticCue? haptic;
  final Widget child;
  final bool transparent;
  final Size size;

  @override
  State<_PaintedIconAction> createState() => _PaintedIconActionState();
}

class _PaintedIconActionState extends State<_PaintedIconAction> {
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final appearance = GlassAppearance.of(context);
    final fill = widget.transparent
        ? Colors.transparent
        : MediaQuery.highContrastOf(context)
        ? Theme.of(context).colorScheme.surface
        : GlassAppearance.tintOf(
            context,
            opacity: appearance.opacity,
          ).withValues(alpha: appearance.opacity);
    return Semantics(
      label: widget.label,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: const CircleBorder()),
        child: Material(
          type: MaterialType.transparency,
          child: IconButton(
            onPressed: widget.onPressed == null
                ? null
                : () {
                    AppHaptics.play(context, widget.haptic);
                    setState(() => _iconActivation++);
                    widget.onPressed!();
                  },
            icon: widget.child,
            iconSize: 21,
            enableFeedback: false,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tight(widget.size),
            visualDensity: VisualDensity.standard,
            splashColor: Colors.transparent,
            style:
                IconButton.styleFrom(
                  fixedSize: widget.size,
                  shape: const CircleBorder(),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  animationDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : NovelMotion.contact,
                  splashFactory: NoSplash.splashFactory,
                ).copyWith(
                  foregroundBuilder: (context, states, child) =>
                      ArchiveIconContact(
                        pressed: states.contains(WidgetState.pressed),
                        activation: _iconActivation,
                        child: child!,
                      ),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.disabled)) {
                      return Colors.transparent;
                    }
                    final alpha =
                        states.contains(WidgetState.pressed) ||
                            states.contains(WidgetState.focused)
                        ? .08
                        : states.contains(WidgetState.hovered)
                        ? .04
                        : 0.0;
                    return Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: alpha);
                  }),
                ),
          ),
        ),
      ),
    );
  }
}

/// Shared sizing for the detail and batch-action pair, including large text.
({bool stacked, double height, double extent}) glassActionDockGeometry(
  BuildContext context, {
  required String primary,
  required String secondary,
}) {
  final media = MediaQuery.of(context);
  final width = math.min(
    DockLayout.actionMaxWidth,
    media.size.width -
        media.viewPadding.horizontal -
        DockLayout.actionSideInset * 2,
  );
  final textStyle =
      Theme.of(context).textTheme.bodyMedium ??
      DefaultTextStyle.of(context).style;
  ({double width, double height}) actionSize(String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: appText(context, text),
        style: textStyle.merge(
          const TextStyle(
            fontSize: DockLayout.labelFontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: media.textScaler,
    )..layout();
    final result = (
      width: painter.width + DockLayout.iconSize + 37,
      height: painter.height + 24,
    );
    painter.dispose();
    return result;
  }

  final first = actionSize(primary), second = actionSize(secondary);
  final rowWidth = math.max(0.0, width - DockLayout.actionGap);
  final stacked =
      second.width > rowWidth * 5 / 12 || first.width > rowWidth * 7 / 12;
  final actionHeight = math.max(
    DockLayout.heightOf(context),
    math.max(first.height, second.height),
  );
  final height = stacked
      ? actionHeight * 2 + DockLayout.actionGap
      : actionHeight;
  return (
    stacked: stacked,
    height: height,
    extent:
        height + DockLayout.bottomPaddingOf(context, viewPadding: true) + 12,
  );
}

({double face, double hit, double scale}) _compactControlGeometry(
  BuildContext context,
) {
  final face = math.max(
    40.0,
    MediaQuery.textScalerOf(context).scale(14) * 1.4 + 12,
  );
  final hit = math.max(48.0, face + 8);
  return (face: face, hit: hit, scale: face / hit);
}

Widget _scaleCompactFace({
  required bool compact,
  required double scaleY,
  double scaleX = 1,
  required Widget child,
}) => compact
    ? _CompactControlFace(scaleX: scaleX, scaleY: scaleY, child: child)
    : child;

class _CompactControlFace extends StatelessWidget {
  const _CompactControlFace({
    required this.scaleX,
    required this.scaleY,
    required this.child,
  });
  final double scaleX, scaleY;
  final Widget child;

  @override
  Widget build(BuildContext context) => Transform.scale(
    scaleX: scaleX,
    scaleY: scaleY,
    transformHitTests: false,
    child: child,
  );
}

Widget _unscaleCompactContent({
  required bool compact,
  required double scaleY,
  double scaleX = 1,
  required Widget child,
}) => compact
    ? Transform.scale(scaleX: 1 / scaleX, scaleY: 1 / scaleY, child: child)
    : child;

class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.height = 54,
    this.iconSize = 18,
    this.fontSize = 14,
    this.compactMainPage = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final double height, iconSize, fontSize;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = compactMainPage || CompactMainPageControls.of(context);
    final geometry = _compactControlGeometry(context);
    final scheme = theme.colorScheme;
    final action = loading ? null : onPressed;
    final color = scheme.onSurface.withValues(alpha: action == null ? .45 : 1);
    return Semantics(
      button: true,
      enabled: action != null,
      child: _scaleCompactFace(
        compact: compact,
        scaleY: geometry.scale,
        child: LiquidGlass(
          radius: height / 2,
          thickness: 16,
          elevated: false,
          onTap: action,
          semanticLabel: label,
          child: SizedBox(
            width: 196,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: compact ? geometry.hit : height,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: compact ? 10 : 12,
                ),
                child: _unscaleCompactContent(
                  compact: compact,
                  scaleY: geometry.scale,
                  child: loading
                      ? const SizedBox(
                          width: 128,
                          height: 18,
                          child: ExcludeSemantics(
                            child: LoadingSkeleton(
                              layout: SkeletonLayout.button,
                              label: '正在加载阅读进度',
                            ),
                          ),
                        )
                      : ArchivePart(
                          start: .58,
                          end: 1,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ArchiveIcon(
                                icon,
                                size: compact ? 20 : iconSize,
                                color: color,
                              ),
                              const SizedBox(width: 9),
                              Flexible(
                                child: AppText(
                                  label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: fontSize,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact secondary actions use the same material/press model, not a separate
/// stock button theme. Includes retry/reset without turning content cards glass.
class GlassTextButton extends StatelessWidget {
  const GlassTextButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.compact = false,
    this.selected,
    this.haptic = HapticCue.action,
    this.pageHeight,
    this.compactMainPage = false,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final bool compact;
  final bool? selected;
  final HapticCue? haptic;
  final double? pageHeight;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    final smallFace = compactMainPage || CompactMainPageControls.of(context);
    final geometry = _compactControlGeometry(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: smallFace ? 0 : 4),
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        selected: selected,
        child: _scaleCompactFace(
          compact: smallFace,
          scaleY: geometry.scale,
          child: LiquidGlass(
            radius: 22,
            elevated: false,
            tintColor: selected == true
                ? Color.lerp(
                    GlassAppearance.tintOf(
                      context,
                      opacity: GlassAppearance.of(context).opacity,
                    ),
                    Theme.of(context).colorScheme.onSurface,
                    .10,
                  )
                : null,
            onTap: onPressed,
            haptic: selected != null && haptic == HapticCue.action
                ? HapticCue.selection
                : haptic,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: compact ? 48 : 64,
                minHeight: smallFace ? geometry.hit : 48,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 14,
                  vertical: 10,
                ),
                child: Align(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: _unscaleCompactContent(
                    compact: smallFace,
                    scaleY: geometry.scale,
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: onPressed == null ? .45 : 1),
                      ),
                      child: ArchivePart(
                        start: .24,
                        end: .88,
                        travel: const Offset(0, 6),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget sectionHeader(BuildContext context, String title, String subtitle) =>
    ArchiveSection(
      title: title,
      subtitle: subtitle,
      code: switch (title) {
        '更多书籍' => '02 / ARCHIVE INDEX',
        '简介' => '01 / SYNOPSIS',
        '目录' => '02 / CONTENTS',
        '使用方式' => '00 / READING MODE',
        '阅读偏好' => '01 / READING PROFILE',
        '阅读记录' || '最近阅读' => '02 / READING LOG',
        '离线阅读' => '03 / LOCAL ARCHIVE',
        '玻璃外观' => '04 / OPTICAL SURFACE',
        '本地数据' => '05 / DATA MANAGEMENT',
        '性能诊断' => '06 / DIAGNOSTICS',
        _ => '01 / CATALOG',
      },
    );

class ContentPanel extends StatefulWidget {
  const ContentPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = ArchiveDesign.panelRadius,
    this.backgroundColor,
    this.onTap,
    this.haptic = HapticCue.action,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final HapticCue? haptic;

  @override
  State<ContentPanel> createState() => _ContentPanelState();
}

class _ContentPanelState extends State<ContentPanel> {
  bool _pressed = false;
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedScale(
      scale: _pressed && !reduceMotion ? .975 : 1,
      duration: reduceMotion
          ? Duration.zero
          : _pressed
          ? NovelMotion.contact
          : NovelMotion.enter,
      curve: NovelMotion.settle,
      child: Material(
        color: widget.backgroundColor ?? Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(widget.radius),
          side: BorderSide(color: Theme.of(context).dividerColor, width: .7),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          enableFeedback: false,
          onTap: widget.onTap == null
              ? null
              : () {
                  AppHaptics.play(context, widget.haptic);
                  setState(() => _iconActivation++);
                  widget.onTap!();
                },
          onHighlightChanged: widget.onTap == null
              ? null
              : (pressed) => setState(() => _pressed = pressed),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: ArchiveIconContact(
            pressed: _pressed,
            activation: _iconActivation,
            child: ArchiveRegistration(
              child: Padding(padding: widget.padding, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class JellyTapSurface extends StatefulWidget {
  const JellyTapSurface({
    super.key,
    this.tapKey,
    required this.child,
    required this.onTap,
    this.haptic = HapticCue.action,
  });

  final Widget child;
  final Key? tapKey;
  final VoidCallback? onTap;
  final HapticCue? haptic;

  @override
  State<JellyTapSurface> createState() => _JellyTapSurfaceState();
}

class _JellyTapSurfaceState extends State<JellyTapSurface> {
  bool _pressed = false;
  bool _cancelledPress = false;
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedScale(
      scale: _pressed && !reduceMotion ? .985 : 1,
      duration: reduceMotion || _cancelledPress
          ? Duration.zero
          : _pressed
          ? NovelMotion.contact
          : NovelMotion.enter,
      curve: NovelMotion.settle,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: widget.tapKey,
          enableFeedback: false,
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          onTapCancel: widget.onTap == null
              ? null
              : () => _cancelledPress = true,
          onHighlightChanged: widget.onTap == null
              ? null
              : (pressed) => setState(() {
                  _pressed = pressed;
                  if (pressed) _cancelledPress = false;
                }),
          onTap: widget.onTap == null
              ? null
              : () {
                  AppHaptics.play(context, widget.haptic);
                  setState(() => _iconActivation++);
                  widget.onTap!();
                },
          child: ArchiveIconContact(
            pressed: _pressed,
            activation: _iconActivation,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Scope distinguishes discovery, shelf and search copies of the same book.
/// Only the tapped copy shares its identity with the destination cover.
class CoverHeroTag {
  const CoverHeroTag(this.source, this.bookId);
  final Object source;
  final int bookId;

  @override
  bool operator ==(Object other) =>
      other is CoverHeroTag &&
      identical(source, other.source) &&
      bookId == other.bookId;

  @override
  int get hashCode => Object.hash(identityHashCode(source), bookId);
}

int novelCoverDecodeWidth(double width, double pixelRatio) =>
    (width * pixelRatio).ceil().clamp(1, 1536);

class NovelCover extends StatelessWidget {
  const NovelCover(
    this.novel, {
    super.key,
    this.width = 120,
    this.height = 164,
    this.heroTag,
    this.isDetailCover = false,
    this.fadeIn = false,
  });
  final Novel novel;
  final double width;
  final double height;
  final Object? heroTag;
  final bool isDetailCover;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    final cover = _visual();
    if (heroTag == null || MediaQuery.disableAnimationsOf(context)) {
      return cover;
    }
    return Hero(
      tag: heroTag!,
      transitionOnUserGestures: true,
      createRectTween: (begin, end) => PaperCoverRectTween(
        begin: begin,
        end: end,
        returning: !isDetailCover,
        heroCurve: true,
      ),
      flightShuttleBuilder: (context, animation, direction, from, to) {
        final pushing = direction == HeroFlightDirection.push;
        return PaperCoverFlight(
          key: ValueKey('cover-flight-${novel.id}'),
          animation:
              ModalRoute.of(
                direction == HeroFlightDirection.push ? to : from,
              )?.animation ??
              animation,
          imageProvider: switch (LegacyCover.peek(novel.id)) {
            final bytes? => MemoryImage(bytes),
            null => null,
          },
          faceSize: Size(width, height),
          beginPlane: PaperCoverPlane.fromHero(pushing ? from : to),
          endPlane: PaperCoverPlane.fromHero(pushing ? to : from),
          beginOcclusion: PaperCoverPlane.occlusionFromHero(
            pushing ? from : to,
          ),
          endOcclusion: PaperCoverPlane.occlusionFromHero(pushing ? to : from),
          backingColor: novel.coverUrl == null
              ? accent
              : Theme.of(context).colorScheme.surface,
          child: FittedBox(
            fit: BoxFit.fill,
            child: _visual(recordArrival: false),
          ),
        );
      },
      child: cover,
    );
  }

  Widget _visual({bool clip = true, bool recordArrival = true}) {
    final fallback = Padding(
      padding: EdgeInsets.all(width * .11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppText(
            novel.title,
            textScaler: TextScaler.noScaling,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: width * .16,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          AppText(
            novel.author,
            textScaler: TextScaler.noScaling,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: .75),
              fontSize: width * .085,
            ),
          ),
        ],
      ),
    );
    final face = novel.coverUrl == null
        ? fallback
        : Builder(
            builder: (context) {
              final placeholder = ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: const LoadingSkeleton(
                  layout: SkeletonLayout.cover,
                  label: '正在载入封面',
                ),
              );
              return FutureBuilder<Uint8List>(
                key: ValueKey('cover-bytes-${novel.id}'),
                future: LegacyCover.bytes(novel.id, url: novel.coverUrl),
                initialData: LegacyCover.peek(novel.id, url: novel.coverUrl),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return snapshot.hasError ? fallback : placeholder;
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => fallback,
                    frameBuilder: (context, child, frame, synchronous) =>
                        CoverArrival(
                          bytes: bytes,
                          ready: frame != null,
                          placeholder: placeholder,
                          recordArrival: recordArrival,
                          fade: fadeIn,
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.surface,
                            child: child,
                          ),
                        ),
                  );
                },
              );
            },
          );
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(
          clip ? ArchiveDesign.coverRadius : 0,
        ),
      ),
      child: !clip
          ? face
          : ClipRRect(
              borderRadius: BorderRadius.circular(ArchiveDesign.coverRadius),
              child: face,
            ),
    );
  }
}

/// Extends grayscale cover luminance behind floating controls.
class CoverGlow extends StatelessWidget {
  const CoverGlow(this.novel, {super.key});

  final Novel novel;

  @override
  Widget build(BuildContext context) {
    if (novel.coverUrl == null || !PerformanceScope.of(context).blur) {
      return const SizedBox.shrink();
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? const Color(0xFF101010) : Colors.white;
    return FutureBuilder(
      future: LegacyCover.bytes(novel.id, url: novel.coverUrl),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final top = MediaQuery.viewPaddingOf(context).top;
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [
                Colors.white,
                Colors.white,
                Colors.transparent,
                Colors.transparent,
              ],
              stops: [
                0,
                ((top + 36) / rect.height).clamp(0.0, 1.0),
                ((top + 170) / rect.height).clamp(0.0, 1.0),
                1,
              ],
            ).createShader(rect);
          },
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: 30,
                    sigmaY: 30,
                    tileMode: TileMode.clamp,
                  ),
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.matrix([
                      .2126,
                      .7152,
                      .0722,
                      0,
                      0,
                      .2126,
                      .7152,
                      .0722,
                      0,
                      0,
                      .2126,
                      .7152,
                      .0722,
                      0,
                      0,
                      0,
                      0,
                      0,
                      1,
                      0,
                    ]),
                    child: Image.memory(snapshot.data!, fit: BoxFit.cover),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        background.withValues(alpha: dark ? .45 : .53),
                        background.withValues(alpha: .84),
                        background,
                      ],
                      stops: const [0, .58, 1],
                    ),
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

/// Consistent recovery/empty states use the same typography, spacing and glass
/// action as the rest of the app, rather than unrelated stock dialog styles.
class ContentNotice extends StatelessWidget {
  const ContentNotice({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.onRetry,
    this.actionLabel = '重试',
    this.secondaryAction,
  });
  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String actionLabel;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArchiveIcon(
            icon,
            ambient: true,
            size: 34,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          AppText(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            AppText(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            GlassTextButton(onPressed: onRetry, child: AppText(actionLabel)),
          ],
          ?secondaryAction,
        ],
      ),
    ),
  );
}

PageRoute<T> softRoute<T>(
  Widget page, {
  bool reduceMotion = false,
  bool paperFlight = false,
  RouteSettings? settings,
}) => _NovelPageRoute<T>(
  page: page,
  reduceMotion: reduceMotion,
  paperFlight: paperFlight,
  settings: settings,
);

class _NovelPageRoute<T> extends CupertinoPageRoute<T> {
  _NovelPageRoute({
    required Widget page,
    required this.reduceMotion,
    required this.paperFlight,
    super.settings,
  }) : super(builder: (_) => RepaintBoundary(child: page));

  final bool reduceMotion;
  final bool paperFlight;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => RouteIdentity(
    route: this,
    child: super.buildPage(context, animation, secondaryAnimation),
  );

  @override
  Duration get transitionDuration => reduceMotion
      ? Duration.zero
      : paperFlight
      ? NovelMotion.coverFlight
      : NovelMotion.enter;

  @override
  Duration get reverseTransitionDuration => reduceMotion
      ? Duration.zero
      : paperFlight
      ? NovelMotion.coverReturn
      : NovelMotion.exit;
}

Future<T?> showJellySheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool reduceMotion = false,
  bool guardDragDismiss = false,
  ValueListenable<bool>? previewing,
  double? heightFactor,
  double maxWidth = 440,
  double? maxHeight,
  Widget Function(Widget)? surfaceWrapper,
  Rect? anchor,
  BuildContext? sourceContext,
}) => _showGlassOverlay<T>(
  context: context,
  builder: builder,
  reduceMotion: reduceMotion,
  kind: GlassOverlayKind.sheet,
  guardDragDismiss: guardDragDismiss,
  previewing: previewing,
  heightFactor: heightFactor,
  maxWidth: maxWidth,
  maxHeight: maxHeight,
  surfaceWrapper: surfaceWrapper,
  anchor: anchor,
  sourceContext: sourceContext,
);

/// The trigger holds its layout slot while its material stretches into the
/// route. Restore it after the reverse transition, never behind a second lens.
class GlassMenuAnchor extends StatefulWidget {
  const GlassMenuAnchor({super.key, required this.child});
  final Widget child;

  @override
  State<GlassMenuAnchor> createState() => _GlassMenuAnchorState();
}

class _GlassMenuAnchorState extends State<GlassMenuAnchor> {
  bool open = false;

  void setOpen(bool value) {
    if (mounted && open != value) setState(() => open = value);
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: open,
    child: ExcludeSemantics(
      excluding: open,
      child: Opacity(opacity: open ? 0 : 1, child: widget.child),
    ),
  );
}

final _activeGlassOverlays = Expando<bool>('active-glass-overlay');

GlassMenuSource? _captureGlassSource(
  BuildContext context,
  NavigatorState navigator,
) {
  GlassMenuSource? source;
  void capture(Element element) {
    if (source != null) return;
    final widget = element.widget;
    if (widget is LiquidGlass) {
      var keyed = false;
      void checkKeys(Element child) {
        if (child.widget.key is GlobalKey) keyed = true;
        child.visitChildElements(checkKeys);
      }

      element.visitChildElements(checkKeys);
      RenderBox? sourceBox;
      void findSurface(Element candidate) {
        if (sourceBox != null) return;
        if (candidate.widget is NativeBackdrop) {
          final render = candidate.findRenderObject();
          if (render is RenderBox && render.attached && render.hasSize) {
            sourceBox = render;
          }
        }
        if (sourceBox == null) candidate.visitChildElements(findSurface);
      }

      element.visitChildElements(findSurface);
      final compactFace = element
          .findAncestorWidgetOfExactType<_CompactControlFace>();
      final foreground = Padding(padding: widget.padding, child: widget.child);
      source = GlassMenuSource(
        box: sourceBox,
        radius: widget.radius,
        thickness: widget.thickness,
        blur: widget.blur ?? 0,
        foreground: keyed
            ? const SizedBox.shrink()
            : InheritedTheme.capture(from: element, to: navigator.context).wrap(
                compactFace == null
                    ? foreground
                    : Transform.scale(
                        scaleX: compactFace.scaleX,
                        scaleY: compactFace.scaleY,
                        child: foreground,
                      ),
              ),
      );
      return;
    }
    element.visitChildElements(capture);
  }

  capture(context as Element);
  return source;
}

Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool reduceMotion = false,
  bool preferBelow = false,
}) async {
  if (!context.mounted) return null;
  if (_activeGlassOverlays[context] == true) return null;
  final owner = context.findAncestorStateOfType<_GlassMenuAnchorState>();
  if (owner?.open ?? false) return null;
  final navigator = Navigator.of(context);
  final box = context.findRenderObject();
  final overlay = navigator.overlay?.context.findRenderObject();
  if (box is! RenderBox ||
      overlay is! RenderBox ||
      !box.attached ||
      !box.hasSize ||
      box.size.isEmpty) {
    return null;
  }
  final appearance = GlassAppearance.of(context);
  final source = _captureGlassSource(context, navigator);
  final sourceBox = source?.box ?? box;
  final route = _GlassOverlayRoute<T>(
    builder: builder,
    reduceMotion: reduceMotion || MediaQuery.disableAnimationsOf(context),
    appearance: appearance,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    kind: GlassOverlayKind.menu,
    preferBelow: preferBelow,
    anchor: MatrixUtils.transformRect(
      sourceBox.getTransformTo(overlay),
      Offset.zero & sourceBox.size,
    ),
    anchorBox: sourceBox,
    source: source,
  );
  owner?.setOpen(true);
  _activeGlassOverlays[context] = true;
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await navigator.push<T>(route);
    await route.completed;
    return result;
  } finally {
    _activeGlassOverlays[context] = false;
    owner?.setOpen(false);
  }
}

Future<T?> _showGlassOverlay<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool reduceMotion,
  required GlassOverlayKind kind,
  bool guardDragDismiss = false,
  Rect? anchor,
  BuildContext? sourceContext,
  ValueListenable<bool>? previewing,
  double? heightFactor,
  double maxWidth = 440,
  double? maxHeight,
  Widget Function(Widget)? surfaceWrapper,
}) async {
  if (!context.mounted) return null;
  if (_activeGlassOverlays[context] == true) return null;
  final navigator = Navigator.of(context);
  final sourceBox = sourceContext?.findRenderObject();
  final source = sourceContext == null
      ? null
      : _captureGlassSource(sourceContext, navigator);
  final owner = sourceContext?.findAncestorStateOfType<_GlassMenuAnchorState>();
  final route = _GlassOverlayRoute<T>(
    builder: builder,
    kind: kind,
    anchor: anchor,
    anchorBox: sourceBox is RenderBox && sourceBox.attached && sourceBox.hasSize
        ? sourceBox
        : null,
    source: source,
    reduceMotion: reduceMotion || MediaQuery.disableAnimationsOf(context),
    appearance: GlassAppearance.of(context),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    previewing: previewing,
    heightFactor: heightFactor,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    surfaceWrapper: surfaceWrapper,
    guardDragDismiss: guardDragDismiss,
  );
  _activeGlassOverlays[context] = true;
  owner?.setOpen(true);
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await navigator.push<T>(route);
    await route.completed;
    return result;
  } finally {
    _activeGlassOverlays[context] = false;
    owner?.setOpen(false);
  }
}

class GlassOverlaySurface extends StatefulWidget {
  const GlassOverlaySurface({
    super.key,
    required this.child,
    this.preserveOptics = false,
    this.morph,
    this.transparent = false,
  });
  final Widget child;
  final bool preserveOptics;
  final NativeGlassMorph? morph;
  final bool transparent;

  @override
  State<GlassOverlaySurface> createState() => _GlassOverlaySurfaceState();
}

class _GlassOverlaySurfaceState extends State<GlassOverlaySurface> {
  final _contentKey = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    return LiquidGlass(
      transparent: widget.transparent,
      radius: 28,
      thickness: 20,
      elevated: false,
      preserveOptics: widget.preserveOptics,
      morph: widget.morph,
      blur: math.min(12, GlassAppearance.of(context).blur),
      child: content,
    );
  }
}

class GlassMenuSource {
  const GlassMenuSource({
    required this.foreground,
    this.radius = 24,
    this.thickness = 20,
    this.blur = 0,
    this.box,
  });
  final Widget foreground;
  final double radius;
  final double thickness;
  final double blur;
  final RenderBox? box;
}

class GlassMenuSurface extends StatelessWidget {
  const GlassMenuSurface({
    super.key,
    required this.animation,
    required this.anchor,
    required this.child,
    this.source,
    this.reduceMotion = false,
  });
  final Animation<double> animation;
  final Rect anchor;
  final Widget child;
  final GlassMenuSource? source;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final reduced = reduceMotion || MediaQuery.disableAnimationsOf(context);
    return GlassOverlaySurface(
      preserveOptics: true,
      morph: reduced
          ? null
          : NativeGlassMorph(
              animation: animation,
              radius: source?.radius ?? 24,
              thickness: source?.thickness ?? 20,
              blur: source?.blur ?? 0,
            ),
      child: reduced
          ? child
          : GlassMenuContents(
              animation: animation,
              sourceSize: anchor.size,
              sourceRadius: source?.radius ?? 24,
              source: source?.foreground ?? const SizedBox.shrink(),
              child: ArchiveMotionScope(animation: animation, child: child),
            ),
    );
  }
}

class GlassMenuItem extends StatelessWidget {
  const GlassMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.order = 0,
    this.icon,
  });
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final int order;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: JellyTapSurface(
      onTap: onPressed,
      haptic: HapticCue.selection,
      child: GlassForeground(
        child: ArchivePart(
          start: .06 + order.clamp(0, 8) * .025,
          end: .62 + order.clamp(0, 8) * .025,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .9)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
            ),
            child: Row(
              children: [
                if (icon != null)
                  ArchiveIcon(icon, size: 20)
                else
                  ExcludeSemantics(
                    child: SizedBox(
                      width: 3,
                      height: 3,
                      child: ColoredBox(
                        color: selected
                            ? Theme.of(context).colorScheme.surface
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                SizedBox(width: icon == null ? 10 : 14),
                Expanded(
                  child: AppText(
                    label,
                    style: TextStyle(
                      color: selected
                          ? Theme.of(context).colorScheme.surface
                          : null,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  ArchiveIcon(
                    CupertinoIcons.check_mark,
                    size: 17,
                    color: Theme.of(context).colorScheme.surface,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _GlassOverlayRoute<T> extends PopupRoute<T>
    with AppHapticModalBarrier<T> {
  _GlassOverlayRoute({
    required this.builder,
    required this.kind,
    required this.reduceMotion,
    required this.appearance,
    required this.themes,
    this.anchor,
    this.anchorBox,
    this.source,
    this.previewing,
    this.heightFactor,
    this.maxWidth = 440,
    this.maxHeight,
    this.surfaceWrapper,
    this.preferBelow = false,
    this.guardDragDismiss = false,
  });
  final WidgetBuilder builder;
  final GlassOverlayKind kind;
  final bool reduceMotion;
  final GlassAppearance appearance;
  final CapturedThemes themes;
  final Rect? anchor;
  final RenderBox? anchorBox;
  final GlassMenuSource? source;
  final ValueListenable<bool>? previewing;
  final double? heightFactor;
  final double maxWidth;
  final double? maxHeight;
  final Widget Function(Widget)? surfaceWrapper;
  final bool preferBelow;
  final bool guardDragDismiss;

  @override
  void install() {
    super.install();
    previewing?.addListener(changedInternalState);
  }

  @override
  void dispose() {
    previewing?.removeListener(changedInternalState);
    super.dispose();
  }

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : NovelMotion.enter;
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : NovelMotion.exit;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor =>
      kind == GlassOverlayKind.menu || (previewing?.value ?? false)
      ? Colors.transparent
      : Colors.black.withValues(alpha: .16);
  @override
  String get barrierLabel => '关闭弹层';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final overlay =
        navigator!.overlay!.context.findRenderObject()! as RenderBox;
    final trigger = anchorBox;
    final origin = trigger != null && trigger.attached && trigger.hasSize
        ? MatrixUtils.transformRect(
            trigger.getTransformTo(overlay),
            Offset.zero & trigger.size,
          )
        : anchor;
    final dockSheet =
        kind == GlassOverlayKind.sheet && origin != null && source != null;
    final fallbackOrigin =
        origin ??
        Rect.fromCenter(
          center: overlay.size.center(Offset.zero),
          width: 1,
          height: 1,
        );
    final material = GlassOverlayTransition(
      animation: animation,
      kind: dockSheet ? GlassOverlayKind.menu : kind,
      reduceMotion: reduceMotion,
      anchor: fallbackOrigin,
      coordinateSpace: overlay,
      child: kind == GlassOverlayKind.sheet
          ? _GlassSheet(
              reduceMotion: reduceMotion,
              guardDragDismiss: guardDragDismiss,
              previewing: previewing,
              animation: animation,
              anchor: dockSheet ? origin : null,
              source: dockSheet ? source : null,
              child: ArchiveMotionScope(
                animation: animation,
                enabled: !reduceMotion,
                child: Builder(builder: builder),
              ),
            )
          : GlassMenuSurface(
              animation: animation,
              anchor: fallbackOrigin,
              source: source,
              reduceMotion: reduceMotion,
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.all(8),
                child: ArchiveMotionScope(
                  animation: animation,
                  enabled: !reduceMotion,
                  child: Builder(builder: builder),
                ),
              ),
            ),
    );
    final surface = surfaceWrapper?.call(material) ?? material;
    return themes.wrap(
      GlassAppearance(
        blur: appearance.blur,
        opacity: appearance.opacity,
        child: Material(
          type: MaterialType.transparency,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final safe = _popupSafeRect(
                overlay,
                constraints.biggest,
                MediaQuery.of(context),
              );
              if (kind == GlassOverlayKind.menu) {
                return CustomSingleChildLayout(
                  delegate: _GlassMenuPlacement(
                    fallbackOrigin,
                    safe,
                    preferBelow,
                  ),
                  child: surface,
                );
              }
              final width = math.min(maxWidth, math.max(0.0, safe.width - 24));
              final sheetBottom = math.min(
                dockSheet ? origin.bottom : origin?.top ?? safe.bottom,
                safe.bottom,
              );
              final height = math.min(
                maxHeight ?? double.infinity,
                math.max(0.0, sheetBottom - safe.top - 22),
              );
              return Stack(
                children: [
                  Positioned(
                    left: safe.center.dx - width / 2,
                    bottom:
                        math.max(0, constraints.maxHeight - sheetBottom) +
                        (dockSheet
                            ? 0
                            : origin == null
                            ? 10
                            : 8),
                    width: width,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: height),
                      child: heightFactor == null
                          ? surface
                          : SizedBox(
                              height: math.min(760, height * heightFactor!),
                              child: surface,
                            ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Rect _popupSafeRect(RenderBox overlay, Size size, MediaQueryData media) {
  final padding = media.padding;
  final keyboard = media.viewInsets;
  final left = math.max(padding.left, keyboard.left);
  final top = math.max(padding.top, keyboard.top);
  final global = Rect.fromLTRB(
    left,
    top,
    math.max(left, media.size.width - math.max(padding.right, keyboard.right)),
    math.max(
      top,
      media.size.height - math.max(padding.bottom, keyboard.bottom),
    ),
  );
  final inverse = Matrix4.tryInvert(overlay.getTransformTo(null));
  final local = inverse == null
      ? Rect.zero
      : MatrixUtils.transformRect(inverse, global);
  final clipped = local.intersect(Offset.zero & size);
  if (clipped.width >= 0 && clipped.height >= 0) return clipped;
  return Rect.fromLTWH(
    local.left.clamp(0, size.width),
    local.top.clamp(0, size.height),
    0,
    0,
  );
}

class _GlassMenuPlacement extends SingleChildLayoutDelegate {
  _GlassMenuPlacement(this.anchor, this.safe, this.preferBelow);
  final Rect anchor;
  final Rect safe;
  final bool preferBelow;
  Rect get available => Rect.fromLTWH(
    safe.left + math.min(12, safe.width / 2),
    math.min(safe.top + math.min(12, safe.height / 2), math.max(0, anchor.top)),
    math.max(0, safe.width - 24),
    math.max(0, safe.height - 24),
  );
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: math.min(248, available.width),
        maxWidth: math.min(248, available.width),
        maxHeight: available.height,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final area = available;
    final x = (anchor.right - childSize.width).clamp(
      area.left,
      math.max(area.left, area.right - childSize.width),
    );
    final below = preferBelow ? anchor.bottom + 8 : anchor.top;
    final y = below + childSize.height <= area.bottom
        ? below
        : (preferBelow ? anchor.top - 8 : anchor.bottom) - childSize.height;
    return Offset(
      x.toDouble(),
      y.clamp(area.top, math.max(area.top, area.bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_GlassMenuPlacement oldDelegate) =>
      anchor != oldDelegate.anchor ||
      safe != oldDelegate.safe ||
      preferBelow != oldDelegate.preferBelow;
}

class _GlassSheet extends StatefulWidget {
  const _GlassSheet({
    required this.child,
    required this.reduceMotion,
    this.guardDragDismiss = false,
    this.previewing,
    this.animation,
    this.anchor,
    this.source,
  });
  final Widget child;
  final bool reduceMotion;
  final bool guardDragDismiss;
  final ValueListenable<bool>? previewing;
  final Animation<double>? animation;
  final Rect? anchor;
  final GlassMenuSource? source;
  @override
  State<_GlassSheet> createState() => _GlassSheetState();
}

class _GlassSheetState extends State<_GlassSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );
  final _surfaceKey = GlobalKey();
  bool _cancelled = false;
  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _restore() {
    if (widget.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _drag.value = 0;
    } else {
      _drag.animateTo(0, duration: NovelMotion.enter, curve: NovelMotion.ease);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _cancelled = false,
    onPointerCancel: (_) => _cancelled = true,
    child: GestureDetector(
      onVerticalDragStart: (_) => _drag.stop(),
      onVerticalDragUpdate: (details) =>
          _drag.value = math.max(0, _drag.value + details.delta.dy),
      onVerticalDragEnd: (details) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        if (_cancelled) {
          _restore();
          return;
        }
        final box = _surfaceKey.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return;
        if ((details.primaryVelocity ?? 0) > 550 ||
            _drag.value > box.size.height * .24) {
          AppHaptics.play(context, HapticCue.action);
          if (widget.guardDragDismiss) {
            if (ModalRoute.of(context)?.popDisposition ==
                RoutePopDisposition.doNotPop) {
              _restore();
            }
            Navigator.of(context).maybePop();
          } else {
            Navigator.of(context).pop();
          }
        } else {
          _restore();
        }
      },
      onVerticalDragCancel: _restore,
      child: AnimatedBuilder(
        animation: _drag,
        child: RepaintBoundary(
          child: ValueListenableBuilder<bool>(
            valueListenable:
                widget.previewing ?? const AlwaysStoppedAnimation(false),
            builder: (context, previewing, child) {
              return GlassOverlaySurface(
                key: _surfaceKey,
                transparent: previewing,
                preserveOptics: widget.source != null,
                morph:
                    widget.source == null ||
                        widget.reduceMotion ||
                        MediaQuery.disableAnimationsOf(context)
                    ? null
                    : NativeGlassMorph(
                        animation: widget.animation!,
                        radius: widget.source!.radius,
                        thickness: widget.source!.thickness,
                        blur: widget.source!.blur,
                      ),
                child: child!,
              );
            },
            child: _contents(context),
          ),
        ),
        builder: (context, child) => Transform.translate(
          key: const ValueKey('glass-sheet-drag'),
          offset: Offset(0, _drag.value),
          child: child,
        ),
      ),
    ),
  );

  Widget _contents(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        ValueListenableBuilder<bool>(
          valueListenable:
              widget.previewing ?? const AlwaysStoppedAnimation(false),
          builder: (context, previewing, child) =>
              Opacity(opacity: previewing ? 0 : 1, child: child),
          child: Container(
            width: 32,
            height: 3,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Flexible(child: widget.child),
      ],
    );
    if (widget.source == null ||
        widget.reduceMotion ||
        MediaQuery.disableAnimationsOf(context)) {
      return content;
    }
    return GlassMenuContents(
      animation: widget.animation!,
      sourceSize: widget.anchor!.size,
      sourceRadius: widget.source!.radius,
      source: widget.source!.foreground,
      child: content,
    );
  }
}
