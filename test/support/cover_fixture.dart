import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wenku8_flutter/catalog.dart';

Novel coverFixtureBook(int id) => Novel(
  id: id,
  title: '透明档案',
  author: '封面回归',
  genre: '固定样本',
  summary: '仅用于封面解码与入场验证。',
  coverUrl: 'fixture://cover/$id',
  colors: const [Color(0xFF49666C), Color(0xFFE8E4DC)],
);

Future<Uint8List> coverFixtureBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 80, 120),
    Paint()..color = const Color(0xFFE8E4DC),
  );
  canvas.drawRect(
    const Rect.fromLTWH(10, 10, 60, 68),
    Paint()..color = const Color(0xFF49666C),
  );
  canvas.drawPath(
    Path()
      ..moveTo(28, 10)
      ..lineTo(70, 10)
      ..lineTo(70, 78)
      ..close(),
    Paint()..color = const Color(0xFF6F8689),
  );
  canvas.drawRect(
    const Rect.fromLTWH(10, 91, 42, 4),
    Paint()..color = const Color(0xFF252D29),
  );
  canvas.drawRect(
    const Rect.fromLTWH(10, 103, 26, 2),
    Paint()..color = const Color(0xFF69746C),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(80, 120);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final bytes = Uint8List.fromList(data.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return bytes;
}
