import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/app_typography.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/low_performance_page.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/performance_preferences.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';
import 'package:wenku8_flutter/updates/update_page.dart';

import 'support/cover_fixture.dart';
import 'support/listening_fixture.dart';
import 'support/visual_review.dart';

class _AdaptiveUpdatePlatform implements UpdatePlatform {
  @override
  Future<InstalledApp> installedApp() async =>
      const InstalledApp(version: '0.2.0', build: 2, abis: ['arm64-v8a']);
  @override
  Future<String> install(File apk, String version) async => 'opened';
  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> openRelease(Uri page) async {}
}

class _AdaptiveUpdateSource implements UpdateSource {
  @override
  Future<AppRelease?> latest() async => AppRelease.fromGithub({
    'tag_name': 'v0.3.0',
    'body': '### 阅读改进\n- 优化阅读与听书体验。',
    'assets': [
      {
        'name': 'wenku8-0.3.0-arm64-v8a.apk',
        'size': 24000000,
        'browser_download_url':
            'https://github.com/example/reader/releases/download/v0.3.0/wenku8-0.3.0-arm64-v8a.apk',
      },
    ],
  }, 'example/reader');
  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int) progress,
  ) async {}
}

typedef AdaptiveCapture =
    Future<void> Function(WidgetTester tester, GlobalKey boundary, String name);

const _profiles = [
  (
    name: 'compact',
    size: Size(320, 640),
    scale: 1.0,
    inset: EdgeInsets.only(top: 28, bottom: 24),
  ),
  (
    name: 'phone',
    size: Size(390, 844),
    scale: 1.0,
    inset: EdgeInsets.only(top: 44, bottom: 34),
  ),
  (
    name: 'wide',
    size: Size(430, 932),
    scale: 1.0,
    inset: EdgeInsets.only(top: 48, bottom: 34),
  ),
  (
    name: 'large-text',
    size: Size(320, 640),
    scale: 2.0,
    inset: EdgeInsets.only(top: 28, bottom: 24),
  ),
  (
    name: 'landscape',
    size: Size(800, 360),
    scale: 1.0,
    inset: EdgeInsets.only(left: 44, right: 24, bottom: 24),
  ),
  (
    name: 'tablet',
    size: Size(800, 1280),
    scale: 1.0,
    inset: EdgeInsets.only(top: 28, bottom: 24),
  ),
];

