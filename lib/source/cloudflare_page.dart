/// 书源试验版（source-trial 分支）：Cloudflare 验证页。
///
/// 用户在可见 WebView 内完成网站验证；应用以"拿到可解析的业务页面"为准
/// 确认验证成功（不只看标题或 cf_clearance），然后经 CookieManager 提取
/// 会话 Cookie 交给下载层复用。
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  bool _checking = false;
  String _hint = '请在页面中完成网站验证，通过后将自动继续';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(sourceUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _onPageFinished(),
        ),
      )
      ..loadRequest(widget.targetUrl);
  }

  Future<void> _onPageFinished() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      final title = await _controller.getTitle() ?? '';
      final url = await _controller.currentUrl() ?? '';
      // 挑战页特征：标题含 Just a moment / 验证字样且 URL 带 cf 挑战参数。
      final lower = title.toLowerCase();
      final isChallenge =
          lower.contains('just a moment') ||
          url.contains('__cf_chl_') ||
          lower.contains('attention required');
      if (isChallenge) {
        setState(() => _hint = '检测到网站验证，请按页面提示完成（可能需要点复选框）');
        return;
      }
      // 非挑战页：试读确认——页面标题非空即视为业务页面已出现。
      // 更严格的确认（解析出正文）由调用方在拿到 Cookie 后用 HTTP 试读完成。
      if (title.trim().isEmpty) {
        setState(() => _hint = '页面加载中，请稍候…');
        return;
      }
      final cookies = await _collectCookies(url);
      if (!mounted) return;
      Navigator.of(context).pop(cookies);
    } catch (_) {
      if (mounted) setState(() => _hint = '验证状态确认失败，可手动刷新页面重试');
    } finally {
      _checking = false;
    }
  }

  Future<VerifyResult> _collectCookies(String url) async {
    final uri = Uri.tryParse(url);
    final result = <String, Map<String, String>>{};
    if (uri == null) return result;
    // 取目标域及其父域的 Cookie（Cloudflare 的 cf_clearance 等多为 HttpOnly，
    // 必须经 CookieManager 拿，不能依赖 document.cookie）。
    final hosts = <String>{uri.host};
    final parts = uri.host.split('.');
    if (parts.length > 2) hosts.add(parts.sublist(parts.length - 2).join('.'));
    for (final host in hosts) {
      try {
        final list = await _cookieManager.getCookies('https://$host/');
        if (list.isEmpty) continue;
        result[host] = {for (final c in list) c.name: c.value};
      } catch (_) {}
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网站验证'),
        actions: [
          TextButton(
            onPressed: () => _onPageFinished(),
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
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
