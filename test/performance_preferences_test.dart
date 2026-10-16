import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_wave.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/low_performance_page.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/performance_preferences.dart';
import 'support/visual_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  late LibraryState state;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = await LibraryState.load();
  });
  tearDown(() => state.dispose());

  test(
    'preset is opt-in and custom switches survive leaving the mode and reloading',
    () async {
      expect(state.performance.enabled, false);
      expect(PerformanceEffect.values.every(state.performance.allows), true);
      await state.setGlassBlur(11);
      await state.setGlassOpacity(.3);
      await state.setPerformance(state.performance.withEnabled(true));
      expect(PerformanceEffect.values.any(state.performance.allows), false);
      expect(state.effectiveReduceMotion, true);
      await state.setPerformance(
        state.performance.withEffect(PerformanceEffect.edgeBlur, true),
      );
      await state.setPerformance(state.performance.withEnabled(false));
      expect(state.effectiveReduceMotion, false);
      expect(state.glassBlur, 11);
      expect(state.glassOpacity, .3);
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.performance.enabled, false);
      await restored.setPerformance(restored.performance.withEnabled(true));
      expect(restored.performance.edgeBlur, true);
      expect(restored.performance.glass, false);
      expect(restored.performance.blur, false);
      await restored.setReduceMotion(true);
      await restored.setPerformance(restored.performance.withEnabled(false));
      expect(restored.effectiveReduceMotion, true);
    },
  );

  test(
    'backup merges performance switches only when preferences are requested',
    () async {
      const preferences = PerformancePreferences(
        enabled: true,
        effects: {PerformanceEffect.glass, PerformanceEffect.motion},
      );
      await state.setPerformance(preferences);
      final backup = await state.createBackup();
      final parsed = await LibraryBackup.parse(await backup.encode());
      await state.setPerformance(const PerformancePreferences());
      await state.restoreBackup(parsed);
      expect(state.performance.enabled, false);
      await state.restoreBackup(parsed, importPreferences: true);
      expect(state.performance, preferences);
      // Older backups lack these keys and must not reset a newer device preset.
      await state.restoreBackup(
        await LibraryBackup.fromRecords({'theme': 'light'}),
        importPreferences: true,
      );
      expect(state.performance, preferences);
      await expectLater(
        LibraryBackup.fromRecords({'performanceBlur': 'yes'}),
        throwsA(isA<FormatException>()),
      );
    },
  );

  testWidgets(
    'light preset removes filters and 3D rendering while cover navigation remains usable',
    (tester) async {
      Novel? opened;
      var preferences = const PerformancePreferences(enabled: true);
      Widget scene() => MaterialApp(
        theme: novelTheme(Brightness.light),
        home: PerformanceScope(
          preferences: preferences,
          child: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  height: 80,
                  child: LiquidGlass(blur: 12, child: Text('轻量玻璃')),
                ),
                const SizedBox(height: 40, child: ProgressiveBlur(maxSigma: 8)),
                ArchiveFileCarousel(
                  books: demoNovels.take(3).toList(),
                  onOpen: (book, _) => opened = book,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(scene());
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(
        find.byKey(const ValueKey('archive-flat-carousel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('archive-file-carousel')), findsNothing);
      await tester.tap(find.text(demoNovels.first.title).last);
      expect(opened?.id, demoNovels.first.id);
      await tester.drag(
        find.byKey(const ValueKey('archive-flat-carousel')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      preferences = preferences.withEffect(PerformanceEffect.blur, true);
      await tester.pumpWidget(scene());
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsOneWidget);
      // Edge blur remains independently off.
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_NativeBackdropWidget',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'settings can customize and reset the preset without exposing diagnostics',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.runAsync(
        () => state.setPerformance(const PerformancePreferences(enabled: true)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => RepaintBoundary(
            key: boundary,
            child: PerformanceScope(
              preferences: state.performance,
              child: child!,
            ),
          ),
          home: LowPerformancePage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      final glass = find.byKey(const ValueKey('performanceGlass'));
      expect(tester.widget<CupertinoSwitch>(glass).value, false);
      await tester.tap(glass);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(state.performance.glass, true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('performance-light-preset')),
      );
      await tester.tap(find.byKey(const ValueKey('performance-light-preset')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(state.performance.glass, false);
      expect(tester.takeException(), isNull);
      await captureReview(tester, boundary, 'low-performance-settings');
    },
  );

  testWidgets(
    'app applies reduced motion globally without overwriting the reading preference',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => state.setPerformance(const PerformancePreferences(enabled: true)),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: NovelApp(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ArchiveFileCarousel).first);
      expect(MediaQuery.disableAnimationsOf(context), true);
      expect(state.reduceMotion, false);
      await captureReview(tester, boundary, 'low-performance-discovery');
      await tester.runAsync(
        () => state.setPerformance(
          state.performance.withEffect(PerformanceEffect.motion, true),
        ),
      );
      await tester.pumpAndSettle();
      expect(MediaQuery.disableAnimationsOf(context), false);
      expect(find.text('帧耗时采样'), findsNothing);
      expect(
        find.byKey(const ValueKey('detail-performance-entry')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
