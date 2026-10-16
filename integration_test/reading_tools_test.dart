import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';

import '../test/reading_tools_ui_test.dart' as features;

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final image =
      await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
          .toImage(pixelRatio: tester.view.devicePixelRatio);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  // ignore: avoid_print
  print('UI_REFINEMENT_CAPTURE=${file.path}');
  image.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NativeEffects.prepare);
  features.main(capture: _capture);
}
