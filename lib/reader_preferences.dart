import 'dart:convert';
import 'package:flutter/material.dart';
import 'archive_design.dart';
import 'personal_images.dart' show validBackgroundId;

const minimumReaderFontSize = 10.0;
const maximumReaderFontSize = 27.0;

enum ReaderPaper {
  system('跟随外观'),
  // Legacy values: never offered again, still decoded and drawn unchanged.
  milk('奶白'),
  parchment('羊皮纸'),
  sage('浅苔'),
  night('夜读'),
  // Design 2026-11 §3 papers (text contrast ≥ 7:1).
  white('纯白'),
  mist('雾灰'),
  green('浅绿'),
  sand('暖沙'),
  oled('纯黑');

  const ReaderPaper(this.label);
  final String label;

  /// Choices shown in the picker, in design order.
  static const choices = [system, white, mist, green, sand, night, oled];
}

/// Warm-light overlay: 0–40 % maps to at most 0.18 alpha of #FF9A3C.
const readerWarmthMax = .4;
const readerWarmthColor = Color(0xFFFF9A3C);
Color readerWarmthOverlay(double warmth) => readerWarmthColor.withValues(
  alpha: (warmth.clamp(0.0, readerWarmthMax) / readerWarmthMax) * .18,
);

enum ReaderMode {
  scroll('上下滚动'),
  paged('横排翻页'),
  vertical('竖排翻页');

  const ReaderMode(this.label);
  final String label;
  bool get paginated => this != scroll;
}

enum ReaderVerticalLatinOrientation {
  rotated('随文旋转'),
  upright('逐字直立');

  const ReaderVerticalLatinOrientation(this.label);
  final String label;
}

/// Stored layout keys may also carry typography and content-filter suffixes.
/// Read the mode token rather than requiring it to be the last field.
bool readerLayoutIsPaginated(String layout) => layout
    .split('|')
    .any(
      (section) =>
          !section.startsWith('languages=') &&
          section
              .split(':')
              .any((part) => part == 'paged' || part == 'vertical'),
    );

enum ReaderTapLayout {
  standard('常规'),
  rightHand('右手'),
  leftHand('左手'),
  custom('九宫格');

  const ReaderTapLayout(this.label);
  final String label;
}

enum ReaderTapZoneAction {
  nextPage('下一页'),
  prevPage('上一页'),
  toggleMenu('呼出菜单'),
  nextChapter('下一章'),
  prevChapter('上一章'),
  toggleListening('听书开关'),
  addBookmark('添加书签'),
  none('无操作');

  const ReaderTapZoneAction(this.label);
  final String label;
}

const defaultReaderTapGrid = <ReaderTapZoneAction>[
  ReaderTapZoneAction.prevPage,
  ReaderTapZoneAction.prevPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.prevPage,
  ReaderTapZoneAction.toggleMenu,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
  ReaderTapZoneAction.nextPage,
];

enum ReaderAutoPageMode {
  off('关闭'),
  curtain('幕布推进'),
  timed('定时翻页');

  const ReaderAutoPageMode(this.label);
  final String label;
}

enum ReaderPageEffect {
  staggered('段落接续'),
  none('无动画'),
  slide('平移'),
  cover('覆盖'),
  paper('纸页翻动'),
  fade('渐隐');

  const ReaderPageEffect(this.label);
  final String label;
  Duration get duration => switch (this) {
    staggered => const Duration(milliseconds: 620),
    none => Duration.zero,
    slide => const Duration(milliseconds: 300),
    cover => const Duration(milliseconds: 340),
    paper => const Duration(milliseconds: 440),
    fade => const Duration(milliseconds: 300),
  };
}

enum ReaderPageSpeed {
  relaxed('舒缓', 1.35),
  normal('标准', 1),
  quick('利落', .7);

  const ReaderPageSpeed(this.label, this.durationScale);
  final String label;
  final double durationScale;

  Duration durationFor(ReaderPageEffect effect) => Duration(
    microseconds: (effect.duration.inMicroseconds * durationScale).round(),
  );
}

