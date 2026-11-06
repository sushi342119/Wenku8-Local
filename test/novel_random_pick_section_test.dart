import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shuyu/archive_random_pick_card.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/novel_random_pick_section.dart';
import 'package:shuyu/ui_preferences.dart';

const _countsKey = 'random_pick_draw_counts_v1';
const _lastKey = 'random_pick_last_id_v1';

Novel _book(int id) => Novel(
  id: id,
  title: '书籍 $id',
  author: '作者 $id',
  genre: '',
  summary: '',
  colors: const [Colors.brown, Colors.amber],
);

Widget _app({
  List<Novel>? books,
  bool reduceMotion = true,
  RandomPickPace pace = RandomPickPace.quick,
  TagMatchMode matchMode = TagMatchMode.any,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: SingleChildScrollView(
        child: NovelRandomPickSection(
          books: books ?? [_book(1), _book(2), _book(3)],
          onOpenDetail: (_) {},
          pace: pace,
          matchMode: matchMode,
        ),
      ),
    ),
  ),
);

ArchiveRandomPickCard<Novel> _card(WidgetTester tester) =>
    tester.widget<ArchiveRandomPickCard<Novel>>(
      find.byType(ArchiveRandomPickCard<Novel>),
    );

List<double> _weights(WidgetTester tester) {
  final card = _card(tester);
  return card.books.map(card.weightOf!).toList();
}

Future<Map<String, dynamic>> _storedCounts() async {
  final prefs = await SharedPreferences.getInstance();
  // Reload from the platform store instead of only asserting the Dart cache.
  await prefs.reload();
  return jsonDecode(prefs.getString(_countsKey) ?? '{}')
      as Map<String, dynamic>;
}

