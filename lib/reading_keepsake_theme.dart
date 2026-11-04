import 'package:flutter/painting.dart';

import 'reading_export_theme.dart';
import 'reading_visual_theme.dart';
import 'reading_visual_theme_picker.dart';

/// Selects artwork only. Callers keep the actual recorded date separate.
String readingKeepsakeArt(
  ReadingVisualTheme theme, {
  DateTime? recordedAt,
  DateTime? artAt,
  bool portrait = false,
}) => readingExportArt(theme, at: recordedAt ?? artAt, portrait: portrait);

ReadingVisualThemePresentation readingKeepsakeThemePresentation(
  ReadingVisualTheme theme, {
  DateTime? recordedAt,
  DateTime? artAt,
}) {
  final style = readingExportTheme(theme);
  return ReadingVisualThemePresentation(
    label: style.label,
    description: style.description,
    artAsset: readingKeepsakeArt(theme, recordedAt: recordedAt, artAt: artAt),
    background: style.background,
    foreground: style.foreground,
    secondary: style.secondary,
    prefersSerif: style.prefersSerif,
    alignment: theme == ReadingVisualTheme.editorial
        ? Alignment.centerRight
        : style.previewAlignment,
  );
}
