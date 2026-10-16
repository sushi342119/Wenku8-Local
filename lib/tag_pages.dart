import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_tags.dart';
import 'feature_pages.dart';
import 'library_state.dart';

/// 为某本书勾选标签；支持现场新建。
Future<void> showTagEditor(
  BuildContext context,
  LibraryState state,
  int bookId,
) async {
  final store = TagStore.shared;
  final selected = store.tagsForBook(bookId).map((t) => t.id).toSet();
  final controller = TextEditingController();
  bool saved = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('标签'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (store.tags.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('还没有标签，在下方新建一个吧'),
                  ),
                for (final tag in store.tags)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(tag.name),
                    secondary: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: tagPalette[tag.colorIndex % tagPalette.length],
                        shape: BoxShape.circle,
                      ),
                    ),
                    value: selected.contains(tag.id),
                    onChanged: (value) {
                      setDialogState(() {
                        if (value == true) {
                          selected.add(tag.id);
                        } else {
                          selected.remove(tag.id);
                        }
                      });
                    },
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: '新建标签',
                          isDense: true,
                        ),
                        onSubmitted: (_) async {
                          final name = controller.text.trim();
                          if (name.isEmpty) return;
                          final id = await store.createTag(name);
                          controller.clear();
                          setDialogState(() => selected.add(id));
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(CupertinoIcons.add_circled),
                      onPressed: () async {
                        final name = controller.text.trim();
                        if (name.isEmpty) return;
                        final id = await store.createTag(name);
                        controller.clear();
                        setDialogState(() => selected.add(id));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await store.setTagsForBook(bookId, selected);
              saved = true;
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  if (saved && context.mounted) showNovelFeedback(context, '标签已保存');
}

/// 标签库管理：新建、重命名、删除。
class TagManagePage extends StatefulWidget {
  const TagManagePage({super.key, required this.state});
  final LibraryState state;

  @override
  State<TagManagePage> createState() => _TagManagePageState();
}

class _TagManagePageState extends State<TagManagePage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _rename(Tag tag) async {
    final controller = TextEditingController(text: tag.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '标签名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await TagStore.shared.renameTag(tag.id, name);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(Tag tag) async {
    final count = TagStore.shared.bookCountFor(tag.id);
    final confirmed = await confirmNovelAction(
      context,
      title: '删除标签「${tag.name}」？',
      message: count > 0 ? '该标签已用于 $count 本书，将一并清除。' : '该标签尚未使用。',
      confirmLabel: '删除',
      reduceMotion: widget.state.reduceMotion,
    );
    if (confirmed) {
      await TagStore.shared.deleteTag(tag.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TagStore.shared;
    return ArchiveFeaturePage(
      title: '标签管理',
      code: 'TAGS / PERSONAL INDEX',
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => ListView(
          padding: featurePadding(context),
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: '新建标签，回车添加',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _create(),
                  ),
                ),
                const SizedBox(width: 8),
                GlassTextButton(
                  onPressed: _create,
                  child: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (store.tags.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('还没有标签'),
                ),
              ),
            for (final tag in store.tags)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ContentPanel(
                  child: Row(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: tagPalette[tag.colorIndex % tagPalette.length],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tag.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${store.bookCountFor(tag.id)} 本书',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(CupertinoIcons.pencil, size: 18),
                        onPressed: () => _rename(tag),
                      ),
                      IconButton(
                        icon: const Icon(CupertinoIcons.delete, size: 18),
                        onPressed: () => _delete(tag),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    await TagStore.shared.createTag(name);
    _controller.clear();
    if (mounted) setState(() {});
  }
}