enum ReaderTextWeight {
  regular('常规', FontWeight.w400),
  medium('适中', FontWeight.w500),
  bold('加粗', FontWeight.w600);

  const ReaderTextWeight(this.label, this.weight);
  final String label;
  final FontWeight weight;
}

/// Reader-only settings: changing paper never changes the rest of the app.
class ReaderPreferences {
  const ReaderPreferences({
    this.paper = ReaderPaper.system,
    this.margin = 26,
    this.marginLeft,
    this.marginRight,
    this.marginTop = 8,
    this.marginBottom = 8,
    this.paragraphGap = 12,
    this.paragraphGapOverride = false,
    this.catalogueReversed = false,
    this.indent = false,
    this.justify = false,
    this.tapPaging = false,
    this.tapBothSidesNext = false,
    this.volumePaging = false,
    this.brightness,
    this.autoScrollSpeed = 24,
    this.mode = ReaderMode.scroll,
    this.verticalLatinOrientation = ReaderVerticalLatinOrientation.rotated,
    this.tapLayout = ReaderTapLayout.standard,
    this.edgeBrightness = false,
    this.pageEffect = ReaderPageEffect.staggered,
    this.pageSpeed = ReaderPageSpeed.normal,
    this.hideSystemStatus = false,
    this.showStatusInfo = true,
    this.chapterEntrance = false,
    this.nightTextBrightness = .82,
    this.letterSpacing = .1,
    this.textWeight = ReaderTextWeight.regular,
    this.statusSideInset = 0,
    this.statusFontSize = 12,
    this.statusTopOffset = 0,
    this.backgroundImage,
    this.backgroundOpacity = .18,
    this.backgroundFit = BoxFit.cover,
    this.warmth = 0,
    this.edgeDeadZone = 0,
    this.tapGrid = defaultReaderTapGrid,
    this.autoPageMode = ReaderAutoPageMode.off,
    this.kinsokuCompression = true,
  });
  final ReaderPaper paper;
  final double margin, paragraphGap, autoScrollSpeed;
  final bool paragraphGapOverride, catalogueReversed;
  // Null horizontal edges preserve old records and existing margin callers.
  final double? marginLeft, marginRight;
  final double marginTop, marginBottom;
  double get leftMargin => marginLeft ?? margin;
  double get rightMargin => marginRight ?? margin;
  double get bindingMargin => (leftMargin + rightMargin) / 2;
  final bool indent, justify, tapPaging, tapBothSidesNext, volumePaging;
  final double? brightness;
  final ReaderMode mode;
  final ReaderVerticalLatinOrientation verticalLatinOrientation;
  final ReaderTapLayout tapLayout;
  final bool edgeBrightness;
  final ReaderPageEffect pageEffect;
  final ReaderPageSpeed pageSpeed;
  final bool hideSystemStatus;
  final bool showStatusInfo;
  bool get showReaderStatus => hideSystemStatus && showStatusInfo;
  final bool chapterEntrance;
  final double nightTextBrightness;
  final double letterSpacing;
  final ReaderTextWeight textWeight;
  final double statusSideInset;
  final double statusFontSize, statusTopOffset;
  final String? backgroundImage;
  final double backgroundOpacity;
  final BoxFit backgroundFit;

  /// 0–[readerWarmthMax]; drawn as an overlay, never changes text layout.
  final double warmth;

  /// Curved-screen anti-mistouch dead-zone width on left/right edges (0..48 px).
  final double edgeDeadZone;

  /// 3x3 custom tap zone actions (row-major, 9 items).
  final List<ReaderTapZoneAction> tapGrid;
  List<ReaderTapZoneAction> get effectiveTapGrid =>
      tapGrid.length == 9 ? tapGrid : defaultReaderTapGrid;

  /// Paged-mode auto read mode (off / curtain scanline / timed page turn).
  final ReaderAutoPageMode autoPageMode;

