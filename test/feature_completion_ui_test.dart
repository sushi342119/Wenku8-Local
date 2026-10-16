import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/legacy_import_page.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';

import 'support/cover_fixture.dart';

typedef FeatureCapture =
    Future<void> Function(WidgetTester tester, GlobalKey key, String name);

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  GlobalKey? key,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(theme: novelTheme(brightness), home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main({FeatureCapture? capture}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('wide glass actions respond across the complete visible plate', (
    tester,
  ) async {
    var taps = 0;
    const buttonKey = ValueKey('wide-glass-action');
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: GlassTextButton(
              key: buttonKey,
              onPressed: () => taps++,
              child: const Text('完整触摸区域'),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byKey(buttonKey));
    for (final point in [
      rect.center,
      rect.centerLeft + const Offset(40, 0),
      rect.centerRight - const Offset(40, 0),
    ]) {
      await tester.tapAt(point);
      await tester.pumpAndSettle();
    }
    expect(taps, 3);
    expect(tester.takeException(), isNull);
  });


  testWidgets(
    'illustration uses static skeleton, one arrival and zoom gallery',
    (tester) async {
      final held = Completer<Uint8List>();
      final bytes = await tester.runAsync(coverFixtureBytes);
      var calls = 0;
      final cache = ReaderIllustrationCache(
        request: (_) {
          calls++;
          return held.future;
        },
      );
      final key = GlobalKey();
      await _pump(
        tester,
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 440,
              child: ReaderIllustration(
                url: 'https://img.wenku8.com/a.jpg',
                cache: cache,
              ),
            ),
          ),
        ),
        key: key,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LoadingSkeleton), findsOneWidget);
      if (capture != null) await capture(tester, key, 'reader-image-skeleton');
      held.complete(bytes!);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(LoadingSkeleton), findsNothing);
      if (capture != null) await capture(tester, key, 'reader-image-ready');
      await _pump(
        tester,
        ReaderIllustrationGallery(
          urls: const ['https://img.wenku8.com/a.jpg'],
          initialUrl: 'https://img.wenku8.com/a.jpg',
          cache: cache,
        ),
        key: key,
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      if (capture != null) await capture(tester, key, 'reader-image-gallery');
      await tester.pumpWidget(const SizedBox.shrink());
      cache.clearMemory();
    },
  );

  testWidgets('legacy import is previewed before any local state change', (
    tester,
  ) async {
    final state = await LibraryState.load();
    await state.addShelfIds([71]);
    final key = GlobalKey();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      LocalPlatform.channel,
      (call) async {
        expect(call.method, 'importLegacyData');
        return {
          'documents': {
            'bookshelf_local.wk8': {'text': '72||73', 'modifiedAt': 1000},
            'read_saves_v1.wk8': {'text': '72:1:72002:3:4', 'modifiedAt': 1000},
          },
          'skippedFiles': 0,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        LocalPlatform.channel,
        null,
      ),
    );
    await _pump(tester, LegacyImportPage(state: state), key: key);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('legacy-choose')),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(state.shelf, {71});
    expect(find.text('导入预览'), findsOneWidget);
    if (capture != null) await capture(tester, key, 'legacy-import-preview');
    await tester.ensureVisible(find.byKey(const ValueKey('legacy-merge')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GlassTextButton>(find.byKey(const ValueKey('legacy-merge')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('legacy-merge')));
    await tester.pumpAndSettle();
    expect(state.shelf, {71, 72, 73});
    expect(state.positionFor(72)!.chapterId, 72002);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

}
