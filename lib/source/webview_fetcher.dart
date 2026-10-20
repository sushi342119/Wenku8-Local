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
///
/// - 串行执行：同一时刻只允许一个取页任务（避免多任务导航互相覆盖）。
/// - 导航同步：经 onLoadStop 确认目标页面加载完成，而非仅轮询 readyState
///  （避免读到旧页面）。
class WebViewSession implements WebViewFetcher {
  InAppWebViewController? _controller;
  final Completer<void> _ready = Completer<void>();

  /// 串行锁：上一个取页任务的 Future。
  Future<void> _lock = Future.value();

  /// UI 正在显示 WebView 供用户验证时为 true；此时取页等待验证完成，
  /// 避免下载/搜索的导航把验证页面覆盖掉。
  bool _verifying = false;
  void setVerifying(bool v) => _verifying = v;

  /// 当前取页任务的完成器（由 onLoadStop 触发）。
  Completer<Uri>? _loadCompleter;
  Uri? _expectUrl;

  /// 主框架加载错误（由 onReceivedError 记录）。
  /// 键为导航批次（每次 fetchHtml 自增），避免旧错误污染新任务。
  int _navSeq = 0;
  int _errorNavSeq = -1;
  String? _lastErrorDescription;

  void attach(InAppWebViewController controller) {
    _controller = controller;
    if (!_ready.isCompleted) _ready.complete();
  }

  /// WebView 的 onReceivedError 回调应转发到此（仅主框架错误有效）。
  void onReceivedError(String? description) {
    _errorNavSeq = _navSeq;
    _lastErrorDescription = description ?? '页面加载失败';
  }

  Future<void> get ready => _ready.future;

  /// WebView 的 onLoadStop 回调应转发到此。
  void onLoadStop(Uri? url) {
    final c = _loadCompleter;
    if (c != null && !c.isCompleted && url != null) {
      // 只要有页面加载完成就通知；fetchHtml 会再校验 URL 是否匹配。
      c.complete(url);
    }
  }

  /// 加载 [uri]，等待加载完成后经 JS 取 outerHTML。
  /// 页面为验证页时抛 [WebViewNeedVerify]（调用方应将 WebView 变为可见，
  /// 待用户完成验证后重试）。
  @override
  Future<({Uri url, String html})> fetchHtml(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    // 串行化：排队等待上一个任务完成。
    final task = _lock.then((_) async {
      // 验证中时等待用户完成（最多 120 秒），避免导航覆盖验证页。
      final verifyDeadline = DateTime.now().add(
        const Duration(seconds: 120),
      );
      while (_verifying && DateTime.now().isBefore(verifyDeadline)) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (_verifying) throw TimeoutException('等待验证超时');
      return _fetchInner(uri, timeout);
    });
    // 无论成功失败，都更新锁（避免异常导致后续任务永久阻塞）。
    _lock = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<({Uri url, String html})> _fetchInner(
    Uri uri,
    Duration timeout,
  ) async {
    await ready;
    final controller = _controller;
    if (controller == null) throw StateError('WebView 未就绪');

    final loadCompleter = Completer<Uri>();
    _loadCompleter = loadCompleter;
    _expectUrl = uri;
    _navSeq++;
    final mySeq = _navSeq;

    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
      // 等待 onLoadStop（目标页面加载完成），带超时。
      Uri loadedUrl;
      try {
        loadedUrl = await loadCompleter.future.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('页面加载超时', timeout),
        );
      } finally {
        if (_loadCompleter == loadCompleter) _loadCompleter = null;
      }

      // 主框架加载出错（如 DNS 失败）：绝不能把错误页当正文。
      if (_errorNavSeq == mySeq) {
        throw WebViewPageError(_lastErrorDescription ?? '页面加载失败');
      }
      // 加载完成后取 HTML（此时文档已就绪）。
      String html = '';
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        try {
          final r = await controller.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          html = r?.toString() ?? '';
          if (html.length >= 100) break;
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (html.length < 100) {
        throw const WebViewFetchEmpty('页面内容为空');
      }
      // 兜底：错误页 HTML 特征检测（Chrome 错误页）。
      if (_looksLikeErrorPage(html)) {
        throw const WebViewPageError('页面加载失败（错误页）');
      }
      if (SourceClient.looksLikeChallenge(html)) {
        throw const WebViewNeedVerify();
      }
      final currentUrlStr = (await controller.getUrl())?.toString();
      return (
        url: Uri.tryParse(currentUrlStr ?? '') ?? loadedUrl,
        html: html,
      );
    } finally {
      if (_loadCompleter == loadCompleter) _loadCompleter = null;
    }
  }
}

class WebViewNeedVerify implements Exception {
  const WebViewNeedVerify();
  @override
  String toString() => '需要完成网站验证';
}

class WebViewFetchEmpty implements Exception {
  const WebViewFetchEmpty(this.message);
  final String message;
  @override
  String toString() => message;
}

/// WebView 页面加载错误（如 DNS 失败、连接超时）。
/// 调用方应将该章节标记为失败（可重试），绝不能存入正文。
class WebViewPageError implements Exception {
  const WebViewPageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Chrome 错误页特征（兜底检测）。
bool _looksLikeErrorPage(String html) {
  final lower = html.toLowerCase();
  return lower.contains('err_name_not_resolved') ||
      lower.contains('err_internet_disconnected') ||
      lower.contains('err_connection_') ||
      lower.contains('net::err_') ||
      (lower.contains('网页无法打开') && lower.contains('因为：'));
}
