import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_state.dart';

class RecentSearches extends StatelessWidget {
  const RecentSearches({
    super.key,
    required this.state,
    required this.onRecall,
  });
  final LibraryState state;
  final ValueChanged<String> onRecall;

  Future<void> _clear(BuildContext context) async {
    FocusScope.of(context).unfocus();
    final confirmed = await showJellySheet<bool>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (sheet) => SingleChildScrollView(
        primary: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '清空最近搜索？',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text('只清除本机关键词，不影响书架、阅读进度或书签。'),
              const SizedBox(height: 16),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet, true),
                child: const Text('清空搜索记录'),
              ),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet, false),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await state.clearRecentSearches();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '搜索记录清除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.searchChanges,
    builder: (context, _) {
      final recent = state.recentSearches;
      if (recent.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近搜索',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                GlassIconButton(
                  icon: CupertinoIcons.trash,
                  label: '清空最近搜索',
                  onPressed: () => _clear(context),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final query in recent)
                  JellyTapSurface(
                    key: ValueKey('recent-search-$query'),
                    onTap: () => onRecall(query),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: .055),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        query,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