  /// Kinsoku trailing punctuation compression in pagination.
  final bool kinsokuCompression;
  String get layoutKey {
    final geometry =
        leftMargin == 26 &&
            rightMargin == 26 &&
            marginTop == 8 &&
            marginBottom == 8 &&
            paragraphGap == 12 &&
            !indent &&
            !justify &&
            mode == ReaderMode.scroll
        ? ''
        : '${leftMargin == rightMargin && marginTop == 8 && marginBottom == 8 ? '$leftMargin' : '$leftMargin,$marginTop,$rightMargin,$marginBottom'}:$paragraphGap:$indent:$justify';
    final modeKey = mode == ReaderMode.scroll ? '' : ':${mode.name}';
    final gapKey = paragraphGapOverride ? ':gap=custom' : '';
    final textKey =
        letterSpacing == .1 && textWeight == ReaderTextWeight.regular
        ? ''
        : ':text=$letterSpacing,${textWeight.name}';
    if (mode == ReaderMode.vertical &&
        verticalLatinOrientation == ReaderVerticalLatinOrientation.upright) {
      return '$geometry$gapKey$textKey:latin=upright$modeKey';
    }
    // Existing preferences retain exactly the same persisted layout key.
    return '$geometry$gapKey$modeKey$textKey';
  }

  Color background(bool dark) => switch (paper) {
    ReaderPaper.system =>
      dark ? ArchiveDesign.darkBackground : const Color(0xFFF7F7F2),
    ReaderPaper.milk => const Color(0xFFF6F5EF),
    ReaderPaper.parchment => const Color(0xFFEDE2CA),
    ReaderPaper.sage => const Color(0xFFE4EBDD),
    ReaderPaper.night => const Color(0xFF0A0E17),
    ReaderPaper.white => const Color(0xFFFFFFFF),
    ReaderPaper.mist => const Color(0xFFF2F3F5),
    ReaderPaper.green => const Color(0xFFE7F0E6),
    ReaderPaper.sand => const Color(0xFFF3ECDD),
    ReaderPaper.oled => const Color(0xFF000000),
  };

