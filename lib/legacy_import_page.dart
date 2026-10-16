import 'package:flutter/cupertino.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'legacy_import.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'wenku_errors.dart';

class LegacyImportPage extends StatefulWidget {
  const LegacyImportPage({super.key, required this.state});
  final LibraryState state;
  @override
  State<LegacyImportPage> createState() => _LegacyImportPageState();
}

class _LegacyImportPageState extends State<LegacyImportPage> {
  bool _busy = false;
  String? _error;
  LegacyImportPreview? _preview;
  Future<void> _choose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bundle = await LocalPlatform.importLegacyData();
      if (bundle == null) return;
      final preview = await LegacyImportPreview.parse(bundle);
      if (mounted) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) setState(() => _error = describeWenkuError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy || _preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.restoreBackup(_preview!.backup);
      if (mounted) {
        setState(() => _preview = null);
        showNovelFeedback(context, '旧版记录已合并，现有较新进度已保留');
      }
    } catch (error) {
      if (mounted) setState(() => _error = describeWenkuError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: ArchiveFeaturePage(
      title: '导入旧版记录',
      code: 'MIGRATION / LOCAL ARCHIVE',
      canPop: !_busy,
      child: LoadedContentSequence(
        generation: _preview,
        child: ListView(
          padding: featurePadding(context),
          children: [
            const Text(
              '让原来的收藏接着读',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              '选择旧版的 wenku8 或 saves 目录。读取本机书架、阅读进度和搜索记录；不读取账号密码，也不改动旧目录。',
            ),
            const SizedBox(height: 12),
            const Text(
              '旧分页阅读进度恢复到对应章节。上下滑动记录通过 intro 目录中的章节索引匹配；本机已有较新的进度优先保留。',
            ),
            const SizedBox(height: 24),
            FeatureEntry(
              key: const ValueKey('legacy-choose'),
              title: '选择旧版目录',
              icon: CupertinoIcons.folder,
              subtitle: 'bookshelf_local.wk8 / read_saves / search_history',
              onTap: _busy ? null : _choose,
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: SizedBox(
                  height: 100,
                  child: LoadingSkeleton(
                    layout: SkeletonLayout.actions,
                    label: '正在处理旧版记录',
                  ),
                ),
              ),
            FeatureError(_error),
            if (_preview case final preview?) ...[
              const SizedBox(height: 24),
              LoadedContentItem(
                index: 0,
                child: ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sectionHeader(context, '导入预览', ''),
                      const SizedBox(height: 14),
                      Text(
                        '${preview.backup.shelfCount} 本收藏 · ${preview.backup.positionCount} 条阅读进度',
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${(preview.backup.records['recentSearches'] as List).length} 条最近搜索',
                      ),
                      if (preview.damagedRecords > 0 ||
                          preview.unmappedChapters > 0 ||
                          preview.skippedFiles > 0) ...[
                        const SizedBox(height: 14),
                        Text(
                          '跳过 ${preview.damagedRecords} 条损坏记录、${preview.unmappedChapters} 条未匹配章节及 ${preview.skippedFiles} 个过大 / 非 UTF-8 文件。旧文件仍保留。',
                        ),
                      ],
                      const SizedBox(height: 20),
                      GlassTextButton(
                        key: const ValueKey('legacy-merge'),
                        onPressed: _busy ? null : _restore,
                        child: const Text('确认合并到本机'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
