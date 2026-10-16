import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'local_pdf_reader.dart';
import 'pages.dart' show openDetail;

/// 本地书库管理：选择文件夹、扫描导入 TXT / PDF、移除。
class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    required this.state,
    required this.local,
    required this.repository,
  });

  final LibraryState state;
  final LocalLibraryStore local;
  final NovelRepository repository;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  bool _scanning = false;
  bool _randomPicking = false;
  String? _folderUri;
  final _random = math.Random();

  @override
  void initState() {
    super.initState();
    _folderUri = widget.local.folderUri;
  }

  Future<void> _pickFolder() async {
    try {
      final uri = await widget.local.pickFolder();
      if (!mounted) return;
      if (uri != null && uri.isNotEmpty) {
        setState(() => _folderUri = uri);
        showNovelFeedback(context, '已选择文件夹，可开始扫描');
      } else {
        // 用户取消选择，显示提示以便确认按钮有响应
        _showDebugDialog('未选择文件夹', '你取消了文件夹选择。如需导入小说，请重新点击并选择文件夹。');
      }
    } on PlatformException catch (e) {
      if (mounted) _showDebugDialog('选择失败', '错误码: ${e.code}\n详情: ${e.message}');
    } catch (e) {
      if (mounted) _showDebugDialog('未知错误', e.toString());
    }
  }

  void _showDebugDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _scan() async {
    if (_scanning) return;
    if (_folderUri == null) {
      await _pickFolder();
      if (_folderUri == null || !mounted) return;
    }
    setState(() => _scanning = true);
    try {
      final result = await widget.local.scan();
      // 新书自动上架。
      for (final book in widget.local.books) {
        if (!widget.state.shelf.contains(book.id)) {
          await widget.state.toggleShelf(
            book.id,
            novel: widget.local.toNovel(book),
          );
        }
      }
      if (!mounted) return;
      setState(() {});
      final parts = <String>[];
      if (result.added > 0) parts.add('新增 ${result.added} 本');
      if (result.refreshed > 0) parts.add('更新 ${result.refreshed} 本');
      if (result.removed > 0) parts.add('移除 ${result.removed} 本');
      showNovelFeedback(
        context,
        parts.isEmpty ? '扫描完成，书库无变化（共 ${result.total} 本）' : '扫描完成：${parts.join('，')}（共 ${result.total} 本）',
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      showNovelFeedback(
        context,
        error.code == 'permission'
            ? '文件夹授权已失效，请重新选择文件夹'
            : '扫描失败：${error.message ?? '请重试'}',
      );
      if (error.code == 'permission') {
        setState(() => _folderUri = null);
        await widget.local.forgetFolder();
      }
    } catch (_) {
      if (mounted) showNovelFeedback(context, '扫描失败，请重试');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 备用方案：扫描应用外部文件夹（无需系统文件夹选择器）。
  Future<void> _scanAppFolder() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final folderPath = await widget.local.appFolderPath;
      final result = await widget.local.scanAppFolder();
      // 新书自动上架。
      for (final book in widget.local.books) {
        if (!widget.state.shelf.contains(book.id)) {
          await widget.state.toggleShelf(
            book.id,
            novel: widget.local.toNovel(book),
          );
        }
      }
      if (!mounted) return;
      setState(() {});
      final parts = <String>[];
      if (result.added > 0) parts.add('新增 ${result.added} 本');
      if (result.refreshed > 0) parts.add('更新 ${result.refreshed} 本');
      if (result.removed > 0) parts.add('移除 ${result.removed} 本');
      if (result.added == 0 && result.total == 0) {
        // 首次使用，告诉用户把文件放哪里
        _showDebugDialog(
          '把小说放进这个文件夹',
          '请用文件管理器把 TXT 小说复制到：\n\n$folderPath\n\n然后再点一次扫描。',
        );
      } else {
        showNovelFeedback(
          context,
          parts.isEmpty
              ? '扫描完成，书库无变化（共 ${result.total} 本）'
              : '扫描完成：${parts.join('，')}（共 ${result.total} 本）',
        );
      }
    } catch (e) {
      if (mounted) _showDebugDialog('扫描失败', e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _editBookInfo(BuildContext context, LocalBook book) async {
    final titleController = TextEditingController(text: book.displayTitle);
    final authorController = TextEditingController(text: book.displayAuthor);
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑书籍信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: '书名',
                hintText: '留空则使用文件名解析结果',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: authorController,
              decoration: const InputDecoration(
                labelText: '作者',
                hintText: '留空则使用文件名解析结果',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              (titleController.text, authorController.text),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    titleController.dispose();
    authorController.dispose();
    if (result == null || !mounted) return;
    await widget.local.updateBookInfo(book.id, result.$1, result.$2);
    // 同步书架快照里的书名/作者。
    final updated = widget.local.bookFor(book.id);
    if (updated != null && widget.state.shelf.contains(book.id)) {
      await widget.state.rememberNovel(widget.local.toNovel(updated));
    }
    if (mounted) {
      setState(() {});
    }
    if (context.mounted) {
      showNovelFeedback(context, '已保存');
    }
  }

  Future<void> _removeBook(LocalBook book) async {
    final confirmed = await confirmNovelAction(
      context,
      title: '从本地书库移除？',
      message: '「${book.displayTitle}」将从书库和书架中移除，源文件不受影响。阅读进度会保留。',
      confirmLabel: '移除',
      reduceMotion: widget.state.reduceMotion,
    );
    if (!confirmed || !mounted) return;
    await widget.local.removeBook(book.id);
    if (widget.state.shelf.contains(book.id)) {
      await widget.state.toggleShelf(book.id);
    }
    if (mounted) {
      setState(() {});
      showNovelFeedback(context, '已移除「${book.displayTitle}」');
    }
  }

  /// 随机选书：从当前书库中随机抽一本。
  Future<void> _randomPick() async {
    if (_scanning || _randomPicking) return;

    final pool = List<LocalBook>.of(widget.local.books);

    if (pool.isEmpty) {
      showNovelFeedback(context, '本地书库为空，请先扫描导入书籍');
      return;
    }

    setState(() => _randomPicking = true);

    try {
      var index = _random.nextInt(pool.length);

      final selected = await showDialog<LocalBook>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final book = pool[index];
            return AlertDialog(
              title: const Text('随机选书'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.displayTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    book.displayAuthor.trim().isEmpty
                        ? '作者未知'
                        : book.displayAuthor,
                    style: TextStyle(
                      color: Theme.of(
                        dialogContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共 ${pool.length} 本候选',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: pool.length <= 1
                      ? null
                      : () {
                          // 从其他候选中抽取，避免"换一本"仍是同一本。
                          final next = _random.nextInt(pool.length - 1);
                          setDialogState(() {
                            index = next >= index ? next + 1 : next;
                          });
                        },
                  child: const Text('换一本'),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(pool[index]),
                  child: const Text('开始阅读'),
                ),
              ],
            );
          },
        ),
      );

      if (!mounted || selected == null) return;

      // 弹窗期间书籍可能被移除，按 ID 获取当前对象。
      final current = widget.local.bookFor(selected.id);
      if (current == null) {
        showNovelFeedback(context, '该书已不在本地书库中，请重新选择');
        return;
      }

      _openBook(current);
    } finally {
      if (mounted) {
        setState(() => _randomPicking = false);
      }
    }
  }

  void _openBook(LocalBook book) {
    final novel = widget.local.toNovel(book);
    if (book.kind == LocalBookKind.pdf) {
      pushNovelPage<void>(
        context,
        LocalPdfReaderPage(
          novel: novel,
          state: widget.state,
          local: widget.local,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    } else {
      openDetail(context, novel, widget.state, widget.repository);
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.local.books;
    return ArchiveFeaturePage(
      title: '本地书库',
      code: 'LOCAL / BOOK ARCHIVE',
      actions: [
        GlassIconButton(
          icon: CupertinoIcons.refresh,
          label: '扫描',
          onPressed: _scanning ? null : _scan,
        ),
      ],
      child: ListView(
        padding: featurePadding(context),
        children: [
          ContentPanel(
            onTap: _pickFolder,
            child: Row(
              children: [
                const Icon(CupertinoIcons.folder, size: 21),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '小说文件夹',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _folderUri == null ? '尚未选择，点击选择' : '已授权，点击可更换',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(CupertinoIcons.chevron_right, size: 14),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FeatureEntry(
            key: const ValueKey('local-library-scan'),
            title: _scanning ? '正在扫描…' : '扫描文件夹',
            subtitle: '自动导入新增，移除已删除的（共 ${books.length} 本）',
            icon: CupertinoIcons.doc_text_search,
            onTap: _scanning ? () {} : _scan,
          ),
          const SizedBox(height: 14),
          FeatureEntry(
            key: const ValueKey('local-library-app-folder'),
            title: _scanning ? '正在扫描…' : '扫描应用文件夹',
            subtitle: '无需选择器：把 TXT 放进应用专属文件夹后扫描',
            icon: CupertinoIcons.tray_arrow_down,
            onTap: _scanning ? () {} : _scanAppFolder,
          ),
          const SizedBox(height: 24),
          if (_scanning) ...[
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          ] else if (books.isEmpty) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '空空如也\n选择文件夹并扫描，把小说搬进来吧',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    height: 1.8,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ] else ...[
            for (final book in books)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ContentPanel(
                  onTap: () => _openBook(book),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                        ),
                        child: Text(
                          book.kind == LocalBookKind.pdf ? 'PDF' : 'TXT',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              book.kind == LocalBookKind.pdf
                                  ? '${book.pageCount} 页 · ${formatLocalSize(book.size)}'
                                  : '${book.chapters.length} 章 · ${formatLocalSize(book.size)}',
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
                        icon: const Icon(
                          CupertinoIcons.pencil,
                          size: 18,
                        ),
                        onPressed: () => _editBookInfo(context, book),
                      ),
                      IconButton(
                        icon: const Icon(
                          CupertinoIcons.delete,
                          size: 18,
                        ),
                        onPressed: () => _removeBook(book),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
