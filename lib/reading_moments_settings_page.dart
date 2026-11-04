import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'reading_keepsake_theme.dart';
import 'reading_moment_content.dart';
import 'reading_moments.dart';
import 'reading_moments_ui.dart';
import 'reading_visual_theme.dart';
import 'reading_visual_theme_picker.dart';

/// Controls celebrations without changing verified reading or its history.
class ReadingMomentsSettingsPage extends StatelessWidget {
  const ReadingMomentsSettingsPage({super.key, required this.state});
  final LibraryState state;

  Future<void> _save(
    BuildContext context,
    ReadingMomentsPreferences value,
  ) async {
    try {
      await state.readingMoments.setPreferences(value);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '设置未能保存，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '阅读纪念',
    code: 'READING / MOMENTS',
    child: ListenableBuilder(
      listenable: state.readingMoments,
      builder: (context, _) {
        final prefs = state.readingMoments.preferences;
        final visual = ReadingVisualTheme.fromId(prefs.themeId);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListView(
              key: const ValueKey('reading-moments-settings-list'),
              padding: featurePadding(context),
              children: [
                ContentPanel(
                  child: _option(
                    context,
                    title: '阅读纪念弹窗',
                    subtitle: '在读到书尾或离开阅读时，庆祝新的时刻',
                    switchKey: 'reading-moments-enabled',
                    value: prefs.enabled,
                    onChanged: (value) =>
                        _save(context, prefs.copyWith(enabled: value)),
                  ),
                ),
                const SizedBox(height: 12),
                AppText(
                  '关闭弹窗仍会记录阅读与纪念，重新开启不会补放旧弹窗。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                const ArchiveSection(title: '纪念方式', code: '01 / CELEBRATIONS'),
                const SizedBox(height: 14),
                ContentPanel(
                  child: Column(
                    children: [
                      _option(
                        context,
                        title: '阅读里程碑',
                        subtitle: '首个阅读日、连续阅读与累计时光',
                        switchKey: 'reading-moments-milestones',
                        value: prefs.milestones,
                        onChanged: prefs.enabled
                            ? (value) => _save(
                                context,
                                prefs.copyWith(milestones: value),
                              )
                            : null,
                      ),
                      const Divider(height: 28),
                      _option(
                        context,
                        title: '书页终点',
                        subtitle: '读完一本书，或读到连载的当前结尾',
                        switchKey: 'reading-moments-completions',
                        value: prefs.completions,
                        onChanged: prefs.enabled
                            ? (value) => _save(
                                context,
                                prefs.copyWith(completions: value),
                              )
                            : null,
                      ),
                      const Divider(height: 28),
                      _option(
                        context,
                        title: '轻盈礼花',
                        subtitle: '跟随系统的减少动态效果设置',
                        switchKey: 'reading-moments-confetti',
                        value: prefs.confetti,
                        onChanged: prefs.enabled
                            ? (value) => _save(
                                context,
                                prefs.copyWith(confetti: value),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                const ArchiveSection(title: '纪念图片', code: '02 / IMAGE'),
                const SizedBox(height: 14),
                ReadingVisualThemePicker(
                  value: visual,
                  presentationFor: (theme) => readingKeepsakeThemePresentation(
                    theme,
                    recordedAt: ReadingMomentPresentation.preview(
                      theme,
                    ).moment.earnedAt,
                  ),
                  onChanged: (theme) =>
                      _save(context, prefs.copyWith(themeId: theme.id)),
                ),
                const SizedBox(height: 16),
                GlassTextButton(
                  key: const ValueKey('reading-moments-preview'),
                  onPressed: () => showReadingMomentPreview(
                    context,
                    reduceMotion: state.reduceMotion,
                    theme: visual,
                    confetti: prefs.confetti,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ArchiveIcon(CupertinoIcons.play_circle, size: 19),
                      SizedBox(width: 10),
                      AppText('预览效果'),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                FeatureEntry(
                  title: '我的阅读纪念',
                  subtitle: state.readingMoments.moments.isEmpty
                      ? null
                      : '已珍藏 ${state.readingMoments.moments.length} 个时刻',
                  icon: CupertinoIcons.bookmark,
                  onTap: () => showReadingMomentsHistory(
                    context,
                    store: state.readingMoments,
                    reduceMotion: state.reduceMotion,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _option(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String switchKey,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            AppText(
              subtitle,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Semantics(
        label: title,
        child: AppControls.toggle(
          context,
          key: ValueKey(switchKey),
          value: value,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}
