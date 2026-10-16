import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Future<LibraryState> _mount(
  WidgetTester tester, {
  NavigatorObserver? observer,
  NovelRepository repository = const DemoNovelRepository(),
  bool reduced = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = await LibraryState.load();
  await state.setReduceMotion(reduced);
  await tester.pumpWidget(
    MaterialApp(
      theme: novelTheme(Brightness.light),
      scrollBehavior: const NovelScrollBehavior(),
      navigatorObservers: [?observer],
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: HomeShell(state: state, repository: repository),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Finder get _search => find.byWidgetPredicate(
  (widget) => widget is GlassIconButton && widget.label == '搜索',
);
Finder get _input => find.byKey(const ValueKey('expanded-search-input'));
Finder get _searchTap =>
    find.descendant(of: _search, matching: find.byType(InkWell)).first;

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(_searchTap);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search grows from its own control without pushing a route', (
    tester,
  ) async {
    final observer = _Routes();
    await _mount(tester, observer: observer);
    final home = tester.element(find.byType(HomeShell));
    final header = tester.element(find.byType(FrostedHeader));
    final origin = tester.getRect(_search);
    final route = ModalRoute.of(home);
    final pushes = observer.pushed.length;
    await tester.tap(_searchTap);
    await tester.pump();
    final bar = find.byKey(const ValueKey('expanded-search-bar'));
    expect(tester.getRect(bar), origin);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(bar).width, greaterThan(origin.width));
    final squish = tester.widget<Transform>(
      find.byKey(const ValueKey('search-jelly-transform')),
    );
    expect(squish.transform.entry(0, 0), isNot(1));
    expect(squish.transform.entry(1, 1), isNot(1));
    await tester.pumpAndSettle();
    expect(identical(tester.element(find.byType(HomeShell)), home), isTrue);
    expect(
      identical(tester.element(find.byType(FrostedHeader)), header),
      isTrue,
    );
    expect(ModalRoute.of(tester.element(_input)), same(route));
    expect(observer.pushed.length, pushes);
    expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
    final complete = tester.getRect(bar);
    expect(complete.left, 24);
    expect(complete.right, origin.right);
    expect(complete.height, 46);
    final settled = tester.widget<Transform>(
      find.byKey(const ValueKey('search-jelly-transform')),
    );
    expect(settled.transform, Matrix4.identity());
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing search restores the discovery viewport and control', (
    tester,
  ) async {
    await _mount(tester);
    final list = find.byKey(const PageStorageKey('discover'));
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    final offset = scroll.position.pixels;
    final origin = tester.getRect(_search);
    await _expand(tester);
    await tester.tap(find.byKey(const ValueKey('inline-search-close')));
    await tester.pumpAndSettle();
    expect(_input, findsNothing);
    expect(scroll.position.pixels, closeTo(offset, .01));
    expect(tester.getRect(_search), origin);
    expect(find.byType(FrostedHeader), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back collapses search instead of leaving home', (
    tester,
  ) async {
    await _mount(tester);
    await _expand(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_input, findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(_search, findsOneWidget);
  });

  testWidgets('search results keep their cover flight and query on return', (
    tester,
  ) async {
    final observer = _Routes();
    await _mount(tester, observer: observer);
    await _expand(tester);
    final query = demoNovels[1].title;
    await tester.enterText(_input, query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('找到 1 个结果'), findsOneWidget);
    final result = find.descendant(
      of: find.byType(InlineSearchResults),
      matching: find.text(query),
    );
    final pushes = observer.pushed.length;
    await tester.tap(result.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.byKey(ValueKey('cover-flight-${demoNovels[1].id}')),
      findsOneWidget,
    );
    expect(observer.pushed.length, pushes + 1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is GlassIconButton && widget.label == '返回',
            ),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, query);
    expect(find.text('找到 1 个结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion expands and closes without a jelly transform', (
    tester,
  ) async {
    await _mount(tester, reduced: true);
    await tester.tap(_searchTap);
    await tester.pump();
    await tester.pump();
    final transform = tester.widget<Transform>(
      find.byKey(const ValueKey('search-jelly-transform')),
    );
    expect(transform.transform, Matrix4.identity());
    expect(
      tester.getSize(find.byKey(const ValueKey('expanded-search-bar'))).width,
      752,
    );
    await tester.tap(find.byKey(const ValueKey('inline-search-close')));
    await tester.pump();
    expect(_input, findsNothing);
  });

  testWidgets(
    'pending search uses matching skeletons and discards stale data',
    (tester) async {
      final repository = _PendingSearch();
      await _mount(tester, repository: repository);
      await tester.tap(_searchTap);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SearchSkeleton), findsOneWidget);
      expect(find.byType(LoadingSkeleton), findsOneWidget);
      await tester.enterText(_input, 'first');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(_input, 'second');
      await tester.pump(const Duration(milliseconds: 300));
      repository.requests['first']!.complete([demoNovels.first]);
      await tester.pump();
      expect(find.byType(SearchSkeleton), findsOneWidget);
      repository.requests['second']!.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(SearchSkeleton), findsNothing);
      expect(find.text('没有找到相关故事'), findsOneWidget);
      repository.requests['']!.complete([]);
      await tester.pump();
      expect(find.text('没有找到相关故事'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inline-search-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('failed search retries in place and removes the stale error', (
    tester,
  ) async {
    final repository = _PendingSearch();
    await _mount(tester, repository: repository);
    await tester.tap(_searchTap);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    repository.requests['']!.completeError(StateError('fixture failure'));
    await tester.pumpAndSettle();
    expect(find.text('搜索失败，请稍后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.byType(SearchSkeleton), findsOneWidget);
    expect(find.text('搜索失败，请稍后重试'), findsNothing);
    repository.requests['']!.complete(demoNovels);
    await tester.pumpAndSettle();
    expect(find.text('你可能会喜欢'), findsOneWidget);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(_input, findsOneWidget);
  });
}

class _PendingSearch extends DemoNovelRepository {
  final requests = <String, Completer<List<Novel>>>{};
  @override
  Future<List<Novel>> search(String query) {
    final request = Completer<List<Novel>>();
    requests[query] = request;
    return request.future;
  }
}
