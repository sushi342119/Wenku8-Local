import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_palette.dart';
import 'app_ui.dart';
import 'glass_palette.dart';
import 'library_state.dart';
import 'performance_preferences.dart';
import 'reader_preferences.dart';

/// Shared reading skeleton for TXT / EPUB / PDF (design 2026-11 §5.3).
///
/// * [ReaderPaperScope] applies the reader paper and warm light to one
///   reader subtree; the rest of the app keeps its own theme.
/// * Reader controls are solid panels: [ReaderSolidScope] turns glass
///   refraction and backdrop blur off for everything inside the reader.
/// * [ReaderActionBar] gives every format the same four buttons
///   (目录 / 排版 / 亮度 / 听书). Unsupported ones stay visible, greyed, and
///   explain why when tapped.

ThemeData readerPaperTheme(ThemeData base, ReaderPreferences prefs) {
  final appDark = base.brightness == Brightness.dark;
  if (prefs.paper == ReaderPaper.system) return base;
  final dark = prefs.darkPaper(appDark);
  final background = prefs.background(appDark);
  final ink = prefs.foreground(appDark);
  final control = prefs.controlForeground(appDark);
  final panel = prefs.panel(appDark);
  final muted = Color.lerp(background, control, dark ? .62 : .66)!;
  final scheme = base.colorScheme.copyWith(
    brightness: dark ? Brightness.dark : Brightness.light,
    surface: background,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: background,
    surfaceContainerLow: panel,
    surfaceContainer: panel,
    surfaceContainerHigh: Color.lerp(panel, control, .05),
    surfaceContainerHighest: Color.lerp(panel, control, .09),
    outlineVariant: Color.lerp(panel, control, .14),
    primary: dark && !appDark ? base.colorScheme.inversePrimary : null,
  );
  final tonal = base.extension<AppTonalColors>();
  return base.copyWith(
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    dividerColor: scheme.outlineVariant,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    iconTheme: base.iconTheme.copyWith(color: control),
    extensions: [
      for (final extension in base.extensions.values)
        if (extension is! GlassPalette &&
            extension is! AppTonalColors &&
            extension is! PageWash)
          extension,
      // Solid reader panels take the paper's control-panel colour.
      GlassPalette(tint: panel, thumb: dark ? control : Colors.white),
      if (tonal != null)
        tonal.copyWith(
          milk: panel,
          darkMilk: panel,
          glassSurface: panel,
          thumb: dark ? control : Colors.white,
          action: control,
        ),
    ],
  );
}

/// Glass refraction and backdrop blur are off for the whole reader; other
/// effect switches (motion, edge blur ≤ σ4) are inherited unchanged.
class ReaderSolidScope extends StatelessWidget {
  const ReaderSolidScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = PerformanceScope.of(context);
    final effects = {
      for (final effect in PerformanceEffect.values)
        if (effect != PerformanceEffect.glass &&
            effect != PerformanceEffect.blur &&
            parent.allows(effect))
          effect,
    };
    return PerformanceScope(
      preferences: PerformancePreferences(enabled: true, effects: effects),
      explicitReduceMotion: PerformanceScope.reduceMotionOf(context),
      child: child,
    );
  }
}

/// Paper theme + solid controls + warm-light overlay for one reader.
class ReaderPaperScope extends StatefulWidget {
  const ReaderPaperScope({super.key, required this.state, required this.child});
  final LibraryState state;
  final Widget child;

  @override
  State<ReaderPaperScope> createState() => _ReaderPaperScopeState();
}

class _ReaderPaperScopeState extends State<ReaderPaperScope> {
  ThemeData? _base;
  ReaderPreferences? _prefs;
  ThemeData? _theme;

