/// 书源试验版（source-trial 分支）：站点基址配置。
///
/// 内置默认地址 + 用户手动修改，不做多域名自动轮询。
/// 修改成功后调用方负责取消旧请求、清理域名相关缓存。
library;

import 'package:shared_preferences/shared_preferences.dart';

class SourceConfig {
  SourceConfig._();

  static const String _prefsKey = 'source_trial_base_url';

  /// 内置默认基址。
  static const String defaultBaseUrl = 'https://www.banzhu22222222.net/';

  /// 站点指纹：连接测试时用于确认页面确实是目标站，
  /// 不能只看 HTTP 200（Cloudflare 挑战页也是 200）。
  static const List<String> siteFingerprints = ['123小说网'];

  String _baseUrl = defaultBaseUrl;
  String get baseUrl => _baseUrl;

  static final SourceConfig instance = SourceConfig._();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && _isValidBaseUrl(saved)) {
      _baseUrl = _normalize(saved);
    }
  }

  /// 设置新基址。返回 null 表示成功，否则返回错误原因。
  Future<String?> setBaseUrl(String value) async {
    final normalized = _normalize(value.trim());
    if (!_isValidBaseUrl(normalized)) {
      return '地址不合法，请输入 https:// 开头的完整地址';
    }
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(_prefsKey, normalized);
    if (!ok) return '保存失败，请重试';
    _baseUrl = normalized;
    return null;
  }

  Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    _baseUrl = defaultBaseUrl;
  }

  /// 用基址解析相对链接。
  String resolve(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = _baseUrl.endsWith('/') ? _baseUrl : '$_baseUrl/';
    final path = url.startsWith('/') ? url.substring(1) : url;
    return '$base$path';
  }

  static String _normalize(String value) {
    var v = value.trim();
    if (!v.endsWith('/')) v = '$v/';
    return v;
  }

  static bool _isValidBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        !uri.userInfo.isNotEmpty;
  }
}
