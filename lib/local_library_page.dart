import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'local_scan_follow_up.dart';
import 'wenku_errors.dart';

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
  bool _picking = false;
  String? _folderUri;

  @override
  void initState() {
    super.initState();
    widget.state.bindLocalChapters(widget.local);
    _folderUri = widget.local.folderUri;
  }

  Future<void> _pickFolder() async {
    if (_scanning || _picking) return;
    setState(() => _picking = true);
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
    } on PlatformException catch (error) {
      if (mounted) {
        _showDebugDialog(
          '选择失败',
          describeSafeError(error, fallback: '文件夹选择失败'),
        );
      }
    } catch (e) {
      if (mounted) {
        _showDebugDialog(
          '选择失败',
          describeSafeError(e, fallback: '文件夹选择失败'),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _showDebugDialog(String title, String message, {bool localScan = false}) {
    if (!mounted) return;
    if (!kDebugMode && !localScan) {
      showNovelFeedback(context, title);
      return;
    }
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
    if (_scanning || _picking) return;
    if (_folderUri == null) {
      await _pickFolder();
      if (_folderUri == null || !mounted) return;
    }
    setState(() => _scanning = true);
    final scanningFolder = widget.local.folderUri;
    try {
      final result = await widget.local.scan();
      // 章节迁移按队列顺序执行，完成后一次提交确认和失败状态。
      final followUp = await applyLocalScanFollowUp<LocalChapterRemap>(
        remaps: result.chapterRemaps,
        cleanupAssociations: () async {},
        migrate: (remap) => widget.state.migrateLocalChapterTask(remap),
        confirm: (_) async {},
        recordFailure: (_, _) async {},
        bookIdOf: (remap) => remap.bookId,
        commitMigrationOutcomes: (confirmed, failures) =>
            widget.local.commitChapterRemapResults(
              confirmed: [
                for (final remap in confirmed)
                  (bookId: remap.bookId, migrationId: remap.migrationId),
              ],
              failures: failures,
            ),
      );
      if (followUp.failedMigrations > 0 && mounted) {
        showNovelFeedback(
          context,
          '${followUp.failedMigrations} 本书的阅读进度迁移失败，已保存待重试任务',
        );
      }
      var cleanupFailed = false;
      // 文件夹切换：清理旧来源书籍的书架/标签/阅读进度。
      // peek→逐个幂等清理→confirm：中断后未确认的 ID 下次重试。
      try {
      final cleanupIds = await widget.local.peekAssociatedCleanupIds();
      final cleanupDone = <int>[];
      for (final id in cleanupIds) {
        try {
          await widget.state.setShelfMembership(id, false);
          await TagStore.shared.setTagsForBook(id, const {});
          await widget.state.clearBookProgress(id);
          cleanupDone.add(id);
        } catch (_) {
          cleanupFailed = true;
          if (mounted) showNovelFeedback(context, '部分关联记录未清理，已保留待重试任务');
        }
      }
      await widget.local.confirmAssociatedCleanupIds(cleanupDone);
      } catch (_) {
        cleanupFailed = true;
        if (mounted) showNovelFeedback(context, '关联清理未完成，已保留待重试任务');
      }
      // 新书自动上架：一次提交书架和对应元数据。
      await widget.state.addShelfBooks([
        for (final book in widget.local.books)
          if (!widget.state.contains(book.id)) widget.local.toNovel(book),
      ]);
      if (!mounted) return;
      setState(() {});
      if (result.failures.isNotEmpty) {
        _showDebugDialog(
          '部分书籍扫描失败',
          result.failures.entries.map((entry) => '${entry.key}：${entry.value}').join('\n'),
          localScan: true,
        );
      }
      final parts = <String>[];
      if (result.failures.isNotEmpty) {
        parts.add('失败 ${result.failures.length} 本');
      }
      if (result.added > 0) parts.add('新增 ${result.added} 本');
      if (result.refreshed > 0) parts.add('更新 ${result.refreshed} 本');
      if (result.removed > 0) parts.add('移除 ${result.removed} 本');
      if (result.switchedRemovedIds.isNotEmpty) {
        parts.add('旧文件夹移除 ${result.switchedRemovedIds.length} 本');
      }
      if (cleanupFailed) parts.add('关联清理待重试');
      if (!followUp.handled) parts.add('迁移确认待重试');
      if (followUp.failedMigrations > 0) parts.add('进度迁移失败 ${followUp.failedMigrations} 本');
      showNovelFeedback(
        context,
        parts.isEmpty ? '扫描完成，书库无变化（共 ${result.total} 本）' : '扫描完成：${parts.join('，')}（共 ${result.total} 本）',
      );
    } on IncompleteScanException catch (error) {
      // 扫描不完整：书库未动，如实提示原因，不再显示误导性的"书库无变化"。
      if (!mounted) return;
      showNovelFeedback(context, '${error.message}。本次未更新书库。');
    } on PlatformException catch (error) {
      if (!mounted) return;
      showNovelFeedback(
        context,
        error.code == 'permission'
            ? '文件夹授权已失效，请重新选择文件夹'
            : '扫描失败，请重试',
      );
      if (error.code == 'permission' && widget.local.folderUri == scanningFolder) {
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
          onPressed: _scanning || _picking ? null : _scan,
        ),
      ],
      child: ListView(
        padding: featurePadding(context),
        children: [
          ContentPanel(
            onTap: _scanning || _picking ? null : _pickFolder,
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
            onTap: _scanning || _picking ? () {} : _scan,
          ),
        ],
      ),
    );
  }
}
