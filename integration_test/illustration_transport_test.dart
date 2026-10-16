import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/reader_content.dart';

/// Explicit QA-device integration: public book content only, no account call.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('original image host redirects yield decodable native images', (
    tester,
  ) async {
    for (final address in [
      'https://pic.wenku8.cn/pictures/1/1305/41759/50471.jpg',
      'https://pic.wenku8.com/pictures/1/1305/41759/50471.jpg',
      'https://pic.777743.xyz/1/1305/41759/50471.jpg',
    ]) {
      final bytes = await LegacyTransport.illustration(address);
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 100);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
      expect(frame.image.height, greaterThan(0));
      debugPrint(
        'LIVE_ILLUSTRATION_OK host=${Uri.parse(address).host} bytes=${bytes.length}',
      );
      frame.image.dispose();
      codec.dispose();
    }
  });
  testWidgets('live chapter markers parse into ordered image paragraphs', (
    tester,
  ) async {
    final repository = LegacyWenkuRepository();
    final chapters = await repository.chapters(1305);
    final chapter = chapters.firstWhere((c) => c.title.contains('插图'));
    final content = await ReaderContent.parse(
      await repository.chapterContent(1305, chapter),
    );
    expect(content.illustrations, isNotEmpty);
    expect(content.paragraphs.where((p) => p.trim() == '[插图]'), isEmpty);
    final bytes = await LegacyTransport.illustration(
      content.illustrations.first,
    );
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 100);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, greaterThan(0));
    debugPrint(
      'LIVE_CHAPTER_ILLUSTRATIONS_OK book=1305 cid=${chapter.id} count=${content.illustrations.length} host=${Uri.parse(content.illustrations.first).host}',
    );
    frame.image.dispose();
    codec.dispose();
  });
}
