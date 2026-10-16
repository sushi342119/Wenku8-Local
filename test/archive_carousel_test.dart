import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/catalog.dart';

List<Novel> _books(int count) => [
  for (var i = 0; i < count; i++)
    Novel(
      id: 930000 + i,
      title: '档案书籍 $i',
      author: '档案作者',
      genre: '轻小说',
      summary: '中心自动抽出的连续档案波列。',
      colors: const [Colors.black, Colors.grey],
    ),
];
int _slot(WidgetTester tester, int lane) =>
    _scene(tester).debugCentreSlot + lane - _scene(tester).debugFocus.round();
Finder _spine(WidgetTester tester, int i) =>
    find.byKey(ValueKey('archive-spine-${_slot(tester, i)}'));
Finder _cover(WidgetTester tester, int i) =>
    find.byKey(ValueKey('archive-cover-${_slot(tester, i)}'));
ArchiveBoxDepthRender _box(WidgetTester tester, int i) =>
    tester.renderObject<ArchiveBoxDepthRender>(
      find.byKey(ValueKey('archive-slot-${_slot(tester, i)}')),
    );
ArchiveShelfSceneRender _scene(WidgetTester tester) =>
    tester.renderObject<ArchiveShelfSceneRender>(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ShelfRow'),
    );
ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.byKey(const ValueKey('archive-file-carousel')))
    .position;
Future<void> _at(WidgetTester tester, double focus) async {
  final position = _position(tester);
  position.jumpTo(focus * _scene(tester).debugPitch);
  (position as ScrollPositionWithSingleContext).goIdle();
  await tester.pump();
}

