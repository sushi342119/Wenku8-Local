/// 书源试验版（source-trial 分支）：Cloudflare 验证页。
///
/// 用户在可见 WebView 内完成网站验证；应用以"拿到可解析的业务页面"为准
/// 确认验证成功（不只看标题或 cf_clearance），然后经 CookieManager 提取
/// 会话 Cookie（含 HttpOnly）交给下载层复用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'source_client.dart';

/// 验证结果：域名 -> {cookie名: cookie值}。
typedef VerifyResult = Map<String, Map<String, String>>;

class CloudflareVerifyPage extends StatefulWidget {
  const CloudflareVerifyPage({super.key, required this.targetUrl});

  /// 需要验证后访问的目标页面。
  final Uri targetUrl;

  @override
  State<CloudflareVerifyPage> createState() => _CloudflareVerifyPageState();
}

class _CloudflareVerifyPageState extends State<CloudflareVerifyPage> {
  InAppWebViewController? _controller;
  bool _checking = false;
  String _hint = '请在页面中完成网站验证，通过后将自动继续';
  bool _done = false;

  Future<void> _onLoadStop(Uri? url) async {
    if (_checking || _done || !mounted) return;
    _checking = true;
    try {
      final title = await _controller?.getTitle() ?? '';
      final urlStr = url?.toString() ?? '';
      final lower = title.toLowerCase();
      final isChallenge =
          lower.contains('just a moment') ||
          urlStr.contains('__cf_chl_') ||
          lower.contains('attention required');
      if (isChallenge) {
        setState(() => _hint = '检测到网站验证，请按页面提示完成（可能需要点复选框）');
        return;
      }
      if (title.trim().isEmpty) {
        setState(() => _hint = '页面加载中，请稍候…');
        return;
      }
      // 非挑战页且标题非空：视为业务页面已出现，提取 Cookie。
      final cookies = await _collectCookies(url);
      if (!mounted || _done) return;
      _done = true;
      Navigator.of(context).pop(cookies);
    } catch (_) {
      if (mounted) setState(() => _hint = '验证状态确认失败，可手动刷新页面重试');
    } finally {
      _checking = false;
    }
  }

  Future<VerifyResult> _collectCookies(Uri? url) async {
    final result = <String, Map<String, String>>{};
    if (url == null) return result;
    final manager = CookieManager.instance();
    // 取目标 URL 的全部 Cookie（含 HttpOnly，如 cf_clearance）。
    try {
      final list = await manager.getCookies(url: url);
      if (list.isNotEmpty) {
        final host = url.host.toLowerCase();
        result[host] = {
          for (final c in list)
            if (c.name != null): c.name!: c.value ?? '',
        };
      }
    } catch (_) {}
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网站验证'),
        actions: [
          TextButton(
            onPressed: () async {
              final url = await _controller?.getUrl();
              _onLoadStop(url?.uriValue);
            },
            child: const Text('已完成验证'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(_hint, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri.uri(widget.targetUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                userAgent: sourceUserAgent,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStop: (controller, url) => _onLoadStop(url?.uriValue),
            ),
          ),
        ],
      ),
    );
  }
}
