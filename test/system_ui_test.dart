import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';

void main() {
  testWidgets('detail headings remain readable after changing appearance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await state.setReduceMotion(true);
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(demoNovels.first.title).last);
    await tester.pumpAndSettle();
    await state.setTheme(ThemeMode.dark);
    await tester.pumpAndSettle();
    for (final text in [
      '图书详情',
      '简介',
      '目录',
      demoNovels.first.chapters.first.title,
    ]) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      expect(
        paragraph.text.style!.color!.computeLuminance(),
        greaterThan(.7),
        reason: 'Dark-theme heading must not keep the light theme ink: $text',
      );
    }
  });

  test('system bars are transparent without separate contrast scrims', () {
    for (final brightness in Brightness.values) {
      final style = novelSystemUiStyle(brightness);
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Colors.transparent);
      expect(style.systemNavigationBarDividerColor, Colors.transparent);
      expect(style.systemStatusBarContrastEnforced, isFalse);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
      expect(style.statusBarBrightness, brightness);
      final icons = brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark;
      expect(style.statusBarIconBrightness, icons);
      expect(style.systemNavigationBarIconBrightness, icons);
    }
  });

  testWidgets('system icons follow app appearance, not just the OS setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.dark);

    // Explicit dark appearance must stay readable on a light-mode Android OS.
    await state.setTheme(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.light);
    expect(
      SystemChrome.latestStyle!.systemNavigationBarIconBrightness,
      Brightness.light,
    );

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await state.setTheme(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.dark);
    expect(
      SystemChrome.latestStyle!.systemNavigationBarIconBrightness,
      Brightness.dark,
    );

    await state.setTheme(ThemeMode.system);
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.dark);
  });

  testWidgets(
    'detail removes the fixed cover glow and keeps compact safe chrome',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final dpr = tester.view.devicePixelRatio;
      tester.view.padding = FakeViewPadding(top: 48 * dpr, bottom: 24 * dpr);
      addTearDown(tester.view.resetPadding);
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      // In this compact safe-area fixture the taller archive bank scrolls.
      // Reveal the caption instead of tapping through the fixed bottom Dock.
      await tester.ensureVisible(
        find.byKey(const ValueKey('archive-shelf-open')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(demoNovels.first.title).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.byType(CoverGlow), findsNothing);
      final header = tester.getRect(find.byType(FrostedHeader));
      expect(header.top, 0);
      expect(
        header.height,
        48 + FrostedHeader.toolbarHeight + FrostedHeader.featherHeight,
      );
      final back = find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == '返回',
      );
      expect(tester.getRect(back).top, greaterThanOrEqualTo(48));
      final read = find.byKey(const ValueKey('detail-read-button'));
      final readSize = tester.getSize(read);
      expect(readSize.width, 196);
      // The chapter suffix may wrap with wide system glyphs. Keep the capsule
      // compact without shrinking typography or clipping its second line.
      expect(readSize.height, inInclusiveRange(54, 72));
      expect(find.text('开始阅读 · 第1章'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(DockUnderlay), findsOneWidget);
      for (final glass in tester.widgetList<LiquidGlass>(
        find.byType(LiquidGlass),
      )) {
        expect(glass.elevated, isFalse);
      }
      expect(
        SystemChrome.latestStyle!.statusBarIconBrightness,
        Brightness.dark,
      );
    },
  );
}
