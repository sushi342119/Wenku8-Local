/// 书源试验版（source-trial 分支）：网络客户端。
///
/// - 统一 User-Agent（与 WebView 验证会话保持一致，不随机切换）
/// - 手动 Cookie 管理（WebView 验证后导入的会话 Cookie）
/// - Cloudflare 挑战检测（以"拿到可解析的业务页面"为准，不只看标题）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gbk_codec.dart';

/// 统一请求 UA：桌面 Chrome。WebView 验证页使用相同 UA，
/// 避免 Cloudflare 因客户端特征不一致拒绝复用会话。
const String sourceUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 页面拉取结果。
class SourcePage {
  const SourcePage({
    required this.url,
    required this.statusCode,
    required this.html,
    required this.challenged,
  });

  final Uri url;
  final int statusCode;
  final String html;

  /// 是否命中 Cloudflare / 人机验证（需要用户介入）。
  final bool challenged;
}

/// WebView 取页器接口（避免 source_client 与 webview_fetcher 循环导入）。
abstract class WebViewFetcher {
  Future<({Uri url, String html})> fetchHtml(
    Uri uri, {
    Duration timeout,
  });
}

class SourceClient {
  SourceClient({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  /// WebView 会话（可选）。设置后，[get] 改走 WebView 取页，
  /// 用于绕过 Cloudflare 对 Dart HttpClient 的 TLS 指纹拦截。
  /// 由 UI 层创建并管理生命周期。
  WebViewFetcher? webViewSession;

  /// domain -> {name: value}
  final Map<String, Map<String, String>> _cookies = {};

  /// 从 WebView 验证会话导入 Cookie（仅用于匹配域名）。
  void importCookies(String domain, Map<String, String> cookies) {
    final host = _cookieDomain(domain);
    final jar = _cookies.putIfAbsent(host, () => {});
    jar.addAll(cookies);
  }

  void clearCookies() => _cookies.clear();

  static String _cookieDomain(String domain) {
    var d = domain.toLowerCase();
    if (d.startsWith('.')) d = d.substring(1);
    return d;
  }

  String _cookieHeader(Uri uri) {
    final host = uri.host.toLowerCase();
    final parts = <String>[];
    _cookies.forEach((domain, jar) {
      if (host == domain || host.endsWith('.$domain')) {
        jar.forEach((name, value) => parts.add('$name=$value'));
      }
    });
    return parts.join('; ');
  }

  /// 拉取页面。遇到 Cloudflare 挑战时返回 challenged=true，由调用方
  /// 打开 WebView 请用户完成验证（不自动重试、不静默跳过）。
  ///
  /// 若 [webViewSession] 已设置，则改走 WebView 会话取页（绕过 TLS 指纹拦截）。
  Future<SourcePage> get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final session = webViewSession;
    if (session != null) {
      final result = await session.fetchHtml(uri, timeout: timeout);
      // WebView 已处理跳转；挑战由 fetchHtml 内部抛 WebViewNeedVerify。
      // 这里再做一次保险检查。
      final challenged = _looksLikeChallenge(result.html);
      return SourcePage(
        url: result.url,
        statusCode: 200,
        html: result.html,
        challenged: challenged,
      );
    }
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    // 手动跟随重定向，以便在每一跳检查挑战页（per-request 设置 followRedirects）。
    try {
      var current = uri;
      for (var hop = 0; hop < 6; hop++) {
        final request = await client.getUrl(current);
        request.headers.set(HttpHeaders.userAgentHeader, sourceUserAgent);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        );
        request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
        final cookieHeader = _cookieHeader(current);
        if (cookieHeader.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
        }
        request.followRedirects = false;
        final response = await request.close().timeout(timeout);
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (_isRedirect(response.statusCode) && location != null) {
          await response.drain();
          current = current.resolve(location);
          continue;
        }
        final body = await _readBody(response, timeout);
        final challenged = _looksLikeChallenge(body);
        return SourcePage(
          url: current,
          statusCode: response.statusCode,
          html: body,
          challenged: challenged,
        );
      }
      throw const HttpException('重定向次数过多');
    } finally {
      client.close(force: true);
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  static Future<String> _readBody(
    HttpClientResponse response,
    Duration timeout,
  ) async {
    // 先按 header 猜编码，拿不到时再试 UTF-8 / GBK。
    final contentType = response.headers.contentType;
    var charset = contentType?.charset?.toLowerCase();
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const HttpException('页面过大');
      }
    }
    if (charset == null || charset.isEmpty) {
      // 从 <meta charset> 嗅探。
      final head = utf8.decode(bytes.take(4096).toList(), allowMalformed: true);
      final meta = RegExp(
        r'''<meta[^>]+charset\s*=\s*["']?([\w-]+)''',
        caseSensitive: false,
      ).firstMatch(head);
      charset = meta?.group(1)?.toLowerCase();
    }
    return _decodeBytes(bytes, charset);
  }

  static String _decodeBytes(List<int> bytes, String? charset) {
    final cs = (charset ?? '').toLowerCase();
    if (cs.contains('gbk') || cs.contains('gb2312') || cs.contains('gb18030')) {
      return gbkDecode(bytes);
    }
    if (cs.isEmpty || cs == 'utf-8' || cs == 'utf8') {
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } catch (_) {
        // 严格 UTF-8 失败时回退 GBK（中文小说站常见）。
        return gbkDecode(bytes);
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Cloudflare 挑战页检测：标题或特征标记。
  /// 注意：403 不一定是验证，空正文也不一定是会话过期，调用方需结合
  /// 页面内容区分"拒绝访问 / 限流 / 改版 / 网络失败"。
  static bool _looksLikeChallenge(String html) {
    final head = html.length > 8192 ? html.substring(0, 8192) : html;
    final lower = head.toLowerCase();
    return lower.contains('just a moment') ||
        lower.contains('__cf_chl_') ||
        lower.contains('challenges.cloudflare.com') ||
        (lower.contains('<title>') &&
            lower.contains('验证') &&
            lower.contains('cloudflare'));
  }
}
