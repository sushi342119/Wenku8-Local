import 'package:flutter/foundation.dart';

import 'performance_preferences.dart';

/// Four glass tiers replace the old "glass appearance" slider and the
/// low-performance entry as the primary control. Older keys are untouched:
/// the sliders live on under "advanced" and the five low-performance switches
/// under "custom", both layered on top of the tier.
enum GlassTier {
  off('关', blur: 0, refraction: 0, opacity: 1, edge: GlassEdgeMode.none),
  light('轻', blur: 4, refraction: 6, opacity: .94, edge: GlassEdgeMode.header),
  standard('标准', blur: 8, refraction: 12, opacity: .87, edge: GlassEdgeMode.full),
  strong(
    '强',
    blur: 14,
    refraction: 16,
    opacity: .78,
    edge: GlassEdgeMode.full,
    highlight: true,
  );

  const GlassTier(
    this.label, {
    required this.blur,
    required this.refraction,
    required this.opacity,
    required this.edge,
    this.highlight = false,
  });
  final String label;
  final double blur, refraction, opacity;
  final GlassEdgeMode edge;
  final bool highlight;

  /// v1.7.1 used a 16px dock thickness; "standard" keeps that exact look and
  /// the other tiers scale it by the design's 6 / 12 / 16 refraction widths.
  double get refractionScale => refraction / GlassTier.standard.refraction;

  static GlassTier? fromRecord(Object? value) {
    for (final tier in values) {
      if (tier.name == value) return tier;
    }
    return null;
  }
}

enum GlassEdgeMode { none, header, full }

/// Stored value of `glassTier` when the tier follows device detection.
const glassTierAuto = 'auto';

/// Reader font size range (design: 14–30, step 1, default 19). Records saved
/// with the old 15–27 range are inside it and load unchanged.
const readerFontSizeMin = 14.0;
const readerFontSizeMax = 30.0;

enum MotionLevel {
  off('关'),
  light('轻'),
  standard('标准');

  const MotionLevel(this.label);
  final String label;

  static MotionLevel fromRecord(Object? value) {
    for (final level in values) {
      if (level.name == value) return level;
    }
    return MotionLevel.light;
  }
}

enum RandomPickPace {
  quick('快速', Duration(milliseconds: 900)),
  ceremony('仪式', Duration(milliseconds: 2400));

  const RandomPickPace(this.label, this.duration);
  final String label;
  final Duration duration;

  static RandomPickPace fromRecord(Object? value) =>
      value == ceremony.name ? ceremony : quick;
}

/// "原版" palette has two versions: the 2026-11 blue (default) and the
/// v1.7.1 ink monochrome. Stored separately from `appPalette`, whose strict
/// decoder in older builds would reject an extra field.
enum OriginalPaletteVariant {
  vivid('新版（蓝）'),
  ink('经典墨黑');

  const OriginalPaletteVariant(this.label);
  final String label;

  static OriginalPaletteVariant fromRecord(Object? value) =>
      value == ink.name ? ink : vivid;
}

enum ShelfLayout {
  list('列表'),
  grid('网格');

  const ShelfLayout(this.label);
  final String label;

  static ShelfLayout fromRecord(Object? value) =>
      value == grid.name ? grid : list;
}

enum TagMatchMode {
  any('任一 OR'),
  all('全部 AND');

  const TagMatchMode(this.label);
  final String label;

  static TagMatchMode fromRecord(Object? value) =>
      value == all.name ? all : any;
}

/// New preference keys. Every key here is additive, is listed in the Dart
/// backup allow-list and in the native multi-key writer allow-list.
abstract final class UiPreferenceKeys {
  static const glassTier = 'glassTier';
  static const glassAdvanced = 'glassAdvanced';
  static const motionLevel = 'motionLevel';
  static const randomPickPace = 'randomPickPace';
  static const pdfNightInvert = 'pdfNightInvert';
  static const shelfLayout = 'shelfLayout';
  static const tagMatchMode = 'tagMatchMode';
  static const readerPreferences = 'readerPreferences';
  static const paletteVariant = 'paletteVariant';

