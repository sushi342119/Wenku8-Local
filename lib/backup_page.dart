import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_backup.dart';
import 'library_state.dart';
import 'local_platform.dart';

class LibraryBackupPage extends StatefulWidget {
  const LibraryBackupPage({super.key, required this.state});
  final LibraryState state;
  @override
  State<LibraryBackupPage> createState() => _LibraryBackupPageState();
}

class _LibraryBackupPageState extends State<LibraryBackupPage> {
  String? _busy;
  String? _error;
  LibraryBackup? _preview;
  bool _preferences = false;

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _error = null;
    });
    // Present the progress state before serializing/merging an explicit backup.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请检查文件或本地存储后重试');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _export({bool clipboard = false}) => _run('正在生成备份…', () async {
    final text = await (await widget.state.createBackup()).encode();
    if (clipboard) {
      if (text.length > 256 * 1024) throw const FormatException('备份较大，请使用文件导出');
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) showNovelFeedback(context, '备份已复制');
    } else {
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final saved = await LocalPlatform.exportBackup(
        text,
        'wenku8-backup-$date.json',
      );
      if (mounted && saved) showNovelFeedback(context, '备份文件已保存');
    }
  });

  Future<void> _import({bool clipboard = false}) => _run('正在读取备份…', () async {
    final text = clipboard
        ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
        : await LocalPlatform.importBackup();
    if (text == null) {
      if (clipboard) throw const FormatException('剪贴板中没有备份文本');
      return; // System picker cancellation is not an error.
    }
    final backup = await LibraryBackup.parse(text);
    if (mounted) {
      setState(() {
        _preview = backup;
        _preferences = false;
      });
    }
  });

  Future<void> _restore() => _run('正在合并本地记录…', () async {
    final backup = _preview;
    if (backup == null) return;
    await widget.state.restoreBackup(backup, importPreferences: _preferences);
    if (mounted) {
      setState(() => _preview = null);
      showNovelFeedback(context, '备份已合并，较新的阅读进度已保留');
    }
  });

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _busy == null,
    child: Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: Row(
            children: [
              GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回设置',
                onPressed: _busy == null ? () => Navigator.pop(context) : null,
              ),
              const Expanded(
                child: ArchiveRouteTitle(
                  title: '备份与恢复',
                  code: 'SYSTEM / DATA TRANSFER',
                ),
              ),
              const SizedBox(width: 44),
            ],
          ),
          body: LoadedContentSequence(
            generation: _preview,
            child: ListView(
              key: const ValueKey('backup-scroll'),
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                const Text(
                  '带走你的阅读记录',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text('备份书架、阅读进度、书签、阅读历史、最近搜索和偏好。离线正文与账号信息不包含在备份中。'),
                const SizedBox(height: 24),
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (LocalPlatform.android) ...[
                        GlassTextButton(
                          key: const ValueKey('backup-export-file'),
                          onPressed: _busy == null ? _export : null,
                          child: const Text('导出备份文件'),
                        ),
                        GlassTextButton(
                          key: const ValueKey('backup-import-file'),
                          onPressed: _busy == null ? _import : null,
                          child: const Text('选择备份文件'),
                        ),
                        const Divider(height: 24),
                      ],
                      GlassTextButton(
                        key: const ValueKey('backup-copy'),
                        onPressed: _busy == null
                            ? () => _export(clipboard: true)
                            : null,
                        child: const Text('复制备份文本'),
                      ),
                      GlassTextButton(
                        key: const ValueKey('backup-paste'),
                        onPressed: _busy == null
                            ? () => _import(clipboard: true)
                            : null,
                        child: const Text('从剪贴板读取备份'),
                      ),
                    ],
                  ),
                ),
                if (_busy != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Row(
                      children: [
                        Expanded(child: Text(_busy!)),
                        const SizedBox(width: 12),
                        const SizedBox(
                          width: 120,
                          height: 64,
                          child: LoadingSkeleton(
                            layout: SkeletonLayout.actions,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        key: const ValueKey('backup-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (_preview case final backup?) ...[
                  const SizedBox(height: 24),
                  LoadedContentItem(
                    index: 0,
                    child: sectionHeader(context, '恢复预览', ''),
                  ),
                  const SizedBox(height: 14),
                  LoadedContentItem(
                    index: 1,
                    child: ContentPanel(
                      key: const ValueKey('backup-preview'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('备份时间 ${_date(backup.createdAt)}'),
                          const SizedBox(height: 12),
                          Text(
                            '${backup.shelfCount} 本书架收藏 · ${backup.positionCount} 条阅读进度\n${backup.bookmarkCount} 个书签 · ${backup.historyCount} 本阅读记录',
                          ),
                          const SizedBox(height: 14),
                          const Text('恢复将合并到本机，不清空已有书架和书签；同一本书保留更新时间较新的进度。'),
                          const Divider(height: 24),
                          Row(
                            children: [
                              const Expanded(child: Text('同时恢复外观与阅读偏好')),
                              CupertinoSwitch(
                                key: const ValueKey(
                                  'backup-import-preferences',
                                ),
                                value: _preferences,
                                activeTrackColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                onChanged: _busy == null
                                    ? (value) =>
                                          setState(() => _preferences = value)
                                    : null,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          GlassTextButton(
                            key: const ValueKey('backup-confirm'),
                            onPressed: _busy == null ? _restore : null,
                            child: const Text('确认合并恢复'),
                          ),
                          GlassTextButton(
                            onPressed: _busy == null
                                ? () => setState(() => _preview = null)
                                : null,
                            child: const Text('取消恢复'),
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
      ),
    ),
  );

  String _date(int timestamp) {
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        timestamp,
      ).toLocal().toString().substring(0, 16);
    } catch (_) {
      return '未记录';
    }
  }
}
