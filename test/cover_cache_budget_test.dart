import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legacy_cover.dart';

void main() {
  test(
    'cover cache deduplicates pending requests and keeps one stable future',
    () async {
      final held = Completer<Uint8List>();
      var calls = 0;
      final cache = LegacyCoverCache(
        request: (_) {
          calls++;
          return held.future;
        },
      );
      final first = cache.load(1);
      expect(identical(cache.load(1), first), isTrue);
      expect(cache.pendingRequests, 1);
      held.complete(Uint8List.fromList([1, 2, 3, 4]));
      final bytes = await first;
      expect(identical(cache.load(1), first), isTrue);
      expect(identical(cache.peek(1), bytes), isTrue);
      expect(cache.pendingRequests, 0);
      expect(calls, 1);
      expect(() => bytes[0] = 9, throwsUnsupportedError);
    },
  );

  test(
    'cover cache byte budget evicts least recently used encoded buffers',
    () async {
      final calls = <int>[];
      final cache = LegacyCoverCache(
        maxBytes: 8,
        request: (id) async {
          calls.add(id);
          return Uint8List(4);
        },
      );
      await cache.load(1);
      await cache.load(2);
      await cache.load(1);
      await cache.load(3);
      expect(cache.encodedBytes, 8);
      expect(cache.cachedEntries, 2);
      expect(cache.peek(2), isNull);
      await cache.load(2);
      expect(calls, [1, 2, 3, 2]);
      expect(cache.pendingRequests, 0);
    },
  );

  test(
    'many tiny covers stay bounded by entry count as well as bytes',
    () async {
      final cache = LegacyCoverCache(
        maxEntries: 3,
        request: (_) async => Uint8List(1),
      );
      for (var id = 1; id <= 500; id++) {
        await cache.load(id);
      }
      expect(cache.cachedEntries, 3);
      expect(cache.encodedBytes, 3);
      expect(cache.pendingRequests, 0);
      expect(cache.peek(1), isNull);
    },
  );

  test(
    'oversized covers render without being retained above the memory budget',
    () async {
      var calls = 0;
      final cache = LegacyCoverCache(
        maxBytes: 2,
        request: (_) async {
          calls++;
          return Uint8List(4);
        },
      );
      expect((await cache.load(1)).length, 4);
      expect(cache.encodedBytes, 0);
      expect(cache.cachedEntries, 0);
      expect(cache.pendingRequests, 0);
      await cache.load(1);
      expect(calls, 2);
    },
  );

  test(
    'failed requests back off, release pending storage, and retry after expiry',
    () async {
      var time = DateTime(2026);
      var calls = 0;
      final cache = LegacyCoverCache(
        now: () => time,
        request: (_) async {
          if (++calls == 1) throw StateError('offline');
          return Uint8List(4);
        },
      );
      final first = cache.load(1);
      await expectLater(first, throwsStateError);
      expect(cache.pendingRequests, 0);
      expect(identical(cache.load(1), first), isTrue);
      await expectLater(cache.load(1), throwsStateError);
      expect(calls, 1);
      time = time.add(const Duration(seconds: 31));
      await cache.load(1);
      expect(calls, 2);
      expect(cache.cachedFailures, 0);
    },
  );

  test('offline failed ID records have a fixed upper bound', () async {
    final cache = LegacyCoverCache(maxEntries: 3, request: (_) async => null);
    for (var id = 1; id <= 50; id++) {
      await expectLater(cache.load(id), throwsFormatException);
    }
    expect(cache.cachedFailures, 3);
    expect(cache.cachedEntries, 0);
    expect(cache.pendingRequests, 0);
  });

  test('explicit local seed wins over a delayed remote cover', () async {
    final held = Completer<Uint8List>();
    final cache = LegacyCoverCache(request: (_) => held.future);
    final older = cache.load(1);
    final local = Uint8List.fromList([1, 2]);
    cache.seed(1, local);
    local[0] = 9;
    held.complete(Uint8List.fromList([3, 4]));
    expect(await older, [3, 4]);
    expect(await cache.load(1), [1, 2]);
    expect(cache.encodedBytes, 2);
    expect(cache.pendingRequests, 0);
  });
}
