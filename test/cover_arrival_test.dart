import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/cover_arrival.dart';
import 'package:wenku8_flutter/legacy_cover.dart';

import 'support/cover_fixture.dart';

Widget _face(Uint8List bytes, {bool ready = true, bool record = true}) =>
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 118,
          height: 166,
          child: CoverArrival(
            bytes: bytes,
            ready: ready,
            recordArrival: record,
            placeholder: const ColoredBox(
              key: ValueKey('cover-skeleton-fixture'),
              color: Color(0xFFFDFCFA),
            ),
            child: const ColoredBox(
              key: ValueKey('decoded-cover-fixture'),
              color: Color(0xFF49666C),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('an offstage decoded frame waits without consuming the arrival', (
    tester,
  ) async {
    final bytes = Uint8List.fromList([8]);
    Widget stage(bool enabled) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: SizedBox(
          width: 118,
          height: 166,
          child: CoverArrival(
            bytes: bytes,
            ready: true,
            placeholder: const Text('offstage skeleton'),
            child: const Text('active face'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(stage(false));
    await tester.pumpAndSettle();
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(CoverArrival.wasPresented(bytes), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(stage(true));
    await tester.pump();
    expect(find.byType(ArchivePlaneTransition), findsOneWidget);
    await tester.pumpAndSettle();
    expect(CoverArrival.wasPresented(bytes), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a new route completes an in-flight face instead of doubling motion',
    (tester) async {
      final bytes = Uint8List.fromList([9]);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: SizedBox(
            width: 118,
            height: 166,
            child: CoverArrival(
              bytes: bytes,
              ready: true,
              placeholder: const Text('source skeleton'),
              child: const Text('source face'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(ArchivePlaneTransition), findsOneWidget);
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (context) => const Scaffold(body: Text('destination')),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(CoverArrival.wasPresented(bytes), isTrue);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('source face'), findsOneWidget);
      expect(find.byType(ArchivePlaneTransition), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('actual cached bytes wait for decode then reveal exactly once', (
    tester,
  ) async {
    final bytes = (await tester.runAsync(coverFixtureBytes))!;
    const id = 910001;
    LegacyCover.seedLocalBytes(id, bytes);
    final book = coverFixtureBook(id);
    Widget cover() => MaterialApp(
      theme: novelTheme(Brightness.light),
      home: Center(child: NovelCover(book)),
    );
    await tester.pumpWidget(cover());
    for (
      var i = 0;
      i < 30 && find.byType(ArchivePlaneTransition).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump();
    }
    expect(find.byType(ArchivePlaneTransition), findsOneWidget);
    final cached = LegacyCover.peek(id)!;
    expect(CoverArrival.wasPresented(cached), isFalse);
    await tester.pumpAndSettle();
    expect(CoverArrival.wasPresented(cached), isTrue);
    expect(find.byType(LoadingSkeleton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(cover());
    await tester.pumpAndSettle();
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a damaged image returns its static generated cover', (
    tester,
  ) async {
    const id = 910002;
    LegacyCover.seedLocalBytes(id, Uint8List.fromList([1, 2, 3]));
    await tester.pumpWidget(
      MaterialApp(home: Center(child: NovelCover(coverFixtureBook(id)))),
    );
    for (var i = 0; i < 20 && find.text('透明档案').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('透明档案'), findsOneWidget);
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover skeleton has no clock before a decoded frame', (
    tester,
  ) async {
    final bytes = Uint8List.fromList([1]);
    await tester.pumpWidget(_face(bytes, ready: false));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cover-skeleton-fixture')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('decoded-cover-fixture')), findsNothing);
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(CoverArrival.wasPresented(bytes), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'decoded cover cuts over its skeleton without new frame layouts',
    (tester) async {
      final bytes = Uint8List.fromList([2]);
      await tester.pumpWidget(_face(bytes, ready: false));
      await tester.pumpWidget(_face(bytes));
      await tester.pump();
      final plane = find.byType(ArchivePlaneTransition);
      expect(plane, findsOneWidget);
      final render = tester.renderObject<ArchivePlaneRender>(plane);
      final layouts = render.debugLayoutCount;
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(render.debugLayoutCount, layouts);
      }
      expect(
        find.byKey(const ValueKey('cover-skeleton-fixture')),
        findsOneWidget,
      );
      expect(find.byType(Opacity), findsNothing);
      expect(CoverArrival.wasPresented(bytes), isFalse);
      await tester.pumpAndSettle();
      expect(find.byType(ArchivePlaneTransition), findsNothing);
      expect(
        find.byKey(const ValueKey('cover-skeleton-fixture')),
        findsNothing,
      );
      expect(CoverArrival.wasPresented(bytes), isTrue);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_face(bytes));
      await tester.pumpAndSettle();
      expect(find.byType(ArchivePlaneTransition), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new bytes reveal once while a repeated cached frame stays still',
    (tester) async {
      final oldBytes = Uint8List.fromList([3]);
      final newBytes = Uint8List.fromList([4]);
      await tester.pumpWidget(_face(oldBytes));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_face(newBytes, ready: false));
      expect(find.byKey(const ValueKey('decoded-cover-fixture')), findsNothing);
      await tester.pumpWidget(_face(newBytes));
      await tester.pump();
      expect(find.byType(ArchivePlaneTransition), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.pumpWidget(_face(newBytes));
      expect(find.byType(ArchivePlaneTransition), findsNothing);
      expect(CoverArrival.wasPresented(oldBytes), isTrue);
      expect(CoverArrival.wasPresented(newBytes), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduce-motion and flight copies never add an arrival clock', (
    tester,
  ) async {
    final bytes = Uint8List.fromList([5]);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SizedBox(
            width: 118,
            height: 166,
            child: CoverArrival(
              bytes: bytes,
              ready: true,
              placeholder: const SizedBox.shrink(),
              child: const Text('decoded reduced cover'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('decoded reduced cover'), findsOneWidget);
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(CoverArrival.wasPresented(bytes), isTrue);
    final flightBytes = Uint8List.fromList([6]);
    await tester.pumpWidget(_face(flightBytes, record: false));
    await tester.pumpAndSettle();
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(CoverArrival.wasPresented(flightBytes), isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('cover waits for the route plane to land before revealing', (
    tester,
  ) async {
    final bytes = Uint8List.fromList([7]);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox.expand()),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 1000),
        pageBuilder: (context, animation, secondaryAnimation) => Center(
          child: SizedBox(
            width: 118,
            height: 166,
            child: CoverArrival(
              bytes: bytes,
              ready: true,
              placeholder: const Text('waiting cover'),
              child: const Text('landed cover'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('waiting cover'), findsOneWidget);
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    expect(CoverArrival.wasPresented(bytes), isFalse);
    await tester.pump(const Duration(milliseconds: 710));
    await tester.pump();
    expect(find.byType(ArchivePlaneTransition), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('landed cover'), findsOneWidget);
    expect(CoverArrival.wasPresented(bytes), isTrue);
    expect(tester.takeException(), isNull);
  });
}