Future<int?> _storedLast() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs.getInt(_lastKey);
}

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences() : super.empty();

  Completer<void>? readGate;
  Completer<void>? writeGate;
  bool failWrite = false;
  bool failLastWrite = false;
  int writes = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    await readGate?.future;
    return super.getAll();
  }

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.$_lastKey' && failLastWrite) return false;
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.$_countsKey') {
      writes++;
      final gate = writeGate;
      writeGate = null;
      await gate?.future;
      if (failWrite) return false;
    }
    if (key == 'flutter.$_lastKey' && failLastWrite) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LibraryFilter.shared.resetForTesting();
    await TagStore.load();
  });

  testWidgets(
    'draws persist by id and restore after preferences are recreated',
    (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(_weights(tester), [1, 1, 1]);
      await tester.tap(find.text('抽阅一本'));
      await tester.pumpAndSettle();
      final counts = await _storedCounts();
      expect(counts, hasLength(1));
      final drawnId = int.parse(counts.keys.single);
      expect(counts['$drawnId'], 1);
      expect(_card(tester).weightOf!(_book(drawnId)), 0);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(await _storedCounts(), counts);

      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.resetStatic();
      await TagStore.load();
      await tester.pumpWidget(_app(books: [_book(3), _book(2), _book(1)]));
      await tester.pumpAndSettle();
      expect(_card(tester).weightOf!(_book(drawnId)), 0);
      expect(_card(tester).weightOf!(_book(100)), 0);
      expect(await _storedLast(), drawnId);
      expect(await _storedCounts(), counts);
    },
  );

  testWidgets(
    'single candidate remains drawable and counts every active pick',
    (tester) async {
      await tester.pumpWidget(_app(books: [_book(1)], reduceMotion: false));
      await tester.pumpAndSettle();
      expect(find.text('书籍 1'), findsOneWidget);
      expect(find.text('查看详情'), findsOneWidget);
      expect(await _storedCounts(), isEmpty);
      for (var count = 1; count <= 3; count++) {
        await tester.tap(find.text('再抽一本'));
        await tester.pump();
        expect(find.text('抽阅中…'), findsNothing);
        expect(_weights(tester).single, greaterThan(0));
        expect(await _storedLast(), 1);
        expect(find.text(count == 1 ? '第一次抽到' : '又遇见这本书'), findsOneWidget);
        expect(await _storedCounts(), {'1': count});
      }
    },
  );

  testWidgets('restored weights have the expected sampling distribution', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_countsKey, jsonEncode({'2': 1, '3': 2}));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final weights = _weights(tester);
    expect(weights, [1, 0.125, 0.03125]);
    final random = math.Random(42);
    final counts = [0, 0, 0];
    for (var i = 0; i < 30000; i++) {
      counts[sampleArchiveRandomPickIndex(weights, random)]++;
    }
    expect(counts[0] / 30000, closeTo(32 / 37, 0.01));
    expect(counts[1] / 30000, closeTo(4 / 37, 0.01));
    expect(counts[2] / 30000, closeTo(1 / 37, 0.01));
  });

  testWidgets('filter changes and replacement models keep weights by book id', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_countsKey, jsonEncode({'1': 2, '2': 1}));
    final tags = TagStore.shared;
    final tagA = await tags.createTag('科幻');
    final tagB = await tags.createTag('奇幻');
    await tags.setTagsForBook(1, [tagA]);
    await tags.setTagsForBook(2, [tagB]);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('科幻'));
    await tester.pumpAndSettle();
    expect(_card(tester).books.map((book) => book.id), [1]);
    expect(_weights(tester), [0.5]);
    expect(find.text('书籍 1'), findsOneWidget);
    await tester.ensureVisible(find.text('再抽一本'));
    await tester.tap(find.text('再抽一本'));
    await tester.pumpAndSettle();
    expect(_weights(tester), [0.5]);
    await tester.ensureVisible(find.text('全部'));
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('奇幻'));
    await tester.pumpAndSettle();
    expect(_weights(tester), [0.5]);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(books: [_book(3), _book(1), _book(2)]));
    await tester.pumpAndSettle();
    expect(_weights(tester), [1, 0, 0.125]);
    expect(await _storedCounts(), {'1': 3, '2': 1});
  });

  testWidgets('reset clears all ids, persists, and restores uniform sampling', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_countsKey, jsonEncode({'1': 2, '2': 1, '99': 6}));
    await prefs.setInt(_lastKey, 2);
    final tag = await TagStore.shared.createTag('筛选');
    await TagStore.shared.setTagsForBook(1, [tag]);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置抽取记录'));
    await tester.pumpAndSettle();
    expect(find.text('已重置抽取记录'), findsOneWidget);
    expect(await _storedCounts(), isEmpty);
    expect(await _storedLast(), isNull);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(_weights(tester), [1, 1, 1]);
    final random = math.Random(42);
    final counts = [0, 0, 0];
    final weights = _weights(tester);
    for (var i = 0; i < 30000; i++) {
      counts[sampleArchiveRandomPickIndex(weights, random)]++;
    }
    for (final count in counts) {
      expect(count / 30000, closeTo(1 / 3, 0.01));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    SharedPreferences.resetStatic();
    await TagStore.load();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(_weights(tester), [1, 1, 1]);
  });

  testWidgets(
    'deleted books and temporarily empty lists do not break records',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_countsKey, jsonEncode({'1': 2, '2': 1, '99': 6}));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(books: [_book(2), _book(3)]));
      await tester.pumpAndSettle();
      expect(_weights(tester), [0.125, 1]);
      await tester.pumpWidget(_app(books: []));
      await tester.pumpAndSettle();
      expect(find.text('书库暂无书籍'), findsOneWidget);
      expect(find.text('重置抽取记录'), findsOneWidget);
      await tester.pumpWidget(_app(books: [_book(2), _book(3)]));
      await tester.pumpAndSettle();
      expect(_weights(tester), [0.125, 1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('very high draw counts retain positive weights', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_countsKey, jsonEncode({'1': 10000, '2': 537}));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(_weights(tester).every((weight) => weight > 0), isTrue);
    expect(_weights(tester).every((weight) => weight.isFinite), isTrue);
    expect(_card(tester).weightOf!(_book(3)), 1);
  });

  for (final raw in <Object>['{broken', 7, '[]', '{"1":-3,"2":"4","3":1.5}']) {
    testWidgets(
      'invalid stored counts are retained without overwriting: $raw',
      (tester) async {
        SharedPreferences.setMockInitialValues({_countsKey: raw});
        await TagStore.load();
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();
        expect(_weights(tester), [1, 1, 1]);
        await tester.tap(find.text('抽阅一本'));
        await tester.pumpAndSettle();
        expect((await SharedPreferences.getInstance()).get(_countsKey), raw);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'first draw waits for restored counts without changing animation',
    (tester) async {
      final storage = _DelayedPreferences();
      await storage.setValue('String', 'flutter.$_countsKey', '{"1":2}');
      final gate = Completer<void>();
      storage.readGate = gate;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = storage;
      // Timings below follow the 2400ms 仪式 timeline (快速 900ms is default).
      await tester.pumpWidget(
        _app(reduceMotion: false, pace: RandomPickPace.ceremony),
      );
      expect(
        tester
            .widget<AbsorbPointer>(
              find
                  .descendant(
                    of: find.byType(NovelRandomPickSection),
                    matching: find.byType(AbsorbPointer),
                  )
                  .first,
            )
            .absorbing,
        isTrue,
      );
      await tester.tap(find.text('抽阅一本'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('抽阅中…'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(_weights(tester), [0.03125, 1, 1]);
      expect(
        tester
            .widget<AbsorbPointer>(
              find
                  .descendant(
                    of: find.byType(NovelRandomPickSection),
                    matching: find.byType(AbsorbPointer),
                  )
                  .first,
            )
            .absorbing,
        isFalse,
      );
      await tester.tap(find.text('抽阅一本'));
      await tester.pump();
      final counts = await _storedCounts();
      expect(
        counts.values.fold<int>(0, (sum, count) => sum + (count as int)),
        3,
      );
      await tester.pump(const Duration(milliseconds: 2399));
      expect(find.text('抽阅中…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      // AnimationController 在超过时长的首帧派发 completed 状态。
      await tester.pump(const Duration(microseconds: 1));
      expect(find.text('查看详情'), findsOneWidget);
      expect(await _storedCounts(), counts);
    },
  );

  testWidgets(
    'reset is written after in-flight draws and later draws survive',
    (tester) async {
      final storage = _DelayedPreferences();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = storage;
      await TagStore.load();
      await tester.pumpWidget(_app(books: [_book(1)]));
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      storage.writeGate = gate;
      await tester.tap(find.text('再抽一本'));
      await tester.pump();
      await tester.tap(find.text('再抽一本'));
      await tester.pump();
      await tester.tap(find.text('重置抽取记录'));
      await tester.pump();
      expect(_weights(tester), [1]);
      expect(storage.writes, 1);
      await tester.tap(find.text('再抽一本'));
      await tester.pump();
      expect(_weights(tester), [0.5]);
      gate.complete();
      await tester.pumpAndSettle();
      expect(storage.writes, 4);
      expect(await _storedCounts(), {'1': 1});
      expect(await _storedLast(), 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reset during a shuffle preserves its result and timing', (
    tester,
  ) async {
    // Timings below follow the 2400ms 仪式 timeline (快速 900ms is default).
    await tester.pumpWidget(
      _app(reduceMotion: false, pace: RandomPickPace.ceremony),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('抽阅一本'));
    await tester.pump();
    final counts = await _storedCounts();
    expect(counts, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1020));
    await tester.tap(find.text('重置抽取记录'));
    await tester.pump();
    expect(_weights(tester), [1, 1, 1]);
    expect(await _storedCounts(), isEmpty);
    expect(find.text('抽阅中…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1379));
    expect(find.text('查看详情'), findsNothing);
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('书籍 ${counts.keys.single}'), findsOneWidget);
    expect(await _storedCounts(), isEmpty);
  });

  testWidgets('failed reset persistence does not claim a saved reset', (
    tester,
  ) async {
    final storage = _DelayedPreferences();
    await storage.setValue('String', 'flutter.$_countsKey', '{"1":2}');
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = storage;
    await TagStore.load();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    storage.failWrite = true;
    await tester.tap(find.text('重置抽取记录'));
    await tester.pumpAndSettle();
    expect(_weights(tester), [1, 1, 1]);
    expect(find.text('已重置抽取记录，但保存失败'), findsOneWidget);
    expect(await _storedCounts(), {'1': 2});
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'two candidates alternate across repeated draws and model replacements',
    (tester) async {
      await tester.pumpWidget(_app(books: [_book(1), _book(2)]));
      await tester.pumpAndSettle();
      int? previous;
      for (var i = 0; i < 12; i++) {
        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();
        final picked = await _storedLast();
        expect(picked, isNot(previous));
        previous = picked;
        await tester.pumpWidget(_app(books: [_book(2), _book(1)]));
        await tester.pumpAndSettle();
      }
      expect(await _storedCounts(), {'1': 6, '2': 6});
    },
  );

  testWidgets(
    'duplicate ids are one candidate and automatic display is not a draw',
    (tester) async {
      await tester.pumpWidget(_app(books: [_book(1), _book(1)]));
      await tester.pumpAndSettle();
      expect(_card(tester).books, hasLength(1));
      expect(await _storedCounts(), isEmpty);
      expect(await _storedLast(), isNull);
      expect(find.text('第一次抽到'), findsNothing);
      await tester.tap(find.text('再抽一本'));
      await tester.pumpAndSettle();
      expect(await _storedCounts(), {'1': 1});
    },
  );

  testWidgets(
    'OR and AND filters keep the last pick across singleton and empty pools',
    (tester) async {
      final tags = TagStore.shared;
      final a = await tags.createTag('甲');
      final b = await tags.createTag('乙');
      await tags.setTagsForBook(1, [a]);
      await tags.setTagsForBook(2, [a, b]);
      LibraryFilter.shared.toggleTag(a);
      LibraryFilter.shared.toggleTag(b);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(_card(tester).books.map((book) => book.id), [1, 2]);
      await tester.pumpWidget(_app(matchMode: TagMatchMode.all));
      await tester.pumpAndSettle();
      expect(_card(tester).books.map((book) => book.id), [2]);
      expect(await _storedLast(), isNull);
      await tester.tap(find.text('再抽一本'));
      await tester.pumpAndSettle();
      expect(await _storedLast(), 2);
      await tester.pumpWidget(_app(books: [], matchMode: TagMatchMode.all));
      await tester.pumpAndSettle();
      expect(await _storedLast(), 2);
      LibraryFilter.shared.clear();
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(_card(tester).weightOf!(_book(2)), 0);
      expect(await _storedCounts(), {'2': 1});
    },
  );

  testWidgets(
    'invalid last id leaves counts usable and does not overwrite the bad value',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        _countsKey: '{"1":2}',
        _lastKey: 'bad',
      });
      await TagStore.load();
      await tester.pumpWidget(_app(books: [_book(1)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('再抽一本'));
      await tester.pumpAndSettle();
      expect(await _storedCounts(), {'1': 3});
      expect((await SharedPreferences.getInstance()).get(_lastKey), 'bad');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed last id save keeps counts and in-memory repeat protection',
    (tester) async {
      final storage = _DelayedPreferences()..failLastWrite = true;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = storage;
      await TagStore.load();
      await tester.pumpWidget(_app(books: [_book(1), _book(2)]));
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();
      }
      expect(await _storedCounts(), {'1': 1, '2': 1});
      expect(await _storedLast(), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('result label stays tied to the draw while a ceremony is reset', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(reduceMotion: false, pace: RandomPickPace.ceremony),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('抽阅一本'));
    await tester.pump();
    expect(find.text('第一次抽到'), findsNothing);
    await tester.tap(find.text('重置抽取记录'));
    await tester.pumpAndSettle();
    expect(find.text('第一次抽到'), findsOneWidget);
    expect(await _storedCounts(), isEmpty);
    expect(await _storedLast(), isNull);
  });
  testWidgets(
    'partial reset failure reports failure while retaining saved counts',
    (tester) async {
      final storage = _DelayedPreferences();
      await storage.setValue('String', 'flutter.$_countsKey', '{"1":2}');
      await storage.setValue('int', 'flutter.$_lastKey', 1);
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = storage;
      await TagStore.load();
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(_card(tester).weightOf!(_book(1)), 0);
      storage.failLastWrite = true;
      await tester.tap(find.text('重置抽取记录'));
      await tester.pumpAndSettle();
      expect(find.text('已重置抽取记录，但保存失败'), findsOneWidget);
      expect(await _storedCounts(), isEmpty);
      expect(await _storedLast(), 1);
      expect(_weights(tester), [1, 1, 1]);
    },
  );
}
