import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/offline_cache.dart';

import '../test/offline_features_ui_test.dart' as features;
import '../test/support/offline_fixture.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final image =
      await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
          .toImage(pixelRatio: tester.view.devicePixelRatio);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  // ignore: avoid_print
  print('UI_REFINEMENT_CAPTURE=${file.path}');
  image.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NativeEffects.prepare);
  features.main(capture: _capture);
  testWidgets('Android app-private offline files survive a new store instance', (
    tester,
  ) async {
    final cache = await OfflineCacheStore.forApp();
    final book = offlineFixtureBook(81);
    await cache.clear();
    final epoch = cache.epochFor(book.id);
    await cache.saveBook(book, epoch: epoch);
    await cache.saveChapter(
      book.id,
      book.chapters.first.id,
      book.chapters.first.content,
      epoch: epoch,
    );
    final reopened = await OfflineCacheStore.forApp();
    await reopened.load();
    expect(reopened.book(book.id)!.cachedCount, 1);
    expect(
      await reopened.readChapter(book.id, book.chapters.first.id),
      book.chapters.first.content,
    );
    // ignore: avoid_print
    print(
      'OFFLINE_ANDROID_STORAGE cached=1 bytes=${reopened.bytes} support_directory=true',
    );
    await reopened.clear();
    reopened.dispose();
    cache.dispose();
  });
}
