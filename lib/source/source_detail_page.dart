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
import 'download_manager.dart';
import 'webview_fetcher.dart';
import 'source_download.dart';
import 'source_models.dart';

class SourceDetailPage extends StatefulWidget {
  const SourceDetailPage({
    super.key,
    required this.book,
    required this.client,
    required this.adapter,
    required this.downloadManager,
    required this.local,
    this.onBookSaved,
  });

  final SourceBook book;
  final SourceClient client;
  final SiteAdapter adapter;
  final SourceDownloadManager downloadManager;
  final LocalLibraryStore local;

  /// 书籍下载完成入库后的回调（用于上架等）。
  final void Function(LocalBook book)? onBookSaved;

  @override
  State<SourceDetailPage> createState() => _SourceDetailPageState();
}

class _SourceDetailPageState extends State<SourceDetailPage> {
  bool _loading = true;
  String? _error;
  SourceBookDetail? _detail;

  int _total = 0;

  /// 当前书的下载任务（由管理器持有，详情页只监听展示）。
  SourceDownloadTask? get _task => widget.downloadManager.taskFor(widget.book);

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
      showNovelFeedback(context, '需要重新验证，已返回搜索页');
      if (mounted) Navigator.of(context).pop();
    } on WebViewNeedVerify {
      if (!mounted) return;
      setState(() => _loading = false);
      // 详情页在栈顶，验证 UI 在搜索页：先弹回搜索页，用户重新搜索时触发验证。
      showNovelFeedback(context, '需要重新验证，已返回搜索页');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 开始下载（经管理器后台执行，可离开本页）。
  void _download() {
    final detail = _detail;
    if (detail == null) return;
    if (detail.chapters.isEmpty) {
      showNovelFeedback(context, '该书暂无章节');
      return;
    }
    final existing = _task;
    if (existing != null &&
        (existing.status == SourceDownloadStatus.downloading ||
            existing.status == SourceDownloadStatus.pausedNeedVerify)) {
      showNovelFeedback(context, '下载进行中，可离开本页，后台继续下载');
      return;
    }
    widget.downloadManager.startDownload(
      detail: detail,
      client: widget.client,
      fetcher: (client, chapter) async {
        try {
          return await widget.adapter.content(client, chapter);
        } on SiteNeedVerify {
          throw const SourceNeedVerify();
        } on WebViewNeedVerify {
          throw const SourceNeedVerify();
        }
      },
      local: widget.local,
      onSaved: (book) {
        widget.onBookSaved?.call(book);
        if (mounted) {
          showNovelFeedback(context, '已导入本地书库：《${book.displayTitle}》');
        }
      },
      onError: (msg) {
        if (mounted) {
          final task = _task;
          if (task != null && task.status == SourceDownloadStatus.failed) {
            _showFailedDialog(task);
          } else {
            showNovelFeedback(context, msg);
          }
        }
      },
    );
    showNovelFeedback(context, '已开始后台下载，可去找其他书');
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
    final detail = _detail;
    if (detail == null) return;
    widget.downloadManager.startDownload(
      detail: detail,
      client: widget.client,
      fetcher: (client, chapter) async {
        try {
          return await widget.adapter.content(client, chapter);
        } on SiteNeedVerify {
          throw const SourceNeedVerify();
        } on WebViewNeedVerify {
          throw const SourceNeedVerify();
        }
      },
      local: widget.local,
      onSaved: (book) {
        widget.onBookSaved?.call(book);
        if (mounted) {
          showNovelFeedback(context, '已导入本地书库：《${book.displayTitle}》');
        }
      },
      onError: (msg) {
        if (mounted) showNovelFeedback(context, msg);
      },
    );
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
                child: ListenableBuilder(
                  listenable: widget.downloadManager,
                  builder: (context, _) {
                    final task = _task;
                    final active = task != null &&
                        (task.status == SourceDownloadStatus.downloading ||
                            task.status ==
                                SourceDownloadStatus.pausedNeedVerify);
                    if (active) return _buildProgress(task);
                    return FilledButton.icon(
                      icon: const Icon(CupertinoIcons.cloud_download),
                      label: Text('下载全本（${_total}章）'),
                      onPressed: _download,
                    );
                  },
                ),
              ),
            ),
    );
  }

  Widget _buildProgress(SourceDownloadTask task) {
    final done = task.done;
    final total = task.total;
    final progress = total > 0 ? done / total : 0.0;
    final paused =
        task.status == SourceDownloadStatus.pausedNeedVerify;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                paused
                    ? '下载已暂停，需返回搜索页完成验证'
                    : '正在下载 $done/$total（后台继续，可离开本页）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () {
                widget.downloadManager.cancelTask(widget.book);
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
