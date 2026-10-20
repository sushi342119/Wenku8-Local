/// 书源试验版（source-trial 分支）：WebView 会话取页器。
///
/// 背景：Cloudflare 会校验 TLS 指纹。Dart HttpClient 即使带上验证后的
/// Cookie 仍会被拦（用户实测"验证后仍被拦截"）。本类改用 WebView 会话
/// 直接加载页面并经 JS 提取 HTML，指纹、Cookie 与验证时完全一致。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'source_client.dart';

/// WebView 会话：由 UI 层创建并持有控制器，提供 [fetchHtml] 取页。
///
/// - 串行执行：同一时刻只允许一个取页任务（避免多任务导航互相覆盖）。
/// - 导航同步：经 onLoadStop 确认目标页面加载完成，而非仅轮询 readyState
///  （避免读到旧页面）。
class WebViewSession implements WebViewFetcher {
  InAppWebViewController? _controller;
  Completer<void> _ready = Completer<void>();

  /// WebView 实例号。导航超时后作废旧实例并自增，页面监听到变化会
  /// 重建 WebView；旧实例的一切回调（带旧实例号）都会被拒绝，
  /// 从根本上隔离迟到回调。
  final ValueNotifier<int> instanceNotifier = ValueNotifier<int>(0);
  int get instance => instanceNotifier.value;

  /// 串行锁：上一个取页任务的 Future。
  Future<void> _lock = Future.value();

  /// UI 正在显示 WebView 供用户验证时为 true；此时取页等待验证完成，
  /// 避免下载/搜索的导航把验证页面覆盖掉。
  bool _verifying = false;
  void setVerifying(bool v) => _verifying = v;

  /// 当前取页任务的完成器（由 onLoadStop 触发）。
  Completer<Uri>? _loadCompleter;
  Uri? _expectUrl;

  /// 主框架加载错误（由 onReceivedError 记录，带请求 URL 与时间做归属）。
  /// 消费后清空，避免旧错误污染新任务。
  String? _lastErrorUrl;
  String? _lastErrorDescription;
  DateTime? _lastErrorTime;
  DateTime? _navStartTime;

  /// 本次取页的导航是否已被确认启动（由与目标 URL 相符的 onLoadStart 武装）。
  /// 初始页加载等与本次无关的 onLoadStop 不会提前完成等待器。
  bool _navArmed = false;

  void attach(InAppWebViewController controller, int instance) {
    if (instance != this.instance) return; // 旧实例，忽略
    _controller = controller;
    if (!_ready.isCompleted) _ready.complete();
  }

  /// WebView 的 onReceivedError 回调应转发到此（仅主框架错误有效）。
  /// 传入触发错误的请求 URL，用于把错误归属到正确的导航。
  void onReceivedError(String? description, Uri? requestUrl, int instance) {
    if (instance != this.instance) return; // 旧实例的迟到回调，拒绝
    _lastErrorUrl = requestUrl?.removeFragment().toString();
    _lastErrorDescription = description ?? '页面加载失败';
    _lastErrorTime = DateTime.now();
  }

  /// 当前导航是否命中了记录的主框架错误。
  /// 须同时满足：URL 归属（请求 URL 或重定向后最终 URL）+ 错误发生在
  /// 本次导航窗口内（早于导航开始的迟到回调不认）。
  bool _hitMainFrameError(Set<String> navUrls) {
    final errUrl = _lastErrorUrl;
    final errTime = _lastErrorTime;
    final navStart = _navStartTime;
    _lastErrorUrl = null; // 消费：无论是否命中都清空
    _lastErrorTime = null;
    if (errUrl == null || errUrl.isEmpty) return false;
    if (!navUrls.contains(errUrl)) return false;
    if (navStart != null && errTime != null && errTime.isBefore(navStart)) {
      return false; // 上一导航迟到的回调
    }
    return true;
  }

  Future<void> get ready => _ready.future;

  /// WebView 的 onLoadStop 回调应转发到此。
  /// WebView 的 onLoadStart 回调应转发到此。
  /// 只有 URL 与本次取页目标相符时才武装（重定向链保持武装直到 onLoadStop）。
  void onLoadStart(Uri? url, int instance) {
    if (instance != this.instance) return; // 旧实例，忽略
    final expect = _expectUrl;
    if (expect != null && url != null &&
        url.removeFragment().toString() ==
            expect.removeFragment().toString()) {
      _navArmed = true;
    }
  }

  void onLoadStop(Uri? url, int instance) {
    if (instance != this.instance) return; // 旧实例，忽略
    final c = _loadCompleter;
    if (c != null && !c.isCompleted && url != null && _navArmed) {
      _navArmed = false;
      c.complete(url);
    }
  }

  /// 以 fire-and-forget 方式停止旧控制器（带 2 秒上限，超时/异常都吞掉）。
  static Future<void> _stopOldLoading(
      InAppWebViewController controller) async {
    try {
      await controller.stopLoading().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// 作废当前 WebView 实例：清控制器/完成器/错误记录，实例号自增，
  /// 页面会据此重建 WebView。Cookie 由平台 CookieManager 持有，不受影响。
  void _invalidateInstance() {
    _controller = null;
    _loadCompleter = null;
    _lastErrorUrl = null;
    _lastErrorDescription = null;
    _lastErrorTime = null;
    _navArmed = false;
    _expectUrl = null;
    _ready = Completer<void>();
    instanceNotifier.value++;
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
    // 本次导航开始：清掉上一导航遗留的错误记录并记录开始时间。
    _lastErrorUrl = null;
    _lastErrorDescription = null;
    _lastErrorTime = null;
    _navStartTime = DateTime.now();
    _navArmed = false;

    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
      // 等待 onLoadStop（目标页面加载完成），带超时。
      Uri loadedUrl;
      try {
        loadedUrl = await loadCompleter.future.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('页面加载超时', timeout),
        );
      } on TimeoutException {
        // 超时时旧导航的回调可能仍会迟到：先作废整个 WebView 实例
        // （页面将重建），旧实例回调一律拒绝，避免污染下一次同 URL 取页；
        // 旧控制器的 stopLoading 以 fire-and-forget 方式执行，
        // 恢复与锁释放不依赖它返回。
        _invalidateInstance();
        unawaited(_stopOldLoading(controller));
        rethrow;
      } finally {
        if (_loadCompleter == loadCompleter) _loadCompleter = null;
      }

      // 主框架加载出错（如 DNS 失败）：绝不能把错误页当正文。
      final navUrls = <String>{
        uri.removeFragment().toString(),
        loadedUrl.removeFragment().toString(),
      };
      if (_hitMainFrameError(navUrls)) {
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
      // 返回 HTML 前再次检查：取 HTML 期间到达的错误。
      if (_hitMainFrameError(navUrls)) {
        throw WebViewPageError(_lastErrorDescription ?? '页面加载失败');
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
      _expectUrl = null;
      _navArmed = false;
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
/// 须同时满足：全文含错误码 + 正文有错误页的典型结构
/// （"网页无法打开"标题与"因为："说明），避免正文偶然提到
/// 错误码（如讨论网络问题）时误伤正常章节。
bool _looksLikeErrorPage(String html) {
  final lower = html.toLowerCase();
  const errorCodes = [
    'err_name_not_resolved',
    'err_internet_disconnected',
    'err_connection_',
    'net::err_',
  ];
  if (!errorCodes.any(lower.contains)) return false;
  return lower.contains('网页无法打开') && lower.contains('因为：');
}
