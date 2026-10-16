import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/reader_content.dart';

void main() {
  for (final long in [false, true]) {
    testWidgets(
      'bookmark centres ${long ? 'the saved part of a long paragraph' : 'the actual text without its trailing gap'} without changing normal anchors',
      (tester) async {
        tester.view.physicalSize = const Size(390, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final registry = ReaderParagraphRegistry();
        final scroll = ScrollController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 100),
                    for (var i = 0; i < 12; i++)
                      ReaderParagraph(
                        registry: registry,
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SizedBox(
                            key: ValueKey('text-$i'),
                            height: long && i == 5 ? 900 : 100,
                            width: 300,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        const anchor = (index: 5, fraction: .73);
        final ordinary = registry.target(anchor, 80)!;
        expect(
          ordinary.offset,
          closeTo(100 + 5 * 112 + .73 * (long ? 912 : 112) - 80, .001),
        );
        final centred = registry.target(
          anchor,
          80,
          viewportBottom: 600,
          trailingSpace: 12,
        )!;
        expect(centred.exact, isTrue);
        scroll.jumpTo(centred.offset);
        await tester.pumpAndSettle();
        final text = tester.getRect(find.byKey(const ValueKey('text-5')));
        expect(
          long ? text.top + 912 * anchor.fraction : text.center.dy,
          closeTo(340, .001),
        );
        expect(registry.target(anchor, 80)!.offset, ordinary.offset);
        expect(registry.capture(1e9), isNull);
        expect(registry.capture(1e9, clampToLast: true), (
          index: 11,
          fraction: 1.0,
        ));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        scroll.dispose();
      },
    );
  }

  testWidgets(
    'an offscreen paragraph converges lazily to the centre in a bounded number of layouts',
    (tester) async {
      final registry = ReaderParagraphRegistry();
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: scroll,
              itemCount: 200,
              itemBuilder: (_, index) => ReaderParagraph(
                registry: registry,
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    key: ValueKey('lazy-$index'),
                    height: index.isEven ? 100 : 160,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      const anchor = (index: 180, fraction: .2);
      for (var step = 0; step < 10; step++) {
        final target = registry.target(
          anchor,
          80,
          viewportBottom: 500,
          trailingSpace: 12,
        )!;
        scroll.jumpTo(target.offset.clamp(0.0, double.infinity));
        await tester.pump();
        final refined = registry.target(
          anchor,
          80,
          viewportBottom: 500,
          trailingSpace: 12,
        )!;
        if (refined.exact && (scroll.offset - refined.offset).abs() < .5) break;
      }
      expect(
        registry
            .target(anchor, 80, viewportBottom: 500, trailingSpace: 12)!
            .exact,
        isTrue,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('lazy-180'))).center.dy,
        closeTo(290, .5),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    },
  );
}
