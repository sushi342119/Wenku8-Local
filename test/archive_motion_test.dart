import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';

void main() {
  testWidgets(
    'navigation landmark stays readable while its address assembles',
    (tester) async {
      final clock = AnimationController(
        vsync: tester,
        duration: NovelMotion.enter,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              child: ArchiveMotionScope(
                animation: clock,
                child: const ArchiveMasthead(
                  title: '书架',
                  code: '02 / PERSONAL ARCHIVE',
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        find.ancestor(
          of: find.text('书架'),
          matching: find.byType(ArchiveReveal),
        ),
        findsNothing,
      );
      expect(find.byType(ArchiveReveal), findsOneWidget);
      clock.value = .2;
      await tester.pump();
      expect(
        find.ancestor(
          of: find.text('书架'),
          matching: find.byType(ArchiveReveal),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      clock.dispose();
    },
  );

  testWidgets('archive reveal paints its retained child without build/layout', (
    tester,
  ) async {
    final clock = AnimationController(
      vsync: tester,
      duration: NovelMotion.reveal,
    );
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ArchiveReveal(
            key: const ValueKey('reveal'),
            animation: clock,
            child: Builder(
              builder: (context) {
                builds++;
                return const SizedBox(
                  width: 240,
                  height: 80,
                  child: Text('档案'),
                );
              },
            ),
          ),
        ),
      ),
    );
    final render = tester.renderObject<ArchiveRevealRender>(
      find.byKey(const ValueKey('reveal')),
    );
    final layouts = render.debugLayoutCount;
    final rect = tester.getRect(find.byKey(const ValueKey('reveal')));
    for (var i = 1; i <= 20; i++) {
      clock.value = i / 20;
      await tester.pump();
      expect(render.debugLayoutCount, layouts);
      expect(tester.getRect(find.byKey(const ValueKey('reveal'))), rect);
    }
    expect(builds, 1);
    expect(render.debugPaintCount, greaterThan(10));
    expect(render.progress, 1);
    expect(render.displacement, Offset.zero);
    expect(render.viewport, Offset.zero & render.size);
    expect(find.byType(Opacity), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    clock.dispose();
  });

  testWidgets('reveal hit testing follows the visible clip and translation', (
    tester,
  ) async {
    final clock = AnimationController(
      vsync: tester,
      duration: NovelMotion.reveal,
    );
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ArchiveReveal(
            animation: clock,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox(width: 220, height: 100),
            ),
          ),
        ),
      ),
    );
    final render = tester.renderObject<ArchiveRevealRender>(
      find.byType(ArchiveReveal),
    );
    final origin = tester.getTopLeft(find.byType(ArchiveReveal));
    await tester.tapAt(origin + const Offset(100, 50));
    expect(taps, 0);
    clock.value = .2;
    await tester.pump();
    await tester.tapAt(origin + const Offset(100, 99));
    expect(taps, 0);
    await tester.tapAt(origin + render.displacement + render.viewport.center);
    expect(taps, 1);
    clock.value = 1;
    await tester.pump();
    await tester.tapAt(origin + const Offset(100, 99));
    expect(taps, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    clock.dispose();
  });

  testWidgets('terminal rules open before codes and headings on one clock', (
    tester,
  ) async {
    final clock = AnimationController(
      vsync: tester,
      duration: NovelMotion.enter,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: ArchiveMotionScope(
              animation: clock,
              child: const ArchiveSection(title: '目录', code: '01 / CONTENTS'),
            ),
          ),
        ),
      ),
    );
    clock.value = .12;
    await tester.pump();
    final parts = find
        .byType(ArchiveReveal)
        .evaluate()
        .map((element) => element.renderObject! as ArchiveRevealRender)
        .toList();
    expect(parts, hasLength(3));
    expect(parts[1].progress, greaterThan(parts[0].progress)); // Rule first.
    expect(parts[0].progress, greaterThan(parts[2].progress)); // Heading last.
    clock.value = 1;
    await tester.pump();
    expect(parts.every((render) => render.progress == 1), isTrue);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    clock.dispose();
  });

  for (final direction in [-1.0, 1.0]) {
    testWidgets('archive plane $direction exchanges on a clipped diagonal', (
      tester,
    ) async {
      final clock = AnimationController(
        vsync: tester,
        duration: NovelMotion.enter,
      );
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 500,
              child: ArchivePlaneTransition(
                animation: clock,
                direction: direction,
                child: RepaintBoundary(
                  child: Builder(
                    builder: (context) {
                      builds++;
                      return const ColoredBox(color: Colors.white);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final render = tester.renderObject<ArchivePlaneRender>(
        find.byType(ArchivePlaneTransition),
      );
      final layouts = render.debugLayoutCount;
      clock.value = .25;
      await tester.pump();
      expect(render.displacement.dx.sign, -direction);
      expect(render.displacement.dy, greaterThan(0));
      final leading = direction > 0 ? 1.0 : 299.0;
      final trailing = direction > 0 ? 299.0 : 1.0;
      expect(render.viewport.contains(Offset(leading, 250)), isTrue);
      expect(render.viewport.contains(Offset(trailing, 250)), isFalse);
      final pose = render.displacement;
      clock.reverse();
      await tester.pump();
      expect(render.displacement, pose); // No closing-curve discontinuity.
      clock.stop();
      for (var i = 1; i <= 20; i++) {
        clock.value = i / 20;
        await tester.pump();
      }
      expect(render.debugLayoutCount, layouts);
      expect(builds, 1);
      expect(render.displacement, Offset.zero);
      expect(find.byType(Opacity), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      clock.dispose();
    });
  }

  testWidgets(
    'sheet comes from below as one full-sized glass/foreground plane',
    (tester) async {
      final clock = AnimationController(
        vsync: tester,
        duration: NovelMotion.enter,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 400,
              child: GlassOverlayTransition(
                animation: clock,
                kind: GlassOverlayKind.sheet,
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      final render = tester.renderObject<ArchivePlaneRender>(
        find.byType(ArchivePlaneTransition),
      );
      expect(render.displacement.dy, greaterThan(render.size.height));
      final layouts = render.debugLayoutCount;
      clock.value = .45;
      await tester.pump();
      final child = render.child!;
      final matrix = child.getTransformTo(render);
      expect(
        MatrixUtils.transformRect(matrix, Offset.zero & child.size).size,
        child.size,
      );
      expect(render.displacement.dx, lessThan(0));
      expect(render.displacement.dy, greaterThan(0));
      expect(find.byType(Opacity), findsNothing);
      clock.value = 1;
      await tester.pump();
      expect(render.displacement, Offset.zero);
      expect(render.debugLayoutCount, layouts);
      await tester.pumpWidget(const SizedBox.shrink());
      clock.dispose();
    },
  );

  testWidgets('reduced motion and completed archive parts add no animation', (
    tester,
  ) async {
    for (final reduced in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: ArchiveMotionScope(
              animation: AlwaysStoppedAnimation<double>(reduced ? .1 : 1),
              child: const ArchiveSection(title: '目录', code: '01 / CONTENTS'),
            ),
          ),
        ),
      );
      expect(find.byType(ArchiveReveal), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    }
  });
}
