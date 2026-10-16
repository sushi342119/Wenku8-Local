import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';

import '../test/adaptive_ui_test.dart' as adaptive;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NativeEffects.prepare);
  testWidgets(
    'native version channel reads installed APK and rejects unsafe install paths',
    (tester) async {
      final platform = AndroidUpdatePlatform();
      final info = await platform.installedApp();
      expect(info.version, currentAppVersion);
      expect(info.build, currentAppBuild);
      expect(info.abis, contains('arm64-v8a'));
      await expectLater(
        platform.install(File('/invalid/update.apk'), '99.0.0'),
        throwsA(isA<Exception>()),
      );
      // ignore: avoid_print
      print(
        'NATIVE_UPDATE_INFO version=${info.version}+${info.build} abis=${info.abis.join(',')}',
      );
    },
  );
  adaptive.main(
    native: true,
    capture: (tester, boundary, name) async {
      await tester.pump();
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
      await directory.create(recursive: true);
      final file = File('${directory.path}/adaptive-$name.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      // ignore: avoid_print
      print('UI_REFINEMENT_CAPTURE=${file.path}');
    },
  );
}