  /// Solid control panel colour for each paper (design §3).
  Color panel(bool dark) => switch (paper) {
    ReaderPaper.white => const Color(0xFFF3F4F6),
    ReaderPaper.mist => const Color(0xFFE6E8EB),
    ReaderPaper.green => const Color(0xFFDAE6D9),
    ReaderPaper.sand => const Color(0xFFE8DFCC),
    ReaderPaper.night => const Color(0xFF121826),
    ReaderPaper.oled => const Color(0xFF0D1119),
    _ => Color.lerp(
      background(dark),
      controlForeground(dark),
      darkPaper(dark) ? .08 : .05,
    )!,
  };
  Color controlForeground(bool dark) => switch (paper) {
    ReaderPaper.white => const Color(0xFF1F2125),
    ReaderPaper.mist => const Color(0xFF23262B),
    ReaderPaper.green => const Color(0xFF1F2A20),
    ReaderPaper.sand => const Color(0xFF2B261C),
    // Full-brightness ink; at the default 0.82 this lands on the design's
    // #B9BCC2 (night) and #9EA2A8 (OLED).
    ReaderPaper.night => const Color(0xFFE2E8F4),
    ReaderPaper.oled => const Color(0xFFC1C6CD),
    _ when darkPaper(dark) => ArchiveDesign.darkInk,
    _ => const Color(0xFF30352F),
  };
  bool darkPaper(bool dark) =>
      paper == ReaderPaper.night ||
      paper == ReaderPaper.oled ||
      paper == ReaderPaper.system && dark;
  Color foreground(bool dark) => darkPaper(dark)
      ? Color.lerp(
          background(dark),
          controlForeground(dark),
          nightTextBrightness,
        )!
      : controlForeground(dark);
  Map<String, Object?> toJson() => {
    'paper': paper.name,
    'margin': margin,
    if (marginLeft != null) 'marginLeft': marginLeft,
    if (marginRight != null) 'marginRight': marginRight,
    'marginTop': marginTop,
    'marginBottom': marginBottom,
    'paragraphGap': paragraphGap,
    if (paragraphGapOverride || paragraphGap != 12)
      'paragraphGapOverride': paragraphGapOverride,
    if (catalogueReversed) 'catalogueReversed': true,
    'indent': indent,
    'justify': justify,
    'tapPaging': tapPaging,
    'tapBothSidesNext': tapBothSidesNext,
    'volumePaging': volumePaging,
    'brightness': brightness,
    'autoScrollSpeed': autoScrollSpeed,
    'mode': mode.name,
    'verticalLatinOrientation': verticalLatinOrientation.name,
    'tapLayout': tapLayout.name,
    'edgeBrightness': edgeBrightness,
    'pageEffect': pageEffect.name,
    'pageSpeed': pageSpeed.name,
    'hideSystemStatus': hideSystemStatus,
    'showStatusInfo': showStatusInfo,
    'chapterEntrance': chapterEntrance,
    'nightTextBrightness': nightTextBrightness,
    'letterSpacing': letterSpacing,
    'textWeight': textWeight.name,
    'statusSideInset': statusSideInset,
    'statusFontSize': statusFontSize,
    'statusTopOffset': statusTopOffset,
    if (backgroundImage != null) 'backgroundImage': backgroundImage,
    'backgroundOpacity': backgroundOpacity,
    'backgroundFit': backgroundFit.name,
    if (warmth != 0) 'warmth': warmth,
    if (edgeDeadZone > 0) 'edgeDeadZone': edgeDeadZone,
    if (tapLayout == ReaderTapLayout.custom ||
        !_sameTapGrid(tapGrid, defaultReaderTapGrid))
      'tapGrid': [for (final a in effectiveTapGrid) a.name],
    if (autoPageMode != ReaderAutoPageMode.off)
      'autoPageMode': autoPageMode.name,
    if (!kinsokuCompression) 'kinsokuCompression': false,
  };
  static bool _sameTapGrid(
    List<ReaderTapZoneAction> a,
    List<ReaderTapZoneAction> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  factory ReaderPreferences.fromJson(Map<String, dynamic> json) {
    double number(String key, double min, double max, double fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! num || !value.isFinite || value < min || value > max) {
        throw const FormatException('阅读偏好数值超出范围');
      }
      return value.toDouble();
    }

    for (final key in [
      'indent',
      'justify',
      'tapPaging',
      'tapBothSidesNext',
      'volumePaging',
      'edgeBrightness',
      'hideSystemStatus',
      'showStatusInfo',
      'chapterEntrance',
      'paragraphGapOverride',
      'catalogueReversed',
      'kinsokuCompression',
    ]) {
      if (json[key] != null && json[key] is! bool) {
        throw const FormatException('阅读偏好格式有误');
      }
    }
    if (json['backgroundImage'] != null &&
        !validBackgroundId(json['backgroundImage'])) {
      throw const FormatException('阅读背景记录有误');
    }
    List<ReaderTapZoneAction> parsedTapGrid = defaultReaderTapGrid;
    if (json['tapGrid'] case final List<dynamic> rawGrid
        when rawGrid.length == 9) {
      parsedTapGrid = [
        for (final item in rawGrid)
          ReaderTapZoneAction.values.firstWhere(
            (v) => v.name == item,
            orElse: () => ReaderTapZoneAction.nextPage,
          ),
      ];
    }
    return ReaderPreferences(
      paper: ReaderPaper.values.firstWhere(
        (p) => p.name == (json['paper'] ?? 'system'),
      ),
      margin: number('margin', 0, 80, 26),
      marginLeft: json['marginLeft'] == null
          ? null
          : number('marginLeft', 0, 80, 26),
      marginRight: json['marginRight'] == null
          ? null
          : number('marginRight', 0, 80, 26),
      marginTop: number('marginTop', 0, 80, 8),
      marginBottom: number('marginBottom', 0, 80, 8),
      paragraphGap: number('paragraphGap', 0, 32, 12),
      paragraphGapOverride:
          json['paragraphGapOverride'] as bool? ??
          number('paragraphGap', 0, 32, 12) != 12,
      catalogueReversed: json['catalogueReversed'] == true,
      indent: json['indent'] == true,
      justify: json['justify'] == true,
      tapPaging: json['tapPaging'] == true,
      tapBothSidesNext: json['tapBothSidesNext'] == true,
      volumePaging: json['volumePaging'] == true,
      brightness: json['brightness'] == null
          ? null
          : number('brightness', 0, 1, 1),
      nightTextBrightness: number('nightTextBrightness', .35, 1, .82),
      letterSpacing: number('letterSpacing', -.5, 3, .1),
      textWeight: ReaderTextWeight.values.byName(
        json['textWeight'] ?? 'regular',
      ),
      statusSideInset: number('statusSideInset', 0, 96, 0),
      statusFontSize: number('statusFontSize', 9, 18, 12),
      statusTopOffset: number('statusTopOffset', -8, 24, 0),
      backgroundImage: json['backgroundImage'] as String?,
      backgroundOpacity: number('backgroundOpacity', .05, 1, .18),
      backgroundFit: (json['backgroundFit'] ?? 'cover') == 'contain'
          ? BoxFit.contain
          : BoxFit.cover,
      warmth: number('warmth', 0, readerWarmthMax, 0),
      autoScrollSpeed: number('autoScrollSpeed', 8, 80, 24),
      mode: ReaderMode.values.byName(json['mode'] ?? 'scroll'),
      verticalLatinOrientation: ReaderVerticalLatinOrientation.values.byName(
        json['verticalLatinOrientation'] ?? 'rotated',
      ),
      tapLayout: ReaderTapLayout.values.firstWhere(
        (v) => v.name == (json['tapLayout'] ?? 'standard'),
        orElse: () => ReaderTapLayout.standard,
      ),
      edgeBrightness: json['edgeBrightness'] == true,
      hideSystemStatus: json['hideSystemStatus'] == true,
      showStatusInfo: json['showStatusInfo'] != false,
      chapterEntrance: json['chapterEntrance'] == true,
      pageEffect: ReaderPageEffect.values.byName(
        json['pageEffect'] ?? 'staggered',
      ),
      pageSpeed: ReaderPageSpeed.values.byName(json['pageSpeed'] ?? 'normal'),
      edgeDeadZone: number('edgeDeadZone', 0, 48, 0),
      tapGrid: parsedTapGrid,
      autoPageMode: ReaderAutoPageMode.values.firstWhere(
        (v) => v.name == (json['autoPageMode'] ?? 'off'),
        orElse: () => ReaderAutoPageMode.off,
      ),
      kinsokuCompression: json['kinsokuCompression'] != false,
    );
  }
  static ReaderPreferences fromRecord(Object? record) {
    try {
      return ReaderPreferences.fromJson(jsonDecode(record as String));
    } catch (_) {
      return const ReaderPreferences();
    }
  }

