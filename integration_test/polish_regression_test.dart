import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';

import '../test/polish_reader_ui_test.dart' as polish;
import 'popup_alignment_test.dart' as popup;
import 'reader_tools_features_test.dart' as tools;
import 'ui_refinement_test.dart' as optics;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('polish details', () {
    setUp(() async => NativeEffects.prepare());
    polish.main(
      capture: (tester, key, name) async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: tester.view.devicePixelRatio);
        final directory = Directory('${Directory.systemTemp.path}/polish-ui');
        await directory.create(recursive: true);
        final file = File('${directory.path}/$name.png');
        await file.writeAsBytes(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
        image.dispose();
        // ignore: avoid_print
        print('POLISH_CAPTURE=${file.path}');
      },
    );
  });
  group('reader tools', tools.main);
  group('popup geometry', popup.main);
  group('glass and motion', optics.main);
}
