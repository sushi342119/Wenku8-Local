import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
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


}
