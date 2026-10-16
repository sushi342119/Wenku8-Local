
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_library.dart';

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
  String? _folderUri;

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
        ],
      ),
    );
  }
}
