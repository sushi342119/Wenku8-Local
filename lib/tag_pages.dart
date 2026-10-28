import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_tags.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_library.dart';

/// 为某本书勾选标签；本地书籍保存时同步改原文件名。
Future<void> showTagEditor(
  BuildContext context,
  LibraryState state,
  int bookId, {
  LocalLibraryStore? local,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TagEditorDialog(bookId: bookId, local: local),
  );
  if (saved == true && context.mounted) showNovelFeedback(context, '标签已保存');
}

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({required this.bookId, this.local});
  final int bookId;
  final LocalLibraryStore? local;
  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  final _store = TagStore.shared;
  final _controller = TextEditingController();
  late final _selected = _store
      .tagsForBook(widget.bookId)
      .map((t) => t.id)
      .toSet();
  bool _busy = false;
  String? _error;

  Future<void> _add() async {
    if (_busy || _controller.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await _store.createTag(_controller.text);
      if (mounted) {
        _controller.clear();
        setState(() => _selected.add(id));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '新建失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (isLocalNovelId(widget.bookId)) {
        final local = widget.local;
        if (local == null) throw StateError('本地书库尚未加载，无法改名');
        await local.setTagsForBook(widget.bookId, _selected);
      } else {
        await _store.setTagsForBook(widget.bookId, _selected);
      }
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '保存失败：$error';
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('标签'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLocalNovelId(widget.bookId))
                const Text('保存后会直接修改源文件名，书籍内容保持不变。'),
              if (_store.tags.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('还没有标签，在下方新建一个吧'),
                ),
              for (final tag in _store.tags)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(tag.name),
                  secondary: Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      color: tagPalette[tag.colorIndex % tagPalette.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  value: _selected.contains(tag.id),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selected.add(tag.id);
                          } else {
                            _selected.remove(tag.id);
                          }
                        }),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        hintText: '新建标签（不能含空格或 ✦）',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(CupertinoIcons.add_circled),
                    onPressed: _busy ? null : _add,
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '正在保存…' : '保存'),
        ),
      ],
    ),
  );
}

/// 标签库管理：新建、重命名、删除。
class TagManagePage extends StatefulWidget {
  const TagManagePage({super.key, required this.state, this.local});
  final LibraryState state;
  final LocalLibraryStore? local;

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
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      try {
        if (widget.local != null) {
          await widget.local!.renameTag(tag.id, name);
        } else {
          await TagStore.shared.renameTag(tag.id, name);
        }
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) showNovelFeedback(context, '保存失败：$error');
      }
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
      try {
        if (widget.local != null) {
          await widget.local!.deleteTag(tag.id);
        } else {
          await TagStore.shared.deleteTag(tag.id);
        }
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) showNovelFeedback(context, '删除失败：$error');
      }
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
                GlassTextButton(onPressed: _create, child: const Text('添加')),
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
    final name = _controller.text;
    if (name.isEmpty) return;
    try {
      await TagStore.shared.createTag(name);
      _controller.clear();
      if (mounted) setState(() {});
    } on ArgumentError catch (error) {
      if (mounted) {
        showNovelFeedback(context, error.message?.toString() ?? '标签名不合法');
      }
    }
  }
}
