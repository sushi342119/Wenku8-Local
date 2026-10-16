import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';

void main() {
  testWidgets(
    'settings scroll retains its widget tree and does not change sliders',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-2'))),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const PageStorageKey('settings'));
      final original = tester.widget<ListView>(list);
      final values = (state.fontSize, state.glassBlur, state.glassOpacity);
      for (var i = 0; i < 8; i++) {
        await tester.drag(list, Offset(0, i.isEven ? -300 : 180));
        await tester.pumpAndSettle();
        expect(tester.widget<ListView>(list), same(original));
        expect((state.fontSize, state.glassBlur, state.glassOpacity), values);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