Widget _app({
  int count = 20,
  GlobalKey? boundary,
  bool reduced = false,
  Brightness brightness = Brightness.light,
  double scale = 1,
  void Function(Novel, Object)? onOpen,
}) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: novelTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduced,
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Atmosphere(
        child: Center(
          child: SingleChildScrollView(
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
      ),
    ),
  ),
);
void _viewport(WidgetTester tester, {double width = 390}) {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main({Future<void> Function(WidgetTester, GlobalKey, String)? capture}) {
  testWidgets(
    'scroll position produces a continuous centered crest without relayout',
    (tester) async {
      _viewport(tester);
      final boundary = GlobalKey();
      await tester.pumpWidget(_app(boundary: boundary));
      await tester.pumpAndSettle();
      final scene = _scene(tester);
      expect(scene.debugFocus, 0);
      expect(find.text('01 / 20'), findsOneWidget);
      await _at(tester, 2);
      expect(scene.debugFocus, closeTo(2, .001));
      expect(find.text('03 / 20'), findsOneWidget);
      expect(_box(tester, 2).debugOpenFraction, 1);
      expect(
        _box(tester, 1).debugOpenFraction,
        closeTo(_box(tester, 3).debugOpenFraction, .0001),
      );
      expect(_box(tester, 1).debugOpenFraction, inExclusiveRange(0, 1));
      expect(_box(tester, 0).debugOpenFraction, 0);
      final crest = _box(tester, 2);
      final physical = MatrixUtils.transformRect(
        crest.getTransformTo(null),
        crest.semanticBounds,
      );
      final rail = tester.getRect(
        find.byKey(const ValueKey('archive-file-carousel')),
      );
      expect(physical.center.dx, closeTo(rail.center.dx, .1));
      final layouts = [
        for (var i = 0; i < 20; i++) _box(tester, i).debugLayoutCount,
      ];
      final sceneLayouts = scene.debugLayoutCount;
      final basis = crest.debugTransform.storage.take(12).toList();
      final spineSize = tester.getSize(_spine(tester, 2));
      final coverSize = tester.getSize(_cover(tester, 2));
      if (capture != null) await capture(tester, boundary, 'wave-ready');
      for (final value in [2.1, 2.25, 2.4, 2.5, 2.6, 2.75, 2.9, 3.0]) {
        await _at(tester, value);
        expect(scene.debugFocus, closeTo(value, .001));
        expect(crest.debugTransform.storage.take(12), basis);
        final rearTop = MatrixUtils.transformPoint(
          crest.debugSpineTransform
            ..translateByDouble(0, 0, coverSize.width, 1),
          Offset.zero,
        );
        final projected =
            MatrixUtils.transformRect(
                  crest.debugSpineTransform,
                  Offset.zero & spineSize,
                )
                .expandToInclude(
                  MatrixUtils.transformRect(
                    crest.debugTransform,
                    Offset.zero & coverSize,
                  ),
                )
                .expandToInclude(Rect.fromPoints(rearTop, rearTop));
        for (final (actual, expected) in [
          (crest.semanticBounds.left, projected.left),
          (crest.semanticBounds.top, projected.top),
          (crest.semanticBounds.right, projected.right),
          (crest.semanticBounds.bottom, projected.bottom),
        ]) {
          expect(actual, closeTo(expected, .0001));
        }
        expect(
          scene.debugPaintOrder,
          orderedEquals([...scene.debugPaintOrder]..sort()),
        );
        expect(scene.debugLayoutCount, sceneLayouts);
        for (var i = 0; i < 20; i++) {
          expect(_box(tester, i).debugLayoutCount, layouts[i]);
        }
        if (value == 2.5) {
          expect(
            _box(tester, 2).debugOpenFraction,
            closeTo(_box(tester, 3).debugOpenFraction, .0001),
          );
        }
        if (capture != null && [2.25, 2.5, 2.75, 3.0].contains(value)) {
          await capture(
            tester,
            boundary,
            'wave-${{2.25: 'quarter', 2.5: 'half', 2.75: 'three-quarter', 3.0: 'next'}[value]}',
          );
        }
      }
      expect(find.text('04 / 20'), findsOneWidget);
      expect(_box(tester, 3).debugOpenFraction, 1);
      if (capture != null) {
        await _at(tester, 10);
        await capture(tester, boundary, 'wave-middle-ready');
        await _at(tester, 10.5);
        await capture(tester, boundary, 'wave-middle-half');
      }
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'foreground solids occlude rear artwork and receive the same touch',
    (tester) async {
      _viewport(tester);
      final boundary = GlobalKey();
      int? opened;
      Object? openedTag;
      await tester.pumpWidget(
        _app(
          boundary: boundary,
          onOpen: (book, tag) {
            opened = book.id;
            openedTag = tag;
          },
        ),
      );
      await tester.pumpAndSettle();
      await _at(tester, 2);
      final foreground = tester.renderObject<RenderBox>(_spine(tester, 3));
      final point = foreground.localToGlobal(
        Offset(foreground.size.width / 2, 27),
      );
      final rearArt = tester.renderObject<RenderBox>(
        find.descendant(
          of: _cover(tester, 2),
          matching: find.byType(NovelCover),
        ),
      );
      final rearPoint = rearArt.globalToLocal(point);
      expect(
        (Offset.zero & rearArt.size).contains(rearPoint),
        isTrue,
        reason:
            'This must actually be an overlapping rear artwork / foreground spine point.',
      );
      for (final i in [2, 3]) {
        final surface = tester.widget<ContentPanel>(_spine(tester, i));
        expect(surface.backgroundColor!.a, 1);
        expect(
          tester.widget<ContentPanel>(_cover(tester, i)).backgroundColor!.a,
          1,
        );
      }
      if (capture != null) {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final local = render.globalToLocal(point);
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final offset = (local.dy.floor() * image.width + local.dx.floor()) * 4;
        expect(
          bytes!.getUint8(offset),
          greaterThan(220),
          reason: 'Opaque foreground milk must cover rear dark artwork.',
        );
        image.dispose();
        await capture(tester, boundary, 'wave-occlusion');
      }
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(opened, isNull);
      expect(find.text('04 / 20'), findsOneWidget);
      // Use the foremost narrow face, not an unoccluded AABB centre guess.
      final selected = tester.renderObject<RenderBox>(_spine(tester, 3));
      await tester.tapAt(
        selected.localToGlobal(Offset(selected.size.width / 2, 28)),
      );
      expect(opened, 930003);
      expect(
        tester
            .widget<Hero>(
              find.descendant(
                of: _cover(tester, 3),
                matching: find.byType(Hero),
              ),
            )
            .tag,
        openedTag,
      );
      opened = null;
      final selectedVolume = _box(tester, 3);
      final side = tester.renderObject<RenderBox>(_cover(tester, 3));
      final capCentre = MatrixUtils.transformPoint(
        selectedVolume.debugSpineTransform..translateByDouble(
          selected.size.width / 2,
          0,
          side.size.width / 2,
          1,
        ),
        Offset.zero,
      );
      await tester.tapAt(selectedVolume.localToGlobal(capCentre));
      expect(
        opened,
        930003,
        reason: 'The solid top cap must also accept taps.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets(
      'wave fits text $scale and reduced motion loops with exact per-book centering',
      (tester) async {
        _viewport(tester);
        await tester.pumpWidget(
          _app(
            count: 10,
            reduced: true,
            scale: scale,
            brightness: Brightness.dark,
          ),
        );
        await tester.pumpAndSettle();
        await _at(tester, 2);
        for (var i = 1; i >= 0; i--) {
          await tester.tap(find.byTooltip('上一份档案'));
          await tester.pumpAndSettle();
          expect(_scene(tester).debugFocus, closeTo(i.toDouble(), .001));
        }
        for (var i = 1; i < 10; i++) {
          await tester.tap(find.byTooltip('下一份档案'));
          await tester.pumpAndSettle();
          expect(
            find.text('${(i + 1).toString().padLeft(2, '0')} / 10'),
            findsOneWidget,
          );
          expect(_box(tester, i).debugOpenFraction, 1);
          final number = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: _spine(tester, i),
              matching: find.text((i + 1).toString().padLeft(2, '0')),
            ),
          );
          expect(number.didExceedMaxLines, isFalse);
        }
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '下一份档案',
                ),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byTooltip('下一份档案'));
        await tester.pumpAndSettle();
        expect(find.text('01 / 10'), findsOneWidget);
        expect(_scene(tester).debugFocus, closeTo(10, .001));
        await tester.pump(const Duration(seconds: 3));
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('twenty archives keep only three nearby cover widgets mounted', (
    tester,
  ) async {
    _viewport(tester);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(NovelCover), findsNWidgets(3));
    final height = tester
        .getSize(find.byKey(const ValueKey('archive-file-carousel')))
        .height;
    for (final i in [5.0, 10.0, 18.0, 19.0, 0.0]) {
      await _at(tester, i);
      await tester.pumpAndSettle();
      expect(find.byType(NovelCover).evaluate().length, lessThanOrEqualTo(3));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('archive-file-carousel')))
            .height,
        height,
      );
      expect(_box(tester, i.toInt()).debugOpenFraction, 1);
    }
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty and single archive banks have no misleading paging', (
    tester,
  ) async {
    for (final count in [0, 1]) {
      await tester.pumpWidget(_app(count: count));
      await tester.pumpAndSettle();
      expect(find.byTooltip('下一份档案'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
