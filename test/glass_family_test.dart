import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';

Future<LibraryState> _mount(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final state = await LibraryState.load();
  await tester.pumpWidget(
    NovelApp(state: state, repository: const DemoNovelRepository()),
  );
  await tester.pumpAndSettle();
  return state;
}

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

void main() {
  testWidgets('glass foreground stays crisp and ordinary content stays solid', (
    tester,
  ) async {
    final state = await _mount(tester);
    await state.setTheme(ThemeMode.dark);
    await tester.pumpAndSettle();
    final title = tester.renderObject<RenderParagraph>(find.text('轻小说文库'));
    expect(title.text.style!.shadows, isEmpty);
    final bookTitle = tester.renderObject<RenderParagraph>(
      find.text(demoNovels.first.title).last,
    );
    expect(bookTitle.text.style!.shadows, isNull);
  });

  testWidgets(
    'reduced-motion dropdown has no geometry animation or idle ticker',
    (tester) async {
      final state = await _mount(tester);
      await state.setReduceMotion(true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随系统'));
      await tester.pumpAndSettle();
      final route = ModalRoute.of(
        tester.element(find.byType(GlassMenuItem).first),
      )!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      expect(find.byKey(const ValueKey('glass-menu-transition')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(GlassMenuItem), findsNothing);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dock material, labels, icons and targets share the whole deformation',
    (tester) async {
      await _mount(tester);
      final plate = find.byKey(const ValueKey('dock-fluid-surface'));
      final tab = find.byKey(const ValueKey('dock-tab-0'));
      final icon = find.descendant(of: tab, matching: find.byType(Icon));
      final label = find.descendant(of: tab, matching: find.byType(Text));
      final initial = [
        tester.getRect(plate),
        tester.getRect(tab),
        tester.getRect(icon),
        tester.getRect(label),
      ];
      final gesture = await tester.startGesture(tester.getCenter(tab));
      await tester.pump();
      await tester.pump(NovelMotion.contact);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-2'))),
        timeStamp: const Duration(milliseconds: 220),
      );
      await tester.pump(const Duration(milliseconds: 20));
      final current = [
        tester.getRect(plate),
        tester.getRect(tab),
        tester.getRect(icon),
        tester.getRect(label),
      ];
      final sx = current.first.width / initial.first.width;
      final sy = current.first.height / initial.first.height;
      expect(sx, greaterThan(1));
      for (var index = 1; index < current.length; index++) {
        expect(current[index].width, closeTo(initial[index].width * sx, .001));
        expect(
          current[index].height,
          closeTo(initial[index].height * sy, .001),
        );
        expect(
          current[index].center.dx - current.first.center.dx,
          closeTo(
            (initial[index].center.dx - initial.first.center.dx) * sx,
            .001,
          ),
        );
        expect(
          current[index].center.dy - current.first.center.dy,
          closeTo(
            (initial[index].center.dy - initial.first.center.dy) * sy,
            .001,
          ),
        );
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      for (var index = 0; index < current.length; index++) {
        expect(
          tester.getRect([plate, tab, icon, label][index]),
          initial[index],
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass button press moves its glyph with its material and glow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: Center(
          child: GlassIconButton(
            icon: CupertinoIcons.back,
            label: '返回',
            onPressed: () {},
          ),
        ),
      ),
    );
    final plate = find.byType(NativeBackdrop);
    final icon = find.byType(Icon);
    final originalPlate = tester.getRect(plate);
    final originalIcon = tester.getRect(icon);
    final gesture = await tester.startGesture(tester.getCenter(icon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final scale = tester.getRect(plate).width / originalPlate.width;
    expect(scale, lessThan(1));
    expect(
      tester.getRect(icon).width,
      closeTo(originalIcon.width * scale, .001),
    );
    expect(tester.getRect(icon).center, tester.getRect(plate).center);
    expect(tester.widget<NativeBackdrop>(plate).emission, greaterThan(0));
    final foreground = tester.element(find.byType(Icon));
    expect(IconTheme.of(foreground).shadows, isNull);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(plate), originalPlate);
    expect(tester.takeException(), isNull);
  });

  testWidgets('whole-surface emission is disabled by high contrast', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: const MediaQuery(
          data: MediaQueryData(highContrast: true),
          child: Center(
            child: LiquidGlass(child: SizedBox(width: 196, height: 54)),
          ),
        ),
      ),
    );
    final material = tester.widget<NativeBackdrop>(find.byType(NativeBackdrop));
    expect(material.emission, 0);
    expect(material.thickness, 0);
    expect(material.tint.a, 1);
  });

  testWidgets(
    'theme dropdown is anchored glass with the shared overlay timeline',
    (tester) async {
      final state = await _mount(tester);
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await tester.pumpAndSettle();
      final trigger = find.text('跟随系统');
      final anchor = tester.getRect(
        find.ancestor(of: trigger, matching: find.byType(LiquidGlass)).first,
      );
      await tester.tap(trigger);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GlassOverlaySurface), findsOneWidget);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(find.byType(GlassMenuItem), findsNWidgets(3));
      final route = ModalRoute.of(
        tester.element(find.byType(GlassMenuItem).first),
      )!;
      expect(route.transitionDuration, NovelMotion.enter);
      expect(route.reverseTransitionDuration, NovelMotion.exit);
      final material = find.descendant(
        of: find.byType(GlassOverlaySurface),
        matching: find.byType(LiquidGlass),
      );
      expect(
        find.ancestor(
          of: material,
          matching: find.byKey(const ValueKey('glass-menu-transition')),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(GlassOverlaySurface));
      expect(rect.top, closeTo(anchor.top, .001));
      expect(rect.right, closeTo(anchor.right, .001));
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(state.theme, ThemeMode.dark);
      expect(find.byType(GlassOverlaySurface), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reading drawer is glass and dragging moves its content with its shell',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(demoNovels.first.title).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-read-button')));
      await tester.pumpAndSettle();
      await tester.tap(_control('阅读设置'));
      await tester.pumpAndSettle();
      final surface = find.byType(GlassOverlaySurface);
      final title = find.text('阅读设置');
      final initialPlate = tester.getRect(surface);
      final initialTitle = tester.getRect(title);
      final gesture = await tester.startGesture(
        Offset(initialPlate.center.dx, initialPlate.top + 10),
      );
      await gesture.moveBy(const Offset(0, 26));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 18));
      await tester.pump();
      final dy = tester.getRect(surface).top - initialPlate.top;
      expect(dy, greaterThan(0));
      expect(tester.getRect(title).top - initialTitle.top, closeTo(dy, .001));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.getRect(surface), initialPlate);
      final slider = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('reader-font-slider')),
      );
      slider.onChangeStart!(slider.value);
      slider.onChanged!(24);
      await tester.pumpAndSettle();
      expect(state.fontSize, 24);
      expect(tester.widget<GlassOverlaySurface>(surface).transparent, isTrue);
      expect(
        (await SharedPreferences.getInstance()).containsKey('readerFontSize'),
        isFalse,
      );
      slider.onChangeEnd!(24);
      await tester.pumpAndSettle();
      expect(state.fontSize, 24);
      expect(tester.widget<GlassOverlaySurface>(surface).transparent, isFalse);
      Navigator.of(tester.element(surface)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(GlassOverlaySurface), findsNothing);
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
