/// 书源试验版（source-trial 分支）：书源搜索页。
///
/// 关键词搜索 → 结果列表 → 点击进入详情页。
/// 仅在试验通道（TRIAL_CHANNEL=true）下可进入。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../local_library.dart';
import '../app_interactions.dart' show pushNovelPage, showNovelFeedback;
import 'cloudflare_page.dart';
import 'site_123.dart';
import 'site_adapter.dart';
import 'source_client.dart';
import 'source_config.dart';
import 'source_detail_page.dart';
import 'source_models.dart';

class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({super.key, required this.local});

  final LocalLibraryStore local;

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final TextEditingController _keyword = TextEditingController();
  final SourceClient _client = SourceClient();
  final SiteAdapter _adapter = Site123Adapter();

  bool _searching = false;
  String? _error;
  List<SourceBook> _results = [];

  @override
  void initState() {
    super.initState();
    SourceConfig.instance.load();
  }

  @override
  void dispose() {
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 打开 WebView 验证，成功后导入 Cookie 并重试原操作。
  /// 返回 true 表示验证成功（调用方重试），false 表示用户取消。
  Future<bool> _verifyThenRetry(Future<void> Function() retry) async {
    final base = SourceConfig.instance.baseUrl;
    final result = await pushNovelPage<VerifyResult>(
      context,
      CloudflareVerifyPage(targetUrl: Uri.parse(base)),
    );
    if (result == null || result.isEmpty) {
      if (mounted) showNovelFeedback(context, '已取消验证');
      return false;
    }
    result.forEach(_client.importCookies);
    // 验证后试读：确认会话可被下载层复用（第一道验收门槛）。
    try {
      final probe = await _client.get(Uri.parse(base));
      if (probe.challenged) {
        if (mounted) showNovelFeedback(context, '验证后仍被拦截，请重试');
        return false;
      }
    } catch (e) {
      if (mounted) showNovelFeedback(context, '验证后试读失败：$e');
      return false;
    }
    await retry();
    return true;
  }

  void _openDetail(SourceBook book) {
    pushNovelPage<void>(
      context,
      SourceDetailPage(
        book: book,
        client: _client,
        adapter: _adapter,
        onVerify: _verifyThenRetry,
        local: widget.local,
      ),
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
      body: Column(
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
          Expanded(
            child: _buildBody(),
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