  ThemeData _resolve(ThemeData base, ReaderPreferences prefs) {
    final cached = _theme;
    if (cached != null &&
        identical(base, _base) &&
        _prefs?.paper == prefs.paper &&
        _prefs?.nightTextBrightness == prefs.nightTextBrightness) {
      return cached;
    }
    _base = base;
    _prefs = prefs;
    return _theme = readerPaperTheme(base, prefs);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state.readerSettingsChanges,
    child: widget.child,
    builder: (context, child) {
      final prefs = widget.state.readerPreferences;
      final base = Theme.of(context);
      final theme = _resolve(base, prefs);
      final warm = prefs.warmth > 0;
      Widget content = ReaderSolidScope(child: child!);
      if (!identical(theme, base)) {
        content = Theme(data: theme, child: content);
      }
      if (!warm) return content;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                key: const ValueKey('reader-warm-light'),
                color: readerWarmthOverlay(prefs.warmth),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// One bottom-bar button. A null [onPressed] with an [unavailable] reason
/// keeps the button visible but grey; tapping it explains the reason.
class ReaderAction {
  const ReaderAction({
    required this.icon,
    required this.caption,
    required this.label,
    this.onPressed,
    this.unavailable,
    this.key,
  });
  final IconData icon;
  final String caption, label;
  final VoidCallback? onPressed;
  final String? unavailable;
  final Key? key;
}

class ReaderActionBar extends StatelessWidget {
  const ReaderActionBar({super.key, required this.actions});
  final List<ReaderAction> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      key: const ValueKey('reader-action-bar'),
      children: [
        for (final action in actions)
          Expanded(
            child: Opacity(
              opacity: action.unavailable == null ? 1 : .42,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    key: action.key,
                    icon: action.icon,
                    label: action.label,
                    transparent: true,
                    onPressed: action.unavailable != null
                        ? () => showNovelFeedback(context, action.unavailable!)
                        : action.onPressed,
                  ),
                  Text(
                    action.caption,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Solid bottom panel (radius 24): progress, optional navigation, actions.
class ReaderBottomPanel extends StatelessWidget {
  const ReaderBottomPanel({
    super.key,
    required this.actions,
    this.progress,
    this.navigation,
  });
  final Widget? progress;
  final Widget? navigation;
  final List<ReaderAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color =
        theme.extension<GlassPalette>()?.tint ??
        theme.colorScheme.surfaceContainerLow;
    return DecoratedBox(
      key: const ValueKey('reader-bottom-panel'),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(ArchiveDesign.sheetRadius),
        border: dark
            ? Border.all(color: Colors.white.withValues(alpha: .08))
            : null,
        boxShadow: dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x1F101828),
                  blurRadius: 32,
                  offset: Offset(0, 12),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?progress,
            ?navigation,
            ReaderActionBar(actions: actions),
          ],
        ),
      ),
    );
  }
}

/// 11sp status line shown while the controls are hidden.
class ReaderStatusLine extends StatefulWidget {
  const ReaderStatusLine({
    super.key,
    required this.chrome,
    required this.text,
  });
  final Animation<double> chrome;
  final String text;

  @override
  State<ReaderStatusLine> createState() => _ReaderStatusLineState();
}

class _ReaderStatusLineState extends State<ReaderStatusLine> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: widget.chrome,
        builder: (context, _) {
          final hidden = 1 - widget.chrome.value;
          if (hidden == 0) return const SizedBox.shrink();
          return Opacity(
            opacity: .55 * hidden,
            child: Text(
              '${widget.text} · $time',
              key: const ValueKey('reader-status-line'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 亮度 sheet: paper, night text brightness, warm light and PDF inversion.
/// The settings page opens the same panel, so both edit one record.
Future<void> showReaderAppearanceSheet(
  BuildContext context, {
  required LibraryState state,
  bool pdf = false,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: state.reduceMotion || MediaQuery.disableAnimationsOf(context),
  builder: (context) => ReaderAppearancePanel(state: state, pdf: pdf),
);

class ReaderAppearancePanel extends StatefulWidget {
  const ReaderAppearancePanel({super.key, required this.state, this.pdf = false});
  final LibraryState state;
  final bool pdf;

  @override
  State<ReaderAppearancePanel> createState() => _ReaderAppearancePanelState();
}

class _ReaderAppearancePanelState extends State<ReaderAppearancePanel> {
  double? _brightness, _warmth;
  LibraryState get state => widget.state;

  Future<void> _save(ReaderPreferences next) async {
    try {
      await state.setReaderPreferences(next);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '阅读设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.readerSettingsChanges,
    builder: (context, _) {
      final prefs = state.readerPreferences;
      final appDark = Theme.of(context).brightness == Brightness.dark;
      final scheme = Theme.of(context).colorScheme;
      final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
      final darkPaper = prefs.darkPaper(appDark);
      return SingleChildScrollView(
        key: const ValueKey('reader-appearance-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '亮度与纸色', code: 'READER / PAPER'),
            const SizedBox(height: 4),
            Text('与“设置 → 阅读偏好”是同一份设置，任一处修改都会同步。', style: muted),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final paper in ReaderPaper.choices)
                  _swatch(context, prefs, paper, appDark),
              ],
            ),
            const Divider(height: 28),
            _sliderLabel('夜读正文亮度', '${((_brightness ?? prefs.nightTextBrightness) * 100).round()}%'),
            CupertinoSlider(
              key: const ValueKey('reader-night-brightness'),
              value: _brightness ?? prefs.nightTextBrightness,
              min: .35,
              max: 1,
              onChanged: darkPaper
                  ? (value) => setState(() => _brightness = value)
                  : null,
              onChangeEnd: (value) async {
                await _save(prefs.copyWith(nightTextBrightness: value));
                if (mounted) setState(() => _brightness = null);
              },
            ),
            if (!darkPaper) Text('仅在深色纸色（夜读、纯黑或深色外观）下生效。', style: muted),
            const SizedBox(height: 12),
            _sliderLabel('暖光', '${((_warmth ?? prefs.warmth) * 100).round()}%'),
            CupertinoSlider(
              key: const ValueKey('reader-warmth'),
              value: _warmth ?? prefs.warmth,
              min: 0,
              max: readerWarmthMax,
              onChanged: (value) => setState(() => _warmth = value),
              onChangeEnd: (value) async {
                await _save(prefs.copyWith(warmth: value));
                if (mounted) setState(() => _warmth = null);
              },
            ),
            const Divider(height: 28),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('夜读时反色 PDF', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        widget.pdf ? '深色纸色下将 PDF 页面反相显示' : '仅影响 PDF：深色纸色下反相页面',
                        style: muted,
                      ),
                    ],
                  ),
                ),
                CupertinoSwitch(
                  key: const ValueKey('reader-pdf-invert'),
                  value: state.pdfNightInvert,
                  activeTrackColor: scheme.primary,
                  onChanged: (value) async {
                    try {
                      await state.setPdfNightInvert(value);
                    } catch (_) {
                      if (context.mounted) showNovelFeedback(context, '设置保存失败，请重试');
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _sliderLabel(String title, String value) => Row(
    children: [
      Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
      Text(value, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ],
  );

  Widget _swatch(
    BuildContext context,
    ReaderPreferences prefs,
    ReaderPaper paper,
    bool appDark,
  ) {
    final sample = prefs.copyWith(paper: paper);
    final selected = prefs.paper == paper;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '纸色 ${paper.label}',
      child: GestureDetector(
        key: ValueKey('reader-paper-${paper.name}'),
        onTap: () => _save(prefs.copyWith(paper: paper)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sample.background(appDark),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Text(
                '文',
                style: TextStyle(color: sample.foreground(appDark), fontSize: 16),
              ),
            ),
            const SizedBox(height: 4),
            Text(paper.label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