  ReaderPreferences copyWith({
    ReaderPaper? paper,
    double? margin,
    double? marginLeft,
    double? marginRight,
    double? marginTop,
    double? marginBottom,
    double? paragraphGap,
    bool? paragraphGapOverride,
    bool? catalogueReversed,
    bool? indent,
    bool? justify,
    bool? tapPaging,
    bool? tapBothSidesNext,
    bool? volumePaging,
    double? brightness,
    bool systemBrightness = false,
    double? autoScrollSpeed,
    ReaderMode? mode,
    ReaderVerticalLatinOrientation? verticalLatinOrientation,
    ReaderTapLayout? tapLayout,
    bool? edgeBrightness,
    ReaderPageEffect? pageEffect,
    ReaderPageSpeed? pageSpeed,
    bool? hideSystemStatus,
    bool? showStatusInfo,
    bool? chapterEntrance,
    double? nightTextBrightness,
    double? letterSpacing,
    ReaderTextWeight? textWeight,
    double? statusSideInset,
    double? statusFontSize,
    double? statusTopOffset,
    String? backgroundImage,
    bool clearBackground = false,
    double? backgroundOpacity,
    BoxFit? backgroundFit,
    double? warmth,
    double? edgeDeadZone,
    List<ReaderTapZoneAction>? tapGrid,
    ReaderAutoPageMode? autoPageMode,
    bool? kinsokuCompression,
  }) => ReaderPreferences(
    paper: paper ?? this.paper,
    margin: margin ?? this.margin,
    marginLeft: marginLeft ?? (margin ?? this.marginLeft),
    marginRight: marginRight ?? (margin ?? this.marginRight),
    marginTop: marginTop ?? this.marginTop,
    marginBottom: marginBottom ?? this.marginBottom,
    paragraphGap: paragraphGap ?? this.paragraphGap,
    paragraphGapOverride: paragraphGapOverride ?? this.paragraphGapOverride,
    catalogueReversed: catalogueReversed ?? this.catalogueReversed,
    indent: indent ?? this.indent,
    justify: justify ?? this.justify,
    tapPaging: tapPaging ?? this.tapPaging,
    tapBothSidesNext: tapBothSidesNext ?? this.tapBothSidesNext,
    volumePaging: volumePaging ?? this.volumePaging,
    brightness: systemBrightness ? null : brightness ?? this.brightness,
    autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
    mode: mode ?? this.mode,
    verticalLatinOrientation:
        verticalLatinOrientation ?? this.verticalLatinOrientation,
    tapLayout: tapLayout ?? this.tapLayout,
    edgeBrightness: edgeBrightness ?? this.edgeBrightness,
    pageEffect: pageEffect ?? this.pageEffect,
    pageSpeed: pageSpeed ?? this.pageSpeed,
    hideSystemStatus: hideSystemStatus ?? this.hideSystemStatus,
    showStatusInfo: showStatusInfo ?? this.showStatusInfo,
    chapterEntrance: chapterEntrance ?? this.chapterEntrance,
    nightTextBrightness: nightTextBrightness ?? this.nightTextBrightness,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    textWeight: textWeight ?? this.textWeight,
    statusSideInset: statusSideInset ?? this.statusSideInset,
    statusFontSize: statusFontSize ?? this.statusFontSize,
    statusTopOffset: statusTopOffset ?? this.statusTopOffset,
    backgroundImage: clearBackground
        ? null
        : backgroundImage ?? this.backgroundImage,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    backgroundFit: backgroundFit ?? this.backgroundFit,
    warmth: warmth ?? this.warmth,
    edgeDeadZone: edgeDeadZone ?? this.edgeDeadZone,
    tapGrid: tapGrid ?? this.tapGrid,
    autoPageMode: autoPageMode ?? this.autoPageMode,
    kinsokuCompression: kinsokuCompression ?? this.kinsokuCompression,
  );

