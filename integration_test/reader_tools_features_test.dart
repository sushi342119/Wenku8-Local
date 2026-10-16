import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';

import '../test/reader_tools_features_test.dart' as features;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await NativeEffects.prepare();
  });
  features.main(
    capture: (tester, key, name) async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: tester.view.devicePixelRatio);
      final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
      await directory.create(recursive: true);
      final file = File('${directory.path}/$name.png');
      await file.writeAsBytes(
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
      image.dispose();
      // ignore: avoid_print
      print('UI_REFINEMENT_CAPTURE=${file.path}');
    },
  );
}
