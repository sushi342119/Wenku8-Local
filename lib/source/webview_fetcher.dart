/// 书源试验版（source-trial 分支）：WebView 会话取页器。
///
/// 背景：Cloudflare 会校验 TLS 指纹。Dart HttpClient 即使带上验证后的
/// Cookie 仍会被拦（用户实测"验证后仍被拦截"）。本类改用 WebView 会话
/// 直接加载页面并经 JS 提取 HTML，指纹、Cookie 与验证时完全一致。
library;

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'source_client.dart';

/// WebView 会话：由 UI 层创建并持有控制器，提供 [fetchHtml] 取页。
class WebViewSession implements WebViewFetcher {
  InAppWebViewController? _controller;
  final Completer<void> _ready = Completer<void>();

  void attach(InAppWebViewController controller) {
    _controller = controller;
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> get ready => _ready.future;

  /// 加载 [uri]，等待 document.readyState == complete 后经 JS 取 outerHTML。
  /// 页面为验证页时抛 [WebViewNeedVerify]（调用方应将 WebView 变为可见，
  /// 待用户完成验证后重试）。
  @override
  Future<({Uri url, String html})> fetchHtml(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await ready;
    final controller = _controller;
    if (controller == null) throw StateError('WebView 未就绪');
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 400));
      String? state;
      try {
        final r = await controller.evaluateJavascript(
          source: 'document.readyState',
        );
        state = r?.toString();
      } catch (_) {
        continue;
      }
      if (state != 'complete') continue;
      String html = '';
      try {
        final r = await controller.evaluateJavascript(
          source: 'document.documentElement.outerHTML',
        );
        html = r?.toString() ?? '';
      } catch (_) {
        continue;
      }
      if (html.length < 100) continue; // 内容太少，继续等
      if (SourceClient.looksLikeChallenge(html)) {
        throw const WebViewNeedVerify();
      }
      final urlStr = (await controller.getUrl())?.toString();
      return (url: Uri.tryParse(urlStr ?? '') ?? uri, html: html);
    }
    throw TimeoutException('页面加载超时', timeout);
  }
}

class WebViewNeedVerify implements Exception {
  const WebViewNeedVerify();
  @override
  String toString() => '需要完成网站验证';
}
