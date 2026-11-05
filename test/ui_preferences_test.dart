import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/performance_preferences.dart';
import 'package:wenku8_flutter/reader_preferences.dart';
import 'package:wenku8_flutter/ui_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('glass tier resolution', () {
    ResolvedGlass resolve({
      GlassTier? chosen,
      bool lowEnd = false,
      bool advanced = false,
      PerformancePreferences custom = const PerformancePreferences(),
    }) => resolveGlass(
      chosen: chosen,
      lowEndDevice: lowEnd,
      advanced: advanced,
      sliderBlur: 20,
      sliderOpacity: .5,
      custom: custom,
    );

    test('automatic tier is 标准, or 轻 on low-end devices', () {
      expect(resolve().tier, GlassTier.standard);
      expect(resolve().automatic, isTrue);
      expect(resolve(lowEnd: true).tier, GlassTier.light);
      expect(resolve(chosen: GlassTier.strong, lowEnd: true).tier,
          GlassTier.strong);
    });

    test('标准 equals the v1.7.1 defaults and allows every effect', () {
      final glass = resolve();
      expect(glass.blur, 8);
      expect(glass.opacity, .87);
      expect(glass.performance, const PerformancePreferences());
    });

    test('关 is solid and 轻 drops the 3D shelf', () {
      final off = resolve(chosen: GlassTier.off, advanced: true);
      expect(off.blur, 0, reason: 'advanced sliders never override 关');
      expect(off.opacity, 1);
      expect(off.performance.glass, isFalse);
      expect(off.performance.edgeBlur, isFalse);
      expect(off.performance.motion, isTrue);
      final light = resolve(chosen: GlassTier.light);
      expect(light.blur, 4);
      expect(light.performance.shelf3d, isFalse);
      expect(light.performance.glass, isTrue);
    });

    test('custom switches only narrow the tier', () {
      final glass = resolve(
        custom: const PerformancePreferences(
          enabled: true,
          effects: {PerformanceEffect.motion, PerformanceEffect.blur},
        ),
      );
      expect(glass.performance.blur, isTrue);
      expect(glass.performance.glass, isFalse);
      expect(glass.performance.shelf3d, isFalse);
    });

    test('advanced sliders override blur/opacity on non-off tiers', () {
      final glass = resolve(chosen: GlassTier.light, advanced: true);
      expect(glass.blur, 20);
      expect(glass.opacity, .5);
    });
  });

  test('device profile thresholds', () {
    expect(const DeviceProfile(sdkInt: 29).lowEnd, isTrue);
    expect(const DeviceProfile(sdkInt: 30).lowEnd, isFalse);
    expect(
      const DeviceProfile(sdkInt: 34, totalMemoryBytes: 3800 * 1024 * 1024)
          .lowEnd,
      isTrue,
    );
    expect(
      const DeviceProfile(sdkInt: 34, totalMemoryBytes: 5800 * 1024 * 1024)
          .lowEnd,
      isFalse,
    );
    expect(const DeviceProfile().lowEnd, isFalse);
  });

  group('LibraryState new keys', () {
    test('upgraders with moved sliders keep them as advanced', () async {
      SharedPreferences.setMockInitialValues({
        'glassBlur': 15.0,
        'readerFontSize': 26.0,
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      expect(state.glassAdvanced, isTrue);
      expect(state.resolvedGlass.blur, 15);
      expect(state.fontSize, 26, reason: 'old records load unchanged');
      expect(state.motionLevel, MotionLevel.light);
      expect(state.randomPickPace, RandomPickPace.quick);
      expect(state.pdfNightInvert, isTrue);
    });

    test('fresh install follows the tier and old keys stay untouched',
        () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      expect(state.glassAdvanced, isFalse);
      await state.setGlassTier(GlassTier.light);
      expect(state.resolvedGlass.blur, 4);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.get('glassTier'), 'light');
      expect(prefs.get('glassBlur'), isNull);
      await state.setGlassTier(null);
      expect(prefs.get('glassTier'), glassTierAuto);
      expect(state.glassTierChoice, isNull);
    });

    test('backup round-trips every new key only with preferences', () async {
      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.setGlassTier(GlassTier.strong);
      await state.setMotionLevel(MotionLevel.standard);
      await state.setRandomPickPace(RandomPickPace.ceremony);
      await state.setPdfNightInvert(false);
      await state.setShelfLayout(ShelfLayout.grid);
      await state.setTagMatchMode(TagMatchMode.all);
      await state.setPaletteVariant(OriginalPaletteVariant.ink);
      await state.setReaderPreferences(
        const ReaderPreferences(paper: ReaderPaper.sand, warmth: .2),
      );
      final backup = await LibraryBackup.parse(
        await (await state.createBackup()).encode(),
      );
      for (final key in UiPreferenceKeys.all) {
        expect(backup.records.containsKey(key), isTrue, reason: key);
      }
      await state.setGlassTier(null);
      await state.setMotionLevel(MotionLevel.light);
      await state.setReaderPreferences(const ReaderPreferences());
      await state.restoreBackup(backup);
      expect(state.glassTierChoice, isNull);
      await state.restoreBackup(backup, importPreferences: true);
      expect(state.glassTierChoice, GlassTier.strong);
      expect(state.motionLevel, MotionLevel.standard);
      expect(state.randomPickPace, RandomPickPace.ceremony);
      expect(state.pdfNightInvert, isFalse);
      expect(state.shelfLayout, ShelfLayout.grid);
      expect(state.tagMatchMode, TagMatchMode.all);
      expect(state.paletteVariant, OriginalPaletteVariant.ink);
      expect(state.readerPreferences.paper, ReaderPaper.sand);
      expect(state.readerPreferences.warmth, .2);
    });

    test('invalid new values are rejected as a format error', () async {
      await expectLater(
        LibraryBackup.fromRecords({'glassTier': 'ultra'}),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        LibraryBackup.fromRecords({'readerFontSize': 31.0}),
        throwsA(isA<FormatException>()),
      );
      await LibraryBackup.fromRecords({'readerFontSize': 14.0});
    });
  });

  test('native multi-key writer allows every new key', () {
    final kotlin = File(
      'android/app/src/main/kotlin/org/mewx/wenku8_flutter/LocalTools.kt',
    ).readAsStringSync();
    for (final key in UiPreferenceKeys.all) {
      expect(kotlin.contains('"$key"'), isTrue, reason: key);
    }
  });
}
