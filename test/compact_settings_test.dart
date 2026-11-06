import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/appearance_performance_panel.dart';
import 'package:shuyu/archive_wave.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_backup.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/main.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/performance_preferences.dart';
import 'package:shuyu/ui_preferences.dart';

import 'support/pump_storage.dart';
import 'support/visual_review.dart';

void main() {
  setUpAll(loadReviewFonts);

  test(
    'old backup cannot revive removed appearance overrides after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.setGlassTier(GlassTier.strong);
      await state.setMotionLevel(MotionLevel.standard);
      final backup = await LibraryBackup.fromRecords({
        'reduceMotion': true,
        'lowPerformanceMode': true,
        'performanceBlur': false,
        'glassAdvanced': true,
        'glassBlur': 22.0,
        'glassOpacity': .1,
        'glassTier': 'light',
        'motionLevel': 'off',
      });
      await state.restoreBackup(backup);
      expect(state.glassTierChoice, GlassTier.strong);
      expect(state.motionLevel, MotionLevel.standard);
      await state.restoreBackup(backup, importPreferences: true);
      expect(state.performance, const PerformancePreferences());
      expect(state.glassAdvanced, isFalse);
      expect(state.reduceMotion, isTrue, reason: 'the visible motion tier is off');
      expect(state.glassTierChoice, GlassTier.light);
      expect(state.resolvedGlass.blur, 4);
      expect(state.motionLevel, MotionLevel.off);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool('reduceMotion'), isFalse);
      expect(prefs.getBool('lowPerformanceMode'), isFalse);
      expect(prefs.getBool('glassAdvanced'), isFalse);
      final restarted = await LibraryState.load();
      addTearDown(restarted.dispose);
      expect(restarted.glassAdvanced, isFalse);
      expect(restarted.resolvedGlass.blur, 4);
      expect(restarted.motionLevel, MotionLevel.off);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('toolbox labels remain complete at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: SettingsPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      for (final title in ['主题调节', '字体管理', '正文替换']) {
        await tester.ensureVisible(find.text(title));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.text(title)).maxLines, isNull);
        expect(tester.takeException(), isNull);
      }
      expect(find.byKey(const ValueKey('settings-dictionaries')), findsNothing);
      expect(find.text('减少动态效果'), findsNothing);
      expect(find.byKey(const ValueKey('glass-tier-picker')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('compact settings expand and save at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AppearancePerformancePanel(state: state),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('glass-tier-picker')), findsNothing);
      final toggle = find.byKey(
        const ValueKey('appearance-performance-toggle'),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('强'));
      await pumpUntil(tester, () => state.glassTierChoice == GlassTier.strong);
      await tester.pumpAndSettle();
      expect(find.textContaining('玻璃：强'), findsOneWidget);
      final auto = find.byKey(const ValueKey('glass-tier-auto'));
      await tester.ensureVisible(auto);
      await tester.tap(auto);
      await pumpUntil(tester, () => state.glassTierChoice == null);
      await tester.pumpAndSettle();
      expect(find.textContaining('玻璃：自动·标准'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-tier-picker')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('discovery pager shares reset row or wraps at scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: DiscoverPage(
              state: state,
              books: demoNovels,
              repository: const DemoNovelRepository(),
              onSearch: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final footer = find.byKey(const ValueKey('archive-carousel-footer'));
      expect(
        find.descendant(of: footer, matching: find.text('重置抽取记录')),
        findsOneWidget,
      );
      expect(find.byType(ArchiveFileCarousel), findsOneWidget);
      final rect = tester.getRect(find.text('重置抽取记录'));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
      final emptyTag = await pumpStorage(
        tester,
        () => TagStore.shared.createTag('空标签'),
      );
      LibraryFilter.shared.setSingleTag(emptyTag);
      await tester.pumpAndSettle();
      expect(find.text('该标签下暂无书籍'), findsOneWidget);
      expect(find.text('空标签'), findsWidgets);
      expect(find.text('重置抽取记录'), findsOneWidget);
      final clear = find.widgetWithText(ChoiceChip, '全部');
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('archive-carousel-footer')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('motion selector and system reduced motion agree across scopes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await state.setMotionLevel(MotionLevel.off);
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    var context = tester.element(find.byType(ArchiveFileCarousel));
    expect(MediaQuery.disableAnimationsOf(context), isTrue);
    expect(PerformanceScope.reduceMotionOf(context), isTrue);
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    await pumpStorage(tester, () => state.setMotionLevel(MotionLevel.standard));
    await tester.pumpAndSettle();
    context = tester.element(find.byType(ArchiveFileCarousel));
    expect(MediaQuery.disableAnimationsOf(context), isTrue);
    expect(PerformanceScope.reduceMotionOf(context), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
