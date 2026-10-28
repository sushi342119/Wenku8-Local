import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/archive_random_pick_card.dart';

class _FixedRandom implements math.Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor();

  @override
  bool nextBool() => value < 0.5;
}

List<int> _sample(List<double> weights, {int draws = 30000}) {
  final random = math.Random(1729);
  final counts = List<int>.filled(weights.length, 0);
  for (var i = 0; i < draws; i++) {
    counts[sampleArchiveRandomPickIndex(weights, random)]++;
  }
  return counts;
}

Widget _app({
  List<String> books = const ['未抽过的书', '抽过的书'],
  double Function(String)? weightOf,
  ValueChanged<String>? onPicked,
  ValueChanged<String>? onOpenDetail,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        body: SingleChildScrollView(
          child: ArchiveRandomPickCard<String>(
            books: books,
            titleOf: (book) => book,
            authorOf: (_) => '作者',
            weightOf: weightOf,
            onPicked: onPicked,
            onOpenDetail: onOpenDetail ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('weighted distribution is 16:4:1 and repeats remain possible', () {
    final counts = _sample([1, 0.25, 0.0625]);
    expect(counts[0] / 30000, closeTo(16 / 21, 0.01));
    expect(counts[1] / 30000, closeTo(4 / 21, 0.01));
    expect(counts[2] / 30000, closeTo(1 / 21, 0.01));
    expect(counts[1], lessThan(counts[0] / 3));
    expect(counts[2], greaterThan(0));
  });

  test('zero weights never participate, including interval boundaries', () {
    final counts = _sample([0, 0.25, 0, 1, 0]);
    expect([counts[0], counts[2], counts[4]], [0, 0, 0]);
    expect(counts[1] / 30000, closeTo(0.2, 0.01));
    expect(sampleArchiveRandomPickIndex([0, 1, 0], _FixedRandom(0)), 1);
    expect(sampleArchiveRandomPickIndex([1, 0, 1, 0], _FixedRandom(0.5)), 2);
  });

  test('all zero weights fall back to a uniform draw', () {
    for (final count in _sample([0, 0, 0])) {
      expect(count / 30000, closeTo(1 / 3, 0.01));
    }
  });

  test('equal positive weights restore a uniform distribution', () {
    for (final count in _sample([1, 1, 1])) {
      expect(count / 30000, closeTo(1 / 3, 0.01));
    }
  });

  test(
    'invalid weights are ignored and overflowing sums stay proportional',
    () {
      expect(_sample([double.nan, -1, double.infinity, 1]), [0, 0, 0, 30000]);
      final counts = _sample([double.maxFinite, double.maxFinite, 0]);
      expect(counts[0] / 30000, closeTo(0.5, 0.01));
      expect(counts[2], 0);
    },
  );

  test('equal subnormal weights remain uniform', () {
    final counts = _sample([double.minPositive, double.minPositive]);
    for (final count in counts) {
      expect(count / 30000, closeTo(0.5, 0.01));
    }
  });

  testWidgets('weighted pick keeps the 2400ms shuffle and records only once', (
    tester,
  ) async {
    final picks = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        weightOf: (book) => book == '抽过的书' ? 1 : 0,
        onPicked: picks.add,
        onOpenDetail: opened.add,
      ),
    );
    await tester.tap(find.text('抽阅一本'));
    await tester.pump();
    expect(picks, ['抽过的书']);
    expect(opened, isEmpty);
    expect(find.text('抽过的书'), findsNothing);
    expect(find.text('待抽阅'), findsNWidgets(3));
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );

    await tester.tap(find.text('抽阅中…'));
    await tester.pump(const Duration(milliseconds: 1020));
    expect(find.text('抽过的书'), findsNothing);
    expect(find.text('待抽阅'), findsNWidgets(3));
    await tester.pump(const Duration(milliseconds: 1379));
    expect(find.text('查看详情'), findsNothing);
    expect(find.text('抽阅中…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    // AnimationController 在超过时长的首帧派发 completed 状态。
    await tester.pump(const Duration(microseconds: 1));
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('抽过的书'), findsOneWidget);
    expect(picks, ['抽过的书']);
    await tester.tap(find.text('查看详情'));
    expect(opened, ['抽过的书']);
    expect(picks, ['抽过的书']);
  });

  testWidgets('reduced motion immediately shows the weighted result', (
    tester,
  ) async {
    final picks = <String>[];
    await tester.pumpWidget(
      _app(
        reduceMotion: true,
        weightOf: (book) => book == '抽过的书' ? 1 : 0,
        onPicked: picks.add,
      ),
    );
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(find.text('抽阅中…'), findsNothing);
      expect(find.text('抽过的书'), findsOneWidget);
    }
    expect(picks, ['抽过的书', '抽过的书']);
  });

  testWidgets('default weights and all zero weights still produce results', (
    tester,
  ) async {
    for (final weightOf in <double Function(String)?>[null, (_) => 0]) {
      final picks = <String>[];
      await tester.pumpWidget(
        _app(reduceMotion: true, weightOf: weightOf, onPicked: picks.add),
      );
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(picks, hasLength(1));
      expect(['未抽过的书', '抽过的书'], contains(picks.single));
      expect(find.text(picks.single), findsOneWidget);
      expect(find.text('查看详情'), findsOneWidget);
    }
  });

  testWidgets('a single candidate shows immediately and never shuffles', (
    tester,
  ) async {
    final picks = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        books: const ['唯一候选'],
        weightOf: (_) => 0,
        onPicked: picks.add,
        onOpenDetail: opened.add,
      ),
    );
    expect(find.text('唯一候选'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('待抽阅'), findsNothing);
    expect(picks, isEmpty);
    await tester.tap(find.text('再抽一本'));
    await tester.pump();
    expect(find.text('唯一候选'), findsOneWidget);
    expect(find.text('抽阅中…'), findsNothing);
    expect(picks, ['唯一候选']);
    await tester.tap(find.text('查看详情'));
    expect(opened, ['唯一候选']);
    expect(picks, ['唯一候选']);
  });

  testWidgets('empty candidates cannot be drawn', (tester) async {
    await tester.pumpWidget(_app(books: const []));
    expect(find.byType(ElevatedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
