import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/main.dart';

void main() {
  testWidgets('发现页和空书架可以打开', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('轻小说文库'), findsOneWidget);
    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    expect(find.text('书架还空着'), findsOneWidget);
  });

  testWidgets('底部 Dock 可以拖拽吸附切换页面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    final first = tester.getCenter(find.byKey(const ValueKey('dock-tab-0')));
    final middle = tester.getCenter(find.byKey(const ValueKey('dock-tab-1')));
    await tester.dragFrom(first, middle - first);
    await tester.pumpAndSettle();
    expect(find.text('书架还空着'), findsOneWidget);

    await tester.dragFrom(middle, first - middle);
    await tester.pumpAndSettle();
    expect(find.text('轻小说文库'), findsOneWidget);
  });

  testWidgets('Dock 胶囊来回形变保持紧凑，不被两端裁切', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    final dock = find.byKey(const ValueKey('liquid-dock'));
    final dockRect = tester.getRect(dock);
    expect(find.byType(DockSelectionLens), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('发现')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(850, 0));
    await tester.pump();
    final stretched = tester.getRect(
      find.byKey(const ValueKey('dock-fluid-surface')),
    );
    expect(stretched.left, greaterThanOrEqualTo(dockRect.left - 12));
    expect(stretched.right, lessThanOrEqualTo(dockRect.right + 12));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面请求失败不会因页面重建而重复请求', (tester) async {
    const channel = MethodChannel('org.mewx.wenku8/legacy_api');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(LegacyCover.bytes(999991), throwsFormatException);
    await expectLater(LegacyCover.bytes(999991), throwsFormatException);
    expect(calls, 1);
  });

  testWidgets('外观选择弹层可弹出并切换黑白主题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(find.text('外观模式'), findsWidgets);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(state.theme, ThemeMode.dark);
  });

  test('书架与章节进度持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await state.toggleShelf(1);
    await state.setChapter(1, 2);

    final reloaded = await LibraryState.load();
    expect(reloaded.contains(1), isTrue);
    expect(reloaded.chapterFor(1), 2);
  });

  test('原版正文空白行被整理为可读段落', () async {
    final repository = LegacyWenkuRepository(
      request: (_) async => '  第一行  \r\n \n   \r\n 第二行\r\n',
    );
    final text = await repository.chapterContent(
      4189,
      const NovelChapter('第一章', '', id: 1),
    );
    expect(text, '第一行\n\n第二行');
  });

  testWidgets('精选书籍可进入详情与阅读器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(demoNovels.first.title).last);
    await tester.pumpAndSettle();
    expect(find.text('简介'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-read-button')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章'), findsOneWidget);

    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsNothing);
  });
}