  static const all = {
    paletteVariant,
    glassTier,
    glassAdvanced,
    motionLevel,
    randomPickPace,
    pdfNightInvert,
    shelfLayout,
    tagMatchMode,
    readerPreferences,
  };

  /// Validates a backup value for one of the new keys.
  static bool valid(String key, Object? value) => switch (key) {
    glassTier => value == glassTierAuto || GlassTier.fromRecord(value) != null,
    glassAdvanced || pdfNightInvert => value is bool,
    motionLevel => MotionLevel.values.any((v) => v.name == value),
    randomPickPace => RandomPickPace.values.any((v) => v.name == value),
    shelfLayout => ShelfLayout.values.any((v) => v.name == value),
    tagMatchMode => TagMatchMode.values.any((v) => v.name == value),
    paletteVariant => OriginalPaletteVariant.values.any((v) => v.name == value),
    _ => false,
  };
}

/// Device facts used once per launch to choose the automatic glass tier.
@immutable
class DeviceProfile {
  const DeviceProfile({this.sdkInt, this.totalMemoryBytes});
  final int? sdkInt;
  final int? totalMemoryBytes;

  /// A "4 GB" phone reports roughly 3.4–3.8 GiB to apps because the kernel
  /// and carve-outs are excluded; 4.5 GiB keeps those on the light tier
  /// without catching 6 GB devices.
  static const lowMemoryThreshold = 4608 * 1024 * 1024;

  /// Android 10 is API 29.
  bool get lowEnd =>
      (sdkInt != null && sdkInt! <= 29) ||
      (totalMemoryBytes != null &&
          totalMemoryBytes! > 0 &&
          totalMemoryBytes! <= lowMemoryThreshold);

  static DeviceProfile fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return const DeviceProfile();
    final sdk = raw['sdkInt'];
    final memory = raw['totalMemoryBytes'];
    return DeviceProfile(
      sdkInt: sdk is int && sdk > 0 ? sdk : null,
      totalMemoryBytes: memory is int && memory > 0 ? memory : null,
    );
  }
}

/// Resolved appearance after tier, custom switches and advanced sliders.
@immutable
class ResolvedGlass {
  const ResolvedGlass({
    required this.tier,
    required this.automatic,
    required this.blur,
    required this.opacity,
    required this.performance,
  });
  final GlassTier tier;
  final bool automatic;
  final double blur, opacity;
  final PerformancePreferences performance;
}

ResolvedGlass resolveGlass({
  required GlassTier? chosen,
  required bool lowEndDevice,
  required bool advanced,
  required double sliderBlur,
  required double sliderOpacity,
  required PerformancePreferences custom,
}) {
  final tier = chosen ?? (lowEndDevice ? GlassTier.light : GlassTier.standard);
  final tierEffects = <PerformanceEffect>{
    PerformanceEffect.motion,
    if (tier != GlassTier.off) ...[
      PerformanceEffect.glass,
      PerformanceEffect.blur,
      PerformanceEffect.edgeBlur,
    ],
    if (tier == GlassTier.standard || tier == GlassTier.strong)
      PerformanceEffect.shelf3d,
  };
  final effects = {
    for (final effect in tierEffects)
      if (custom.allows(effect)) effect,
  };
  final restricted = effects.length != PerformanceEffect.values.length;
  final useSliders = advanced && tier != GlassTier.off;
  return ResolvedGlass(
    tier: tier,
    automatic: chosen == null,
    blur: useSliders ? sliderBlur : tier.blur,
    opacity: useSliders ? sliderOpacity : tier.opacity,
    performance: restricted
        ? PerformancePreferences(enabled: true, effects: Set.unmodifiable(effects))
        : const PerformancePreferences(),
  );
}
