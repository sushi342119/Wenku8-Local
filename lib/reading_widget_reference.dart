import 'package:flutter/material.dart';

import 'reading_widget_design.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

enum ReadingDesktopSize {
  small(Size(170, 170)),
  medium(Size(364, 170)),
  large(Size(364, 364));

  const ReadingDesktopSize(this.logicalSize);
  final Size logicalSize;
}

class ReadingDesktopCard extends StatelessWidget {
  const ReadingDesktopCard({
    super.key,
    required this.data,
    required this.size,
    required this.brightness,
    this.quoteText,
    this.quoteSource = '',
    this.quoteCount = 0,
  });

  final ReadingWidgetSnapshot data;
  final ReadingDesktopSize size;
  final Brightness brightness;
  final String? quoteText;
  final String quoteSource;
  final int quoteCount;

  @override
  Widget build(BuildContext context) {
    final isDark = brightness == Brightness.dark;
    final (bg, fg, accent) = _paletteFor(data.skin, isDark);
    final todayMin = widgetMinutes(data.verifiedTodaySeconds);
    final totalMin = widgetMinutes(data.verifiedTotalSeconds);
    final streak = data.qualifiedStreakDays ?? 0;

    return SizedBox(
      width: size.logicalSize.width,
      height: size.logicalSize.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: fg.withValues(alpha: 0.12)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${data.design.label} · ${data.skin.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.68),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (data.design == ReadingWidgetDesign.quote) ...[
                Text(
                  (quoteText == null || quoteText!.trim().isEmpty)
                      ? '在阅读器中收藏书签或划线，桌面将展示你的摘录句子。'
                      : quoteText!,
                  maxLines: size == ReadingDesktopSize.large ? 6 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (quoteSource.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    quoteSource,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                ],
              ] else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      todayMin,
                      style: TextStyle(
                        color: fg,
                        fontSize: size == ReadingDesktopSize.small ? 30 : 34,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '分钟今日阅读',
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.68),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  data.showBookDetails && data.currentBook != null
                      ? '正在读《${data.currentBook!.title}》'
                      : '累计 $totalMin 分钟 · 连续 $streak 天',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.68),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static (Color, Color, Color) _paletteFor(
    ReadingWidgetSkin skin,
    bool isDark,
  ) {
    if (isDark) {
      return switch (skin) {
        ReadingWidgetSkin.original => (
          const Color(0xFF1A1917),
          const Color(0xFFF3EFEA),
          const Color(0xFFD0A97E),
        ),
        ReadingWidgetSkin.seasons => (
          const Color(0xFF18221F),
          const Color(0xFFEAF2EE),
          const Color(0xFF7FC8A9),
        ),
        ReadingWidgetSkin.archive => (
          const Color(0xFF1E1C1A),
          const Color(0xFFF2ECE1),
          const Color(0xFFC89D66),
        ),
        ReadingWidgetSkin.editorial => (
          const Color(0xFF17181C),
          const Color(0xFFF4F4F6),
          const Color(0xFFE07A5F),
        ),
        ReadingWidgetSkin.ink => (
          const Color(0xFF161616),
          const Color(0xFFEFECE6),
          const Color(0xFFC85A48),
        ),
        ReadingWidgetSkin.constellation => (
          const Color(0xFF111622),
          const Color(0xFFE8EEF9),
          const Color(0xFF8AB4F8),
        ),
      };
    }
    return switch (skin) {
      ReadingWidgetSkin.original => (
        const Color(0xFFF7F3EB),
        const Color(0xFF22201D),
        const Color(0xFF8B5E34),
      ),
      ReadingWidgetSkin.seasons => (
        const Color(0xFFF1F6F2),
        const Color(0xFF1D2A24),
        const Color(0xFF3E7B5F),
      ),
      ReadingWidgetSkin.archive => (
        const Color(0xFFF5EFE4),
        const Color(0xFF26221E),
        const Color(0xFF9C6B3B),
      ),
      ReadingWidgetSkin.editorial => (
        const Color(0xFFF6F5F2),
        const Color(0xFF1C1D21),
        const Color(0xFFC8553D),
      ),
      ReadingWidgetSkin.ink => (
        const Color(0xFFF4F1EA),
        const Color(0xFF1E1E1E),
        const Color(0xFFB23A2B),
      ),
      ReadingWidgetSkin.constellation => (
        const Color(0xFFEEF2F9),
        const Color(0xFF182032),
        const Color(0xFF3B68B8),
      ),
    };
  }
}
