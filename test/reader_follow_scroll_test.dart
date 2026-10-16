import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_follow_scroll.dart';

void main() {
  late ScrollController scroll;
  late ReaderParagraphRegistry registry;
  late ReaderFollowScroll following;
  setUp(() {
    scroll = ScrollController(keepScrollOffset: false);
    registry = ReaderParagraphRegistry();
    following = ReaderFollowScroll(scroll);
  });
  tearDown(() {
    following.dispose();
    scroll.dispose();
  });
  Future<void> article(
    WidgetTester tester, {
    String? longParagraph,
    ValueChanged<ScrollStartNotification>? onStart,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 500,
              child: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  onStart?.call(notification);
                  return false;
                },
                child: ListView.builder(
                  controller: scroll,
                  cacheExtent: 100,
                  itemCount: 160,
                  itemBuilder: (context, index) => ReaderParagraph(
                    registry: registry,
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        longParagraph ??
                            '第 $index 段。${'夜色中的书页缓缓展开。' * (index.isEven ? 3 : 6)}',
                        key: ValueKey('row-$index'),
                        style: const TextStyle(fontSize: 20, height: 1.6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(
    int paragraph, {
    bool reduced = false,
    int start = 0,
    int end = 20,
  }) => following.reveal(
    allowed: () => true,
    reduceMotion: reduced,
    target: () => registry.speechTarget(
      paragraph,
      start,
      end,
      48,
      viewportBottom: 440,
      trailingSpace: 12,
    ),
  );
  test('scroll cadence uses distance, not the 120ms button contact', () {
    expect(
      ReaderFollowScroll.durationFor(80, 500).inMilliseconds,
      greaterThanOrEqualTo(380),
    );
    expect(ReaderFollowScroll.durationFor(10000, 500).inMilliseconds, 660);
    expect(ReaderFollowScroll.durationFor(4, 500).inMilliseconds, 180);
    expect(
      ReaderFollowScroll.durationFor(-80, 500),
      ReaderFollowScroll.durationFor(80, 500),
    );
  });
  testWidgets(
    'missing layout waits are bounded and leave no perpetual frame loop',
    (tester) async {
      await article(tester);
      var tries = 0;
      final landing = following.reveal(
        allowed: () => true,
        reduceMotion: false,
        target: () {
          tries++;
          return null;
        },
      );
      await tester.pumpAndSettle();
      await landing;
      expect(tries, 12);
      expect(tester.binding.hasScheduledFrame, false);
      expect(scroll.offset, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a lazy offscreen paragraph approaches smoothly before exact refinement',
    (tester) async {
      await article(tester);
      expect(
        registry.speechTarget(35, 0, 20, 48, viewportBottom: 440)!.exact,
        false,
      );
      final landing = reveal(35);
      await tester.pump();
      expect(scroll.offset, 0);
      await tester.pump(const Duration(milliseconds: 120));
      final intermediate = scroll.offset;
      expect(intermediate, greaterThan(0));
      await tester.pumpAndSettle();
      await landing;
      final exact = registry.speechTarget(
        35,
        0,
        20,
        48,
        viewportBottom: 440,
        trailingSpace: 12,
      )!;
      expect(exact.exact, true);
      expect(scroll.offset, closeTo(exact.offset, 1));
      expect(intermediate, lessThan(scroll.offset * .8));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'cancel stops an owned animation without changing its current pixel position',
    (tester) async {
      await article(tester);
      final landing = reveal(20);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      final before = scroll.offset;
      following.cancel();
      await tester.pump(const Duration(seconds: 1));
      await landing;
      expect(scroll.offset, closeTo(before, .1));
      expect(scroll.position.isScrollingNotifier.value, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a touch hold does not get chased by another automatic refinement',
    (tester) async {
      await article(tester);
      final landing = reveal(20);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      final before = scroll.offset;
      final hold = scroll.position.hold(() {});
      await tester.pumpAndSettle();
      await landing;
      expect(scroll.offset, closeTo(before, .1));
      hold.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a manual drag cancels following but remains scrollable and keeps its inertia',
    (tester) async {
      var dragging = false;
      await article(
        tester,
        onStart: (notification) {
          if (notification.dragDetails != null) {
            dragging = true;
            following.cancel(userDrag: true);
          }
        },
      );
      final landing = reveal(20);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final before = scroll.offset;
      await tester.fling(find.byType(ListView), const Offset(0, -150), 1000);
      await tester.pump(const Duration(milliseconds: 80));
      expect(dragging, true);
      expect(scroll.offset, greaterThan(before));
      final released = scroll.offset;
      await tester.pump(const Duration(milliseconds: 80));
      expect(scroll.offset, greaterThan(released));
      await tester.pumpAndSettle();
      await landing;
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('a newer request wins over a still-running old landing', (
    tester,
  ) async {
    await article(tester);
    final old = reveal(30);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final latest = reveal(7);
    await tester.pumpAndSettle();
    await Future.wait([old, latest]);
    final exact = registry.speechTarget(
      7,
      0,
      20,
      48,
      viewportBottom: 440,
      trailingSpace: 12,
    )!;
    expect(exact.exact, true);
    expect(scroll.offset, closeTo(exact.offset, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'reduced motion still reaches an exact lazy anchor with no driven animation',
    (tester) async {
      await article(tester);
      final landing = reveal(30, reduced: true);
      await tester.pumpAndSettle();
      await landing;
      final exact = registry.speechTarget(
        30,
        0,
        20,
        48,
        viewportBottom: 440,
        trailingSpace: 12,
      )!;
      expect(exact.exact, true);
      expect(scroll.offset, closeTo(exact.offset, 1));
      expect(scroll.position.isScrollingNotifier.value, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'long paragraphs reveal the spoken range and oversized ranges align their start',
    (tester) async {
      final text = '温柔的光落在书页上。' * 120;
      await article(tester, longParagraph: text);
      final first = registry.speechTarget(0, 0, 100, 48, viewportBottom: 440)!;
      final later = registry.speechTarget(
        0,
        360,
        440,
        48,
        viewportBottom: 440,
      )!;
      expect(later.offset, greaterThan(first.offset + 300));
      final landing = reveal(0, start: 360, end: 440);
      await tester.pumpAndSettle();
      await landing;
      final exact = registry.speechTarget(
        0,
        360,
        440,
        48,
        viewportBottom: 440,
      )!;
      expect(scroll.offset, closeTo(exact.offset, 1));
      final oversized = registry.speechTarget(
        0,
        360,
        text.length,
        48,
        viewportBottom: 440,
      )!;
      expect(
        oversized.offset,
        closeTo(registry.matchOffset(0, 360, text.length, 48)!, 1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
