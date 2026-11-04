import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'app_ui.dart';
import 'reading_export_theme.dart';
import 'reading_visual_theme.dart';
import 'performance_preferences.dart';

/// Optional surface-specific artwork and copy, without changing persisted IDs.
class ReadingVisualThemePresentation {
  const ReadingVisualThemePresentation({
    required this.label,
    required this.description,
    required this.artAsset,
    required this.background,
    required this.foreground,
    required this.secondary,
    this.alignment = Alignment.centerRight,
    this.prefersSerif = false,
  });

  factory ReadingVisualThemePresentation.fromTheme(ReadingVisualTheme theme) =>
      ReadingVisualThemePresentation(
        label: theme.label,
        description: theme.description,
        artAsset: theme.artAsset,
        background: theme.background,
        foreground: theme.foreground,
        secondary: theme.secondary,
      );

  factory ReadingVisualThemePresentation.fromExportTheme(
    ReadingVisualTheme theme, {
    DateTime? at,
  }) {
    final style = readingExportTheme(theme);
    return ReadingVisualThemePresentation(
      label: style.label,
      description: style.description,
      artAsset: readingExportArt(theme, at: at),
      background: style.background,
      foreground: style.foreground,
      secondary: style.secondary,
      alignment: style.previewAlignment,
      prefersSerif: style.prefersSerif,
    );
  }

  final String label, description, artAsset;
  final Color background, foreground, secondary;
  final Alignment alignment;
  final bool prefersSerif;
}

/// Stable theme choices, optionally using a surface's own art direction.
class ReadingVisualThemePicker extends StatelessWidget {
  const ReadingVisualThemePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.presentationFor,
  });
  final ReadingVisualTheme value;
  final ValueChanged<ReadingVisualTheme>? onChanged;
  final ReadingVisualThemePresentation Function(ReadingVisualTheme)?
  presentationFor;

  ReadingVisualThemePresentation _presentation(ReadingVisualTheme theme) =>
      presentationFor?.call(theme) ??
      ReadingVisualThemePresentation.fromTheme(theme);

  @override
  Widget build(BuildContext context) => presentationFor != null
      ? _ExportThemeGallery(
          value: value,
          onChanged: onChanged,
          presentationFor: _presentation,
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 560 ? 4 : 2;
                final width =
                    (constraints.maxWidth - 12 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final theme in ReadingVisualTheme.values)
                      _choice(theme, _presentation(theme), width),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            AppText(
              _presentation(value).description,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: _presentation(value).prefersSerif
                    ? 'ReadingSerifDisplay'
                    : null,
                fontFamilyFallback: _presentation(value).prefersSerif
                    ? const ['CupertinoSystemText']
                    : null,
                fontWeight: _presentation(value).prefersSerif
                    ? FontWeight.w700
                    : null,
              ),
            ),
          ],
        );

  Widget _choice(
    ReadingVisualTheme theme,
    ReadingVisualThemePresentation presentation,
    double width,
  ) => Semantics(
    selected: value == theme,
    button: true,
    label: '${presentation.label}，${presentation.description}',
    child: SizedBox(
      width: width,
      height: 146,
      child: Material(
        color: presentation.background,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('reading-theme-${theme.id}'),
          onTap: onChanged == null ? null : () => onChanged!(theme),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: value == theme
                    ? presentation.foreground
                    : presentation.foreground.withValues(alpha: .12),
                width: value == theme ? 2 : .75,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                children: [
                  Expanded(child: _ThemePreview(presentation)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: AppText(
                          presentation.label,
                          style: TextStyle(
                            color: presentation.foreground,
                            fontSize: 13,
                            fontWeight: presentation.prefersSerif
                                ? FontWeight.w700
                                : FontWeight.w600,
                            fontFamily: presentation.prefersSerif
                                ? 'ReadingSerifDisplay'
                                : null,
                            fontFamilyFallback: presentation.prefersSerif
                                ? const ['CupertinoSystemText']
                                : null,
                          ),
                        ),
                      ),
                      if (value == theme)
                        Icon(
                          CupertinoIcons.check_mark_circled_solid,
                          size: 16,
                          color: presentation.foreground,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ExportThemeGallery extends StatefulWidget {
  const _ExportThemeGallery({
    required this.value,
    required this.onChanged,
    required this.presentationFor,
  });
  final ReadingVisualTheme value;
  final ValueChanged<ReadingVisualTheme>? onChanged;
  final ReadingVisualThemePresentation Function(ReadingVisualTheme)
  presentationFor;

  @override
  State<_ExportThemeGallery> createState() => _ExportThemeGalleryState();
}

class _ExportThemeGalleryState extends State<_ExportThemeGallery> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(false));
  }

  @override
  void didUpdateWidget(_ExportThemeGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(true));
    }
  }

  void _reveal(bool animate) {
    if (!mounted || !_scroll.hasClients) return;
    final target =
        (widget.value.index * 122.0 -
                (_scroll.position.viewportDimension - 110) / 2)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    if (animate && !PerformanceScope.reduceMotionOf(context)) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TextStyle _type(ReadingVisualThemePresentation p, double size) => TextStyle(
    color: p.foreground,
    fontSize: size,
    fontWeight: FontWeight.w700,
    fontFamily: p.prefersSerif ? 'ReadingSerifDisplay' : null,
    fontFamilyFallback: p.prefersSerif ? const ['CupertinoSystemText'] : null,
  );

  Widget _art(ReadingVisualThemePresentation p, {int width = 300}) =>
      Image.asset(
        p.artAsset,
        fit: BoxFit.cover,
        alignment: p.alignment,
        cacheWidth: width,
        excludeFromSemantics: true,
        errorBuilder: (_, error, stack) => ColoredBox(color: p.secondary),
      );

  @override
  Widget build(BuildContext context) {
    final duration = PerformanceScope.reduceMotionOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return SingleChildScrollView(
      key: const ValueKey('reading-theme-gallery'),
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final theme in ReadingVisualTheme.values)
            Padding(
              padding: EdgeInsets.only(
                right: theme == ReadingVisualTheme.values.last ? 0 : 12,
              ),
              child: _thumbnail(context, theme, duration),
            ),
        ],
      ),
    );
  }

  Widget _thumbnail(
    BuildContext context,
    ReadingVisualTheme theme,
    Duration duration,
  ) {
    final p = widget.presentationFor(theme);
    final selected = theme == widget.value;
    final ink = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      label: p.label,
      child: SizedBox(
        width: 110,
        child: Material(
          color: Colors.transparent,
          child: JellyTapSurface(
            tapKey: ValueKey('reading-theme-${theme.id}'),
            haptic: HapticCue.selection,
            onTap: widget.onChanged == null || selected
                ? null
                : () => widget.onChanged!(theme),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: duration,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? ink : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      height: 114,
                      width: 101,
                      child: _art(p, width: 300),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: AppText(
                    p.label,
                    style: _type(p, 13).copyWith(
                      color: ink.withValues(alpha: selected ? 1 : .6),
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview(this.presentation);
  final ReadingVisualThemePresentation presentation;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox.expand(
      child: Image.asset(
        presentation.artAsset,
        fit: BoxFit.cover,
        alignment: presentation.alignment,
        cacheWidth: 420,
        excludeFromSemantics: true,
        errorBuilder: (context, error, stackTrace) => ColoredBox(
          color: presentation.secondary,
          child: Icon(CupertinoIcons.photo, color: presentation.foreground),
        ),
      ),
    ),
  );
}
