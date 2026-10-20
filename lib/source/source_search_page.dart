/// 书源试验版（source-trial 分支）：书源搜索页。
///
/// 关键词搜索 → 结果列表 → 点击进入详情页。
/// 仅在试验通道（TRIAL_CHANNEL=true）下可进入。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../library_state.dart';
import '../local_library.dart';
import '../app_interactions.dart' show pushNovelPage, showNovelFeedback;
import 'site_123.dart';
import 'site_adapter.dart';
import 'source_client.dart';
import 'source_config.dart';
import 'source_detail_page.dart';
import 'source_models.dart';
import 'download_manager.dart';
import 'source_download.dart';
import 'webview_fetcher.dart';

class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({super.key, required this.local, required this.libraryState});

  final LocalLibraryStore local;
  final LibraryState libraryState;

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final TextEditingController _keyword = TextEditingController();
  final SourceClient _client = SourceClient();
  final SiteAdapter _adapter = Site123Adapter();
  final WebViewSession _webViewSession = WebViewSession();
  late final SourceDownloadManager _downloadManager = SourceDownloadManager();

  bool _searching = false;
  String? _error;
  List<SourceBook> _results = [];
  bool _verifying = false; // WebView 验证中（显示内嵌 WebView）

  @override
  void initState() {
    super.initState();
    SourceConfig.instance.load();
    // 全程走 WebView 会话取页，绕过 Cloudflare 对 HttpClient 的 TLS 指纹拦截。
    _client.webViewSession = _webViewSession;
  }

  @override
  void dispose() {
    _downloadManager.dispose();
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final kw = _keyword.text.trim();
    if (kw.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });
    try {
      final results = await _adapter.search(_client, kw);
      if (!mounted) return;
      setState(() {
        _results = results;
        if (results.isEmpty) _error = '没有找到相关书籍，换个关键词试试';
      });
    } on SiteNeedVerify {
      if (!mounted) return;
      setState(() => _searching = false);
      await _verifyThenRetry(() => _search());
    } on WebViewNeedVerify {
      if (!mounted) return;
      setState(() => _searching = false);
      await _verifyThenRetry(() => _search());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 待重试的操作（验证完成后执行）。
  Future<void> Function()? _pendingRetry;

  /// 内嵌 WebView 验证：切换到 WebView 页面供用户完成验证。
  /// 返回 true 表示验证成功（调用方重试），false 表示用户取消。
  Future<bool> _verifyThenRetry(Future<void> Function() retry) async {
    if (!mounted) return false;
    // 防重入：已在验证中则不再重复触发。
    if (_verifying) return false;
    _pendingRetry = retry;
    _webViewSession.setVerifying(true);
    setState(() => _verifying = true);
    return false; // 实际重试由 _onVerifyDone 触发
  }

  /// 用户点击"已完成验证"：试读确认后执行待重试操作。
  Future<void> _onVerifyDone() async {
    if (!mounted) return;
    _webViewSession.setVerifying(false);
    setState(() => _verifying = false);
    final retry = _pendingRetry;
    _pendingRetry = null;
    // 验证后试读：确认 WebView 会话可用（第一道验收门槛）。
    bool verified = false;
    try {
      final probe = await _client.get(Uri.parse(SourceConfig.instance.baseUrl));
      verified = !probe.challenged;
    } catch (e) {
      verified = false;
      if (e is! WebViewNeedVerify && mounted) {
        showNovelFeedback(context, '验证后试读失败：$e');
      }
    }
    if (!verified) {
      if (mounted) {
        showNovelFeedback(context, '验证尚未通过，请继续验证');
        // 保留待重试操作，重新显示 WebView
        _pendingRetry = retry;
        setState(() => _verifying = true);
      }
      return;
    }
    if (retry != null) await retry();
    // 续传因验证暂停的后台下载任务。
    await _downloadManager.resumeAfterVerify(
      onSaved: (task, book) {
        _shelfBook(book);
        if (mounted) {
          showNovelFeedback(context, '《${task.detail.book.title}》下载完成，已入库');
        }
      },
      onError: (task, msg) {
        if (mounted) showNovelFeedback(context, msg);
      },
    );
  }

  /// 下载完成入库后自动上架（与本地书库页"新书自动上架"逻辑一致）。
  Future<void> _shelfBook(LocalBook book) async {
    try {
      final state = widget.libraryState;
      // book 是 LocalBook，有 id；local.toNovel 转 Novel
      final novel = widget.local.toNovel(book);
      await state.toggleShelf(book.id, novel: novel);
    } catch (_) {}
  }

  /// 后台下载因验证暂停时，用户点击横幅触发验证。
  void _verifyForDownloads() {
    if (_verifying) return;
    _webViewSession.setVerifying(true);
    setState(() => _verifying = true);
  }

  void _openDetail(SourceBook book) {
    pushNovelPage<void>(
      context,
      SourceDetailPage(
        book: book,
        client: _client,
        adapter: _adapter,
        downloadManager: _downloadManager,
        local: widget.local,
        onBookSaved: _shelfBook,
      ),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  /// 后台下载状态条：显示进行中/暂停的下载，点击暂停验证时触发验证。
  Widget _buildDownloadBar() {
    return ListenableBuilder(
      listenable: _downloadManager,
      builder: (context, _) {
        final active = _downloadManager.tasks
            .where(
              (t) =>
                  t.status == SourceDownloadStatus.downloading ||
                  t.status == SourceDownloadStatus.pausedNeedVerify,
            )
            .toList();
        if (active.isEmpty && !_downloadManager.needsVerify) {
          return const SizedBox.shrink();
        }
        final task = active.isNotEmpty ? active.first : null;
        final paused = _downloadManager.needsVerify ||
            (task?.status == SourceDownloadStatus.pausedNeedVerify);
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: paused ? _verifyForDownloads : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    paused
                        ? CupertinoIcons.exclamationmark_circle
                        : CupertinoIcons.arrow_down_circle,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      paused
                          ? '下载已暂停，需要验证，点击继续验证'
                          : '后台下载《${task!.detail.book.title}》 '
                              '${task.done}/${task.total}',
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (task != null && !paused)
                    SizedBox(
                      width: 60,
                      child: LinearProgressIndicator(
                        value: task.total == 0
                            ? null
                            : task.done / task.total,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源搜索 · 123小说网'),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.gear),
            tooltip: '站点设置',
            onPressed: _showBaseUrlDialog,
          ),
        ],
      ),
      body: IndexedStack(
        index: _verifying ? 1 : 0,
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _keyword,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '输入书名或作者搜索',
                          prefixIcon: Icon(CupertinoIcons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _searching ? null : _search,
                      child: const Text('搜索'),
                    ),
                  ],
                ),
              ),
              if (_searching) const LinearProgressIndicator(),
              _buildDownloadBar(),
              Expanded(
                child: _buildBody(),
              ),
            ],
          ),
          // 内嵌 WebView：正常尺寸，平时在主内容下方（IndexedStack index 0），
          // 验证时切换到前台。避免 1px 隐藏被识别为无头浏览器。
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '请在下方完成网站验证',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        // 用户取消验证
                        _webViewSession.setVerifying(false);
                        _pendingRetry = null;
                        setState(() => _verifying = false);
                      },
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _onVerifyDone,
                      child: const Text('已完成验证'),
                    ),
                  ],
                ),
              ),
              Expanded(
                // session 作废旧实例（超时隔离）后重建 WebView
                child: ValueListenableBuilder<int>(
                  valueListenable: _webViewSession.instanceNotifier,
                  builder: (context, instance, _) {
                    return InAppWebView(
                      key: ValueKey(instance),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        userAgent: sourceUserAgent,
                      ),
                      initialUrlRequest: URLRequest(
                        url: WebUri.uri(
                            Uri.parse(SourceConfig.instance.baseUrl)),
                      ),
                      onWebViewCreated: (controller) =>
                          _webViewSession.attach(controller, instance),
                      onLoadStart: (controller, url) {
                        _webViewSession.onLoadStart(
                          url == null ? null : Uri.tryParse(url.toString()),
                          instance,
                        );
                      },
                      onLoadStop: (controller, url) {
                        _webViewSession.onLoadStop(
                          url == null ? null : Uri.tryParse(url.toString()),
                          instance,
                        );
                      },
                      onReceivedError: (controller, request, error) {
                        // 仅主框架错误有效（isForMainFrame），带 URL 归属
                        if (request.isForMainFrame == true) {
                          _webViewSession.onReceivedError(
                            error.description,
                            request.url == null
                                ? null
                                : Uri.tryParse(request.url.toString()),
                            instance,
                          );
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showBaseUrlDialog() async {
    final controller = TextEditingController(
      text: SourceConfig.instance.baseUrl,
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('站点基址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '站点换域名时可在此修改。修改后将清理当前会话，请重新验证。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('__reset__'),
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    if (result == '__reset__') {
      await SourceConfig.instance.resetToDefault();
      _client.clearCookies();
      showNovelFeedback(context, '已恢复默认基址');
      return;
    }
    final error = await SourceConfig.instance.setBaseUrl(result);
    if (!mounted) return;
    if (error != null) {
      showNovelFeedback(context, error);
    } else {
      // 基址变更：清理旧域会话，避免把旧 Cookie 发到新域名。
      _client.clearCookies();
      showNovelFeedback(context, '基址已更新');
    }
  }

  Widget _buildBody() {
    if (_error != null && _results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text('试验功能：搜索站内书籍，下载后转本地 TXT 阅读'),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final book = _results[i];
        return ListTile(
          title: Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (book.author.isNotEmpty) book.author,
              if (book.status != null) book.status!,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
          onTap: () => _openDetail(book),
        );
      },
    );
  }
}