  /// A book can keep its typography while interaction and device settings
  /// continue to follow the shared reader. Explicit null margins stay null.
  ReaderPreferences withLayoutOf(ReaderPreferences layout) => ReaderPreferences(
    paper: layout.paper,
    margin: layout.margin,
    marginLeft: layout.marginLeft,
    marginRight: layout.marginRight,
    marginTop: layout.marginTop,
    marginBottom: layout.marginBottom,
    paragraphGap: layout.paragraphGap,
    paragraphGapOverride: layout.paragraphGapOverride,
    catalogueReversed: catalogueReversed,
    indent: layout.indent,
    justify: layout.justify,
    mode: layout.mode,
    verticalLatinOrientation: layout.verticalLatinOrientation,
    nightTextBrightness: layout.nightTextBrightness,
    letterSpacing: layout.letterSpacing,
    textWeight: layout.textWeight,
    backgroundImage: layout.backgroundImage,
    backgroundOpacity: layout.backgroundOpacity,
    backgroundFit: layout.backgroundFit,
    tapPaging: tapPaging,
    tapBothSidesNext: tapBothSidesNext,
    volumePaging: volumePaging,
    brightness: brightness,
    autoScrollSpeed: autoScrollSpeed,
    tapLayout: tapLayout,
    edgeBrightness: edgeBrightness,
    pageEffect: pageEffect,
    pageSpeed: pageSpeed,
    hideSystemStatus: hideSystemStatus,
    showStatusInfo: showStatusInfo,
    chapterEntrance: chapterEntrance,
    statusSideInset: statusSideInset,
    statusFontSize: statusFontSize,
    statusTopOffset: statusTopOffset,
    warmth: warmth,
    edgeDeadZone: edgeDeadZone,
    tapGrid: tapGrid,
    autoPageMode: autoPageMode,
    kinsokuCompression: layout.kinsokuCompression,
  );
}
