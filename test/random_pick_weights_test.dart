import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/archive_random_pick_card.dart';
import 'package:wenku8_flutter/random_pick_weights.dart';

void main() {
  test('empty and duplicate candidate ids are safe', () {
    expect(buildRandomPickWeights([], {}), isEmpty);
    expect(buildRandomPickWeights([1, 1], {}, lastPickedId: 1), {1: 1});
  });

  test('exclude last pick and double the relative chance of unseen books', () {
    final weights = buildRandomPickWeights(
      [1, 2, 3],
      {1: 1, 3: 2},
      lastPickedId: 1,
    );
    expect(weights[1], 0);
    expect(weights[2]! / weights[3]!, 32);
    expect(buildRandomPickWeights([1, 2], {}, lastPickedId: 99), {1: 1, 2: 1});
  });

  test(
    'large counts preserve relative weights after excluding the minimum',
    () {
      final weights = buildRandomPickWeights(
        [1, 2, 3],
        {1: 1, 2: 10000, 3: 10001},
        lastPickedId: 1,
      );
      expect(weights[1], 0);
      expect(weights[2]! / weights[3]!, 4);
      final extreme = buildRandomPickWeights([1, 2], {1: 10000});
      expect(extreme.values.every((w) => w.isFinite && w > 0), isTrue);
    },
  );

  test('single candidate stays drawable regardless of count and last pick', () {
    final weights = buildRandomPickWeights([1], {1: 10000}, lastPickedId: 1);
    expect(
      sampleArchiveRandomPickIndex(weights.values.toList(), math.Random(0)),
      0,
    );
  });

  test('sequential sampling never repeats, but permits an A B A sequence', () {
    final random = math.Random(42);
    final counts = <int, int>{};
    final ids = [1, 2, 3];
    int? last;
    int? beforeLast;
    var returnedAfterOne = false;
    for (var i = 0; i < 1000; i++) {
      final weights = buildRandomPickWeights(ids, counts, lastPickedId: last);
      final picked =
          ids[sampleArchiveRandomPickIndex(
            ids.map((id) => weights[id]!).toList(),
            random,
          )];
      expect(picked, isNot(last));
      returnedAfterOne |= picked == beforeLast;
      counts[picked] = (counts[picked] ?? 0) + 1;
      beforeLast = last;
      last = picked;
    }
    expect(returnedAfterOne, isTrue);
  });
}
