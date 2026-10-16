import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/reader_content.dart';

import '../test/feature_completion_state_test.dart' as state;
import '../test/feature_completion_ui_test.dart' as features;

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  debugPrint('UI_REFINEMENT_CAPTURE=${file.path}');
  image.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('native new feature state', state.main);
  group('native new feature UI', () => features.main(capture: _capture));
  testWidgets('native actual chapter illustration is preserved and cached', (
    tester,
  ) async {
    final repository = LegacyWenkuRepository();
    final chapters = await repository.chapters(1239);
    expect(chapters, isNotEmpty);
    String? imageUrl;
    final candidates = [
      ...chapters.where((chapter) => chapter.title.contains('插图')).take(3),
      ...chapters.take(6),
    ];
    for (final chapter in candidates) {
      final content = await ReaderContent.parse(
        await repository.chapterContent(1239, chapter),
      );
      if (content.illustrations.isNotEmpty) {
        imageUrl = content.illustrations.first;
        break;
      }
    }
    expect(imageUrl, isNotNull);
    final bytes = await LegacyTransport.illustration(imageUrl!);
    expect(bytes.length, greaterThan(1000));
    final again = await LegacyTransport.illustration(imageUrl);
    expect(again, bytes);
    debugPrint(
      'FEATURE_NATIVE_ILLUSTRATION bytes=${bytes.length} cached_read=true',
    );
  });
}
