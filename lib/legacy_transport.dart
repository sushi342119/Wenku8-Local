import 'package:flutter/services.dart';
import 'reader_content.dart' show normalizeReaderIllustrationUrl;

/// The same v1.30 POST bridge. All requests are anonymous; account features
/// have been removed, so no session cookies are ever used.
abstract final class LegacyTransport {
  static const channel = MethodChannel('org.mewx.wenku8/legacy_api');
  static Future<String> request(String action) => _text('request', action);
  static Future<String> _text(String method, String action) async {
    final text = await channel.invokeMethod<String>(method, {'action': action});
    if (text == null || text.trim().isEmpty) {
      throw const FormatException('接口返回空内容');
    }
    return text;
  }

  static Future<Uint8List> illustration(String url) async {
    final normalized = normalizeReaderIllustrationUrl(url);
    if (normalized == null) {
      throw const FormatException('插图地址格式无效');
    }
    final bytes = await channel.invokeMethod<Uint8List>('illustration', {
      'url': normalized,
    });
    if (bytes == null || bytes.isEmpty) throw const FormatException('插图内容为空');
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('插图大小无效');
    }
    return bytes;
  }
}
