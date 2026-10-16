import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';

void main() {
  Future<void> fixture(
    WidgetTester tester, {
    bool nested = false,
    double scale = 1,
    double keyboard = 0,
    bool sheet = false,
    bool bottom = false,
    int rows = 3,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget page(BuildContext context) => Scaffold(
      body: Stack(
        children: [
          Positioned(
            right: 24,
            top: bottom ? null : 72,
            bottom: bottom ? 30 : null,
            child: GlassMenuAnchor(
              child: Builder(
                builder: (context) => GestureDetector(
                  key: const ValueKey('popup-trigger'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (sheet) {
                      showJellySheet<void>(
                        context: context,
                        builder: (context) => const SizedBox(
                          height: 900,
                          child: Center(child: Text('抽屉内容')),
                        ),
                      );
                    } else {
                      showGlassMenu<int>(
                        context: context,
                        builder: (context) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var index = 0; index < rows; index++)
                              GlassMenuItem(
                                label: '条目 $index',
                                onPressed: () => Navigator.pop(context, index),
                              ),
                          ],
                        ),
                      );
                    }
                  },
                  child: const SizedBox(width: 46, height: 46),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 20),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 20),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: nested
            ? Stack(
                children: [
                  Positioned(
                    left: 24,
                    top: 80,
                    width: 352,
                    height: 620,
                    child: Transform.scale(
                      scale: scale,
                      alignment: Alignment.topLeft,
                      child: Navigator(
                        onGenerateRoute: (_) =>
                            MaterialPageRoute<void>(builder: page),
                      ),
                    ),
                  ),
                ],
              )
            : Builder(builder: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, .8]) {
    testWidgets(
      'inset Navigator menu uses one coordinate space at scale $scale',
      (tester) async {
        await fixture(tester, nested: true, scale: scale);
        final trigger = tester.getRect(
          find.byKey(const ValueKey('popup-trigger')),
        );
        await tester.tap(find.byKey(const ValueKey('popup-trigger')));
        await tester.pump();
        final initial = tester.getRect(find.byType(GlassOverlaySurface));
        expect(initial.left, closeTo(trigger.left, .001));
        expect(initial.top, closeTo(trigger.top, .001));
        expect(initial.size.width, closeTo(trigger.width, .001));
        expect(initial.size.height, closeTo(trigger.height, .001));
        await tester.pump(const Duration(milliseconds: 120));
        final middle = tester.getRect(find.byType(GlassOverlaySurface));
        expect(middle.right, closeTo(trigger.right, .001));
        expect(middle.top, closeTo(trigger.top, .001));
        await tester.pumpAndSettle();
        final finalRect = tester.getRect(find.byType(GlassOverlaySurface));
        expect(finalRect.right, closeTo(trigger.right, .001));
        expect(finalRect.top, closeTo(trigger.top, .001));
        expect(finalRect.width, closeTo(248 * scale, .001));
        await tester.tap(find.text('条目 1'));
        await tester.pumpAndSettle();
        expect(find.byType(GlassMenuSurface), findsNothing);
        expect(
          find.byKey(const ValueKey('popup-trigger')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final nested in [false, true]) {
    testWidgets('long menu fits window keyboard insets, nested $nested', (
      tester,
    ) async {
      await fixture(
        tester,
        nested: nested,
        bottom: true,
        keyboard: 260,
        rows: 16,
      );
      await tester.tap(find.byKey(const ValueKey('popup-trigger')));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(GlassOverlaySurface));
      expect(rect.bottom, lessThanOrEqualTo(528.001));
      expect(rect.top, greaterThanOrEqualTo(nested ? 92 : 36));
      final scroll = find.descendant(
        of: find.byType(GlassMenuSurface),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('条目 15'),
        180,
        scrollable: scroll,
      );
      await tester.tap(find.text('条目 15'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassMenuSurface), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'drawer fits same safe bounds without double keyboard inset, nested $nested',
      (tester) async {
        await fixture(tester, nested: nested, keyboard: 260, sheet: true);
        await tester.tap(find.byKey(const ValueKey('popup-trigger')));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byType(GlassOverlaySurface));
        expect(rect.bottom, closeTo(530, .001));
        expect(rect.top, greaterThanOrEqualTo(nested ? 92 : 36));
        expect(rect.width, closeTo(nested ? 328 : 376, .001));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