Finder _button(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

void main({AdaptiveCapture? capture, bool native = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!native) {
    setUpAll(() async {
      await loadReviewFonts();
      await (FontLoader('SourceHanSerifCN')..addFont(
            rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf'),
          ))
          .load();
    });
  }
  for (final profile in _profiles) {
    testWidgets('adaptive ${profile.name}: library, overlays and listening', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = profile.size;
      tester.view.padding = FakeViewPadding(
        left: profile.inset.left,
        top: profile.inset.top,
        right: profile.inset.right,
        bottom: profile.inset.bottom,
      );
      tester.view.viewPadding = tester.view.padding;
      tester.platformDispatcher.textScaleFactorTestValue = profile.scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({
        'reduceMotion': true,
        'appTypeface': AppTypeface.sourceHanSerif.name,
      });
      final library = await LibraryState.load();
      final output = FakeListeningOutput();
      final updates = AppUpdates(
        preferences: await SharedPreferences.getInstance(),
        source: _AdaptiveUpdateSource(),
        platform: _AdaptiveUpdatePlatform(),
      );
      final controller = ListeningController(
        repository: const DemoNovelRepository(),
        audio: FakeSpeechAudio(),
        store: ListeningStore(await SharedPreferences.getInstance()),
        outputFactory: (_) async => output,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = controller.dispose();
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        await closing;
        library.dispose();
        updates.dispose();
      });
      final cover = await tester.runAsync(coverFixtureBytes);
      for (final novel in demoNovels) {
        LegacyCover.seedLocalBytes(novel.id, cover!);
      }
      await tester.runAsync(() async {
        for (final novel in demoNovels.take(3)) {
          await library.setShelfMembership(novel.id, true, novel: novel);
        }
      });
      final boundary = GlobalKey();
      Future<void> snapshot(String name) async {
        expect(tester.takeException(), isNull, reason: '${profile.name}/$name');
        if (capture != null) {
          await capture(tester, boundary, '${profile.name}-$name');
        } else {
          await captureReview(
            tester,
            boundary,
            'adaptive-${profile.name}-$name',
          );
        }
      }

      void onScreen(Finder finder) {
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(profile.inset.left - .5));
        expect(
          rect.right,
          lessThanOrEqualTo(profile.size.width - profile.inset.right + .5),
        );
        expect(rect.top, greaterThanOrEqualTo(profile.inset.top - .5));
        expect(
          rect.bottom,
          lessThanOrEqualTo(profile.size.height - profile.inset.bottom + .5),
        );
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: NovelApp(
            state: library,
            repository: const DemoNovelRepository(),
            listening: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      onScreen(find.byKey(const ValueKey('dock-tab-0')));
      await snapshot('discovery');
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
      );
      await tester.pumpAndSettle();
      await snapshot('shelf');
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-2'))),
      );
      await tester.pumpAndSettle();
      await snapshot('settings');
      await tester.tap(find.text('跟随系统'));
      await tester.pumpAndSettle();
      onScreen(find.byType(GlassOverlaySurface));
      await snapshot('menu');
      Navigator.of(tester.element(find.byType(GlassOverlaySurface))).pop();
      await tester.pumpAndSettle();

      Future<void> page(Widget child) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              key: UniqueKey(),
              debugShowCheckedModeBanner: false,
              theme: novelTheme(
                Brightness.light,
                fontFamily: library.appTypeface.family,
              ),
              builder: (context, child) => PerformanceScope(
                preferences: library.performance,
                child: ListeningScope(controller: controller, child: child!),
              ),
              home: child,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await tester.runAsync(
        () =>
            library.setPerformance(const PerformancePreferences(enabled: true)),
      );
      await page(LowPerformancePage(state: library));
      await snapshot('performance');
      final reset = find.byKey(const ValueKey('performance-light-preset'));
      await tester.scrollUntilVisible(
        reset,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('performance-options-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      onScreen(reset);
      await tester.runAsync(
        () => library.setPerformance(const PerformancePreferences()),
      );

      final novel = demoNovels.first.withChapters([
        NovelChapter(
          '适配测试章节',
          List.generate(
            24,
            (i) => '第 ${i + 1} 段。微光穿过书页，故事沿着月光继续。',
          ).join('\n\n'),
        ),
        const NovelChapter('下一章', '新的一章开始了。'),
      ]);
      await page(
        DetailPage(
          novel: novel,
          state: library,
          repository: const DemoNovelRepository(),
        ),
      );
      onScreen(find.byKey(const ValueKey('detail-read-button')));
      await snapshot('detail');
      await page(
        ReaderPage(
          novel: novel,
          state: library,
          repository: const DemoNovelRepository(),
          initialChapter: 0,
        ),
      );
      onScreen(find.byKey(const ValueKey('reader-listening-entry')));
      await snapshot('reader');
      await tester.tap(_button('阅读设置'));
      await tester.pumpAndSettle();
      onScreen(find.byType(GlassOverlaySurface));
      await snapshot('reader-settings');
      final font = find.byKey(const ValueKey('reader-font-slider'));
      await Scrollable.ensureVisible(tester.element(font), alignment: .5);
      await tester.pumpAndSettle();
      final fontControl = tester.widget<CupertinoSlider>(font);
      final bounds = tester.getRect(font);
      final fraction =
          (fontControl.value - fontControl.min) /
          (fontControl.max - fontControl.min);
      final gesture = await tester.startGesture(
        Offset(bounds.left + bounds.width * fraction, bounds.center.dy),
      );
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(36, 0));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isTrue,
      );
      expect(library.fontSize, greaterThan(19));
      expect(
        (await SharedPreferences.getInstance()).containsKey('readerFontSize'),
        isFalse,
      );
      await snapshot('typography-preview');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isFalse,
      );
      Navigator.of(tester.element(find.byType(GlassOverlaySurface))).pop();
      await tester.pumpAndSettle();

      final starting = controller.start(novel, chapter: 0);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await starting;
      await tester.tap(_button('听书'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('listening-position'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      onScreen(slider);
      output.positionEvents.add(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      final rect = tester.getRect(slider);
      final progress = tester.widget<CupertinoSlider>(slider).value;
      output.complete();
      await tester.runAsync(listeningMicrotasks);
      await tester.pumpAndSettle();
      expect(tester.getRect(slider), rect);
      expect(
        tester.widget<CupertinoSlider>(slider).value,
        closeTo(progress, .00001),
      );
      await snapshot('listening');
      final voices = find.text('音源与音色');
      await tester.ensureVisible(voices);
      await tester.pumpAndSettle();
      onScreen(voices);
      final checking = updates.check();
      await tester.pump();
      await checking;
      await page(AppUpdatePage(updates: updates));
      await snapshot('updates');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('download-app-update')),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('update-page-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('download-app-update'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      onScreen(find.byKey(const ValueKey('download-app-update')));
      await snapshot('update-download');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
