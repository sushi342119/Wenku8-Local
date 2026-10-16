import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_shelf.dart';
import 'package:wenku8_flutter/catalog.dart';

List<Novel> _books(int count) => [
  for (var i = 0; i < count; i++)
    Novel(
      id: 940000 + i,
      title: '书架档案 $i',
      author: '作者',
      genre: '轻小说',
      summary: '',
      colors: const [Colors.black, Colors.grey],
    ),
];
Widget _app({
  int count = 20,
  bool reduced = false,
  void Function(Novel, Object)? onOpen,
}) => MaterialApp(
  theme: novelTheme(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ArchiveFileCarousel(
          books: _books(count),
          reduceMotion: reduced,
          onOpen: onOpen ?? (_, _) {},
        ),
      ),
    ),
  ),
);
void _view(WidgetTester tester, {double width = 390}) {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder get _rail => find.byKey(const ValueKey('archive-file-carousel'));
ArchiveShelfSceneRender _scene(WidgetTester tester) =>
    tester.renderObject<ArchiveShelfSceneRender>(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ShelfRow'),
    );
ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(_rail).position;
Future<void> _at(WidgetTester tester, double focus) async {
  final position = _position(tester);
  position.jumpTo(focus * _scene(tester).debugPitch);
  (position as ScrollPositionWithSingleContext).goIdle();
  await tester.pump();
}

void main() {
  testWidgets(
    'the looping bank does not read or overwrite its parent feed PageStorage',
    (tester) async {
      _view(tester);
      final bucket = PageStorageBucket();
      final parentContext = GlobalKey();
      Widget page({required bool shelf}) => MaterialApp(
        home: Scaffold(
          body: PageStorage(
            bucket: bucket,
            child: SingleChildScrollView(
              key: const PageStorageKey('parent-feed'),
              child: Builder(
                key: parentContext,
                builder: (_) => shelf
                    ? ArchiveFileCarousel(books: _books(5), onOpen: (_, _) {})
                    : const SizedBox(height: 1200),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(shelf: false));
      bucket.writeState(parentContext.currentContext!, 3200.0);
      await tester.pumpWidget(page(shelf: true));
      await tester.pumpAndSettle();
      expect(_scene(tester).debugFocus, 0);
      await _at(tester, 1000);
      await tester.pumpWidget(page(shelf: false));
      await tester.pumpAndSettle();
      expect(bucket.readState(parentContext.currentContext!), 3200.0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a held gesture crosses repeated seams without resetting or growing the pool',
    (tester) async {
      _view(tester);
      await tester.pumpWidget(_app(count: 3));
      await tester.pumpAndSettle();
      final pool = _scene(tester).debugPoolCount;
      final pitch = _scene(tester).debugPitch;
      final gesture = await tester.startGesture(tester.getCenter(_rail));
      var previous = 0.0;
      for (var step = 1; step <= 45; step++) {
        await gesture.moveBy(
          Offset(-pitch, 0),
          timeStamp: Duration(milliseconds: step * 80),
        );
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          _scene(tester).debugFocus,
          step == 1 ? greaterThanOrEqualTo(previous) : greaterThan(previous),
        );
        previous = _scene(tester).debugFocus;
        expect(_position(tester).isScrollingNotifier.value, isTrue);
        expect(_scene(tester).debugPoolCount, pool);
        expect(find.byType(NovelCover), findsNWidgets(3));
        final tags = tester
            .widgetList<Hero>(find.byType(Hero))
            .map((hero) => hero.tag)
            .toList();
        expect(tags.toSet().length, tags.length);
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scene(tester).debugFocus, greaterThan(40));
      expect(
        _scene(tester).debugFocus,
        closeTo(_scene(tester).debugFocus.roundToDouble(), .001),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'both loop seams keep the same physical cover and foreground ordering',
    (tester) async {
      _view(tester);
      await tester.pumpWidget(_app(count: 10));
      await tester.pumpAndSettle();
      Rect face() => tester.getRect(
        find.descendant(
          of: find.byKey(
            ValueKey('archive-cover-${_scene(tester).debugCentreSlot}'),
          ),
          matching: find.byType(NovelCover),
        ),
      );
      for (final boundary in [-20.0, 0.0, 10.0, 10000.0]) {
        await _at(tester, boundary - .001);
        final before = face();
        final beforeBook = tester
            .widget<NovelCover>(
              find.descendant(
                of: find.byKey(
                  ValueKey('archive-cover-${_scene(tester).debugCentreSlot}'),
                ),
                matching: find.byType(NovelCover),
              ),
            )
            .novel
            .id;
        await _at(tester, boundary + .001);
        expect((face().center - before.center).distance, lessThan(.2));
        expect(face().size, before.size);
        expect(
          tester
              .widget<NovelCover>(
                find.descendant(
                  of: find.byKey(
                    ValueKey('archive-cover-${_scene(tester).debugCentreSlot}'),
                  ),
                  matching: find.byType(NovelCover),
                ),
              )
              .novel
              .id,
          beforeBook,
        );
        expect(
          _scene(tester).debugPaintOrder,
          orderedEquals([..._scene(tester).debugPaintOrder]..sort()),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'detents emit one light selection pulse per book and remain silent while idle',
    (tester) async {
      _view(tester);
      final pulses = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') pulses.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(_app(count: 5));
      await tester.pumpAndSettle();
      expect(pulses, isEmpty);
      for (var step = 0; step < 7; step++) {
        final before = pulses.length;
        await tester.tap(find.byTooltip('下一份档案'));
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
        expect(pulses.length - before, 1);
        expect(pulses.last.arguments, 'HapticFeedbackType.selectionClick');
      }
      final settled = pulses.length;
      await tester.pump(const Duration(seconds: 3));
      expect(pulses.length, settled);
      expect(find.text('03 / 05'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'width changes preserve fractional focus and the physical crest stays centered',
    (tester) async {
      _view(tester);
      int? opened;
      await tester.pumpWidget(_app(onOpen: (book, _) => opened = book.id));
      await tester.pumpAndSettle();
      await _at(tester, 7.25);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(_scene(tester).debugFocus, closeTo(7.25, .001));
      expect(find.text('08 / 20'), findsOneWidget);
      final caption = find.byKey(const ValueKey('archive-shelf-open'));
      await tester.ensureVisible(caption);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: caption, matching: find.byType(InkWell)),
      );
      expect(opened, 940007);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a real swipe automatically extracts its centered archive and settles to its lane',
    (tester) async {
      _view(tester, width: 260);
      int? opened;
      await tester.pumpWidget(_app(onOpen: (book, _) => opened = book.id));
      await tester.pumpAndSettle();
      await tester.timedDrag(
        _rail,
        const Offset(-170, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      final focus = _scene(tester).debugFocus;
      expect(focus, greaterThan(2));
      expect(focus, closeTo(focus.roundToDouble(), .005));
      expect(opened, isNull);
      final box = tester.renderObject<ArchiveBoxDepthRender>(
        find.byKey(ValueKey('archive-slot-${_scene(tester).debugCentreSlot}')),
      );
      expect(box.debugSelected, isTrue);
      expect(box.debugOpenFraction, closeTo(1, .0001));
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('archive-shelf-open')),
          matching: find.byType(InkWell),
        ),
      );
      expect(opened, 940000 + focus.round() % 20);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('rapid centering commands retain the last requested lane', (
    tester,
  ) async {
    _view(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('下一份档案'));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.byTooltip('上一份档案'));
    await tester.pumpAndSettle();
    expect(find.text('03 / 20'), findsOneWidget);
    expect(_scene(tester).debugFocus, closeTo(2, .001));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'appending and shrinking archive data preserve the logical lane',
    (tester) async {
      _view(tester);
      await tester.pumpWidget(_app(count: 10));
      await tester.pumpAndSettle();
      await _at(tester, 7);
      await tester.pumpWidget(_app(count: 20));
      await tester.pumpAndSettle();
      expect(find.text('08 / 20'), findsOneWidget);
      expect(_scene(tester).debugFocus, closeTo(7, .001));
      await _at(tester, 19);
      await tester.pumpWidget(_app(count: 2, reduced: true));
      await tester.pumpAndSettle();
      expect(find.text('02 / 02'), findsOneWidget);
      expect(_scene(tester).debugFocus, closeTo(19, .001));
      await tester.pumpWidget(_app(count: 0));
      await tester.pumpAndSettle();
      expect(_rail, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('dragging takes over an unfinished automatic centering command', (
    tester,
  ) async {
    _view(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一份档案'));
    await tester.pump(const Duration(milliseconds: 25));
    await tester.timedDrag(
      _rail,
      const Offset(-150, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();
    final focus = _scene(tester).debugFocus;
    expect(focus, greaterThan(3));
    await tester.pump(const Duration(seconds: 2));
    expect(_scene(tester).debugFocus, focus);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scrolling beyond either book-bank boundary keeps looping', (
    tester,
  ) async {
    _view(tester, width: 260);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    for (final focus in [0.0, 19.0]) {
      await _at(tester, focus);
      await tester.pumpAndSettle();
      final box = tester.renderObject<ArchiveBoxDepthRender>(
        find.byKey(ValueKey('archive-slot-${_scene(tester).debugCentreSlot}')),
      );
      expect(box.debugOpenFraction, 1);
      expect(_scene(tester).debugFocus, focus);
    }
    await tester.fling(_rail, const Offset(-500, 0), 1800);
    await tester.pumpAndSettle();
    expect(_scene(tester).debugFocus, greaterThan(19));
    expect(
      _scene(tester).debugFocus,
      closeTo(_scene(tester).debugFocus.roundToDouble(), .01),
    );
    expect(_position(tester).maxScrollExtent, double.infinity);
    expect(_position(tester).minScrollExtent, double.negativeInfinity);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a released fast flick keeps coasting and settles farther than a slow flick',
    (tester) async {
      _view(tester);
      await tester.pumpWidget(_app(count: 5));
      await tester.pumpAndSettle();
      final pool = _scene(tester).debugPoolCount;
      final landings = <double>[];
      for (final speed in [300.0, 1800.0]) {
        await _at(tester, 4);
        await tester.fling(_rail, const Offset(-90, 0), speed);
        await tester.pump();
        final released = _scene(tester).debugFocus;
        await tester.pump(const Duration(milliseconds: 120));
        expect(_scene(tester).debugFocus, greaterThan(released));
        await tester.pumpAndSettle(const Duration(milliseconds: 8));
        landings.add(_scene(tester).debugFocus - released);
        expect(
          _scene(tester).debugFocus,
          closeTo(_scene(tester).debugFocus.roundToDouble(), .00001),
        );
        expect(_scene(tester).debugPoolCount, pool);
        expect(find.byType(NovelCover), findsNWidgets(3));
      }
      expect(landings.last, greaterThan(landings.first * 3));
      expect(landings.last, greaterThan(3));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'regrabbing a coasting shelf stops it immediately and a new drag owns the lane',
    (tester) async {
      _view(tester);
      await tester.pumpWidget(_app(count: 5));
      await tester.pumpAndSettle();
      await tester.fling(_rail, const Offset(-100, 0), 1800);
      await tester.pump(const Duration(milliseconds: 100));
      final before = _scene(tester).debugFocus;
      final gesture = await tester.startGesture(tester.getCenter(_rail));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_scene(tester).debugFocus, closeTo(before, .00001));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_scene(tester).debugFocus, lessThan(before));
      await gesture.up();
      await tester.pumpAndSettle();
      final settled = _scene(tester).debugFocus;
      await tester.pump(const Duration(seconds: 2));
      expect(_scene(tester).debugFocus, settled);
      expect(settled, closeTo(settled.roundToDouble(), .00001));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
