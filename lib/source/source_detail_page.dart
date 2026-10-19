/// 书源试验版（source-trial 分支）：书源书籍详情页。
///
/// 展示书名/作者/简介/章节目录；一键下载全本 → 生成 TXT → 本地入库。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../local_library.dart';
import '../app_interactions.dart' show pushNovelPage, showNovelFeedback;
import 'site_adapter.dart';
import 'source_client.dart';
import 'source_download.dart';
import 'source_models.dart';

class SourceDetailPage extends StatefulWidget {
  const SourceDetailPage({
    super.key,
    required this.book,
    required this.client,
    required this.adapter,
    required this.onVerify,
    required this.local,
  });

  final SourceBook book;
  final SourceClient client;
  final SiteAdapter adapter;

  /// 需要验证时的处理：打开 WebView，成功返回 true（调用方重试）。
  final Future<bool> Function(Future<void> Function() retry) onVerify;
  final LocalLibraryStore local;

  @override
  State<SourceDetailPage> createState() => _SourceDetailPageState();
}

class _SourceDetailPageState extends State<SourceDetailPage> {
  bool _loading = true;
  String? _error;
  SourceBookDetail? _detail;

  SourceDownloadTask? _task;
  bool _downloading = false;
  int _done = 0;
  int _total = 0;
  String _current = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.adapter.detail(widget.client, widget.book);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _total = detail.chapters.length;
      });
    } on SiteNeedVerify {
      if (!mounted) return;
      setState(() => _loading = false);
      await widget.onVerify(() => _load());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download() async {
    final detail = _detail;
    if (detail == null || _downloading) return;
    if (detail.chapters.isEmpty) {
      showNovelFeedback(context, '该书暂无章节');
      return;
    }
    final task = SourceDownloadTask(
      detail: detail,
      client: widget.client,
      fetcher: (client, chapter) async {
        try {
          return await widget.adapter.content(client, chapter);
        } on SiteNeedVerify {
          throw const SourceNeedVerify();
        }
      },
      local: widget.local,
    );
    setState(() {
      _task = task;
      _downloading = true;
      _done = 0;
      _current = '';
    });
    try {
      await task.start((done, total, current) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
          _current = current;
        });
      });
    } on SourceNeedVerify {
      if (!mounted) return;
      setState(() => _downloading = false);
      final ok = await widget.onVerify(() => _download());
      if (!ok && mounted) setState(() => _task = null);
      return;
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    if (task.status == SourceDownloadStatus.completed) {
      await _saveToLibrary(task);
    } else if (task.status == SourceDownloadStatus.failed) {
      _showFailedDialog(task);
    }
    // cancelled / pausedNeedVerify：保持任务，用户可继续操作。
  }

  Future<void> _saveToLibrary(SourceDownloadTask task) async {
    showNovelFeedback(context, '下载完成，正在入库…');
    try {
      final book = await task.saveToLibrary();
      if (!mounted) return;
      showNovelFeedback(context, '已导入本地书库：《${book.displayTitle}》');
      setState(() => _task = null);
    } catch (e) {
      if (!mounted) return;
      showNovelFeedback(context, '入库失败：$e');
    }
  }

  void _showFailedDialog(SourceDownloadTask task) {
    final failed = task.failedResults;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${failed.length} 章下载失败'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: failed.length.clamp(0, 20),
            itemBuilder: (_, i) => Text(
              '· ${failed[i].chapter.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _retry(task);
            },
            child: const Text('重试失败章节'),
          ),
        ],
      ),
    );
  }

  Future<void> _retry(SourceDownloadTask task) async {
    setState(() => _downloading = true);
    try {
      await task.retryFailed((done, total, current) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
          _current = current;
        });
      });
    } on SourceNeedVerify {
      if (!mounted) return;
      setState(() => _downloading = false);
      await widget.onVerify(() => _retry(task));
      return;
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    if (task.status == SourceDownloadStatus.completed) {
      await _saveToLibrary(task);
    } else if (task.status == SourceDownloadStatus.failed) {
      _showFailedDialog(task);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.book.title)),
      body: _buildBody(),
      bottomNavigationBar: _detail == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: _downloading
                    ? _buildProgress()
                    : FilledButton.icon(
                        icon: const Icon(CupertinoIcons.cloud_download),
                        label: Text('下载全本（${_total}章）'),
                        onPressed: _download,
                      ),
              ),
            ),
    );
  }

  Widget _buildProgress() {
    final progress = _total > 0 ? _done / _total : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '正在下载 $_done/$_total${_current.isNotEmpty ? ' · $_current' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () {
                _task?.cancel();
                setState(() => _downloading = false);
              },
              child: const Text('取消'),
            ),
          ],
        ),
        LinearProgressIndicator(value: progress),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final detail = _detail!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          detail.book.title,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        if (detail.book.author.isNotEmpty)
          Text('作者：${detail.book.author}'),
        if (detail.book.status != null) Text('状态：${detail.book.status}'),
        if (detail.book.description != null &&
            detail.book.description!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            detail.book.description!.trim(),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '目录（${detail.chapters.length}章）',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Divider(),
        ...detail.chapters.take(50).map(
          (c) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (detail.chapters.length > 50)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '…共 ${detail.chapters.length} 章，下载后可在本地阅读',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
