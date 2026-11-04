import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'app_interactions.dart';
import 'library_state.dart';

Future<void> organizeBookmark(
  BuildContext context,
  LibraryState state,
  int novelId,
  ReaderBookmark mark,
) async {
  final text = TextEditingController(text: mark.category);
  try {
    final names =
        state.bookmarkEntries
            .map((e) => e.bookmark.category)
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final category = await showJellySheet<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (sheet) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '书签分类', code: 'EXCERPTS / CATEGORY'),
            const SizedBox(height: 18),
            CupertinoTextField(
              key: const ValueKey('bookmark-category-name'),
              onTap: () => AppHaptics.play(sheet, HapticCue.selection),
              onSubmitted: (_) => AppHaptics.play(sheet, HapticCue.action),
              controller: text,
              maxLength: 30,
              placeholder: '新建或选择分类',
              padding: const EdgeInsets.all(14),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                GlassTextButton(
                  onPressed: () => Navigator.pop(sheet, ''),
                  child: const AppText('未分类'),
                ),
                for (final name in names)
                  GlassTextButton(
                    onPressed: () => Navigator.pop(sheet, name),
                    child: AppText(name),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            GlassPillButton(
              icon: CupertinoIcons.checkmark,
              label: '保存分类',
              onPressed: () => Navigator.pop(sheet, text.text.trim()),
            ),
          ],
        ),
      ),
    );
    if (category != null) {
      await state.categorizeBookmark(novelId, mark.id, category);
    }
  } catch (_) {
    if (context.mounted) showNovelFeedback(context, '书签分类未保存，请重试');
  } finally {
    text.dispose();
  }
}
