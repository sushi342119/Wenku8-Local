import 'dart:async';
import 'dart:io';
import 'font_catalog.dart';
export 'font_catalog.dart';

class FontDownloadProgress {
  const FontDownloadProgress(
    this.received,
    this.total, {
    this.validating = false,
  });
  final int received, total;
  final bool validating;
  double get fraction => (received / total).clamp(0, 1);
  int get percent => (fraction * 100).floor();
}

class FontDownloadCancelled implements Exception {
  const FontDownloadCancelled();
}

class FontDownloadCancellation {
  bool cancelled = false;
  HttpClient? _client;
  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }

  void check() {
    if (cancelled) throw const FontDownloadCancelled();
  }
}

/// Explicit, user-initiated downloads only. No account or reading data is sent.
/// Fixed font releases, streamed to a temporary file. No app Worker quota,
/// account credential or paid font API is used.
class FontDownloadClient {
  FontDownloadClient({List<Uri>? sources})
    : sources =
          sources ?? downloadableFonts.first.sourceUrls.map(Uri.parse).toList();
  final List<Uri> sources;

  Future<void> download(
    File target, {
    required FontDownloadCancellation cancellation,
    required void Function(FontDownloadProgress) onProgress,
    int expectedBytes = sourceHanFontBytes,
    List<Uri>? from,
  }) async {
    final endpoints = from ?? sources;
    for (final (index, source) in endpoints.indexed) {
      cancellation.check();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      cancellation._client = client;
      RandomAccessFile? output;
      try {
        final request = await client
            .getUrl(source)
            .timeout(const Duration(seconds: 20));
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode != HttpStatus.ok) {
          throw const FormatException('字体下载暂不可用，请稍后重试');
        }
        if (response.contentLength >= 0 &&
            response.contentLength != expectedBytes) {
          throw const FormatException('字体下载内容不完整，请重试');
        }
        output = await target.open(mode: FileMode.write);
        var received = 0, lastPercent = -1;
        onProgress(FontDownloadProgress(0, expectedBytes));
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          cancellation.check();
          received += chunk.length;
          if (received > expectedBytes) {
            throw const FormatException('字体下载内容超出预期，请重试');
          }
          await output.writeFrom(chunk);
          final progress = FontDownloadProgress(received, expectedBytes);
          if (progress.percent != lastPercent) {
            lastPercent = progress.percent;
            onProgress(progress);
          }
        }
        cancellation.check();
        if (received != expectedBytes) {
          throw const FormatException('字体下载中断，请重试');
        }
        await output.flush();
        return;
      } on FileSystemException {
        rethrow;
      } catch (error) {
        cancellation.check();

        if (index == endpoints.length - 1) {
          throw const FormatException('字体下载未完成，请检查网络后重试');
        }
      } finally {
        await output?.close();
        client.close(force: true);
        cancellation._client = null;
      }
    }
    throw const FormatException('字体下载暂不可用，请稍后重试');
  }
}
