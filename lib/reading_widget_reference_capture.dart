import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reading_widget_reference.dart';
import 'reading_widget_snapshot.dart';

Future<void> warmReadingDesktopImages(ReadingWidgetSnapshot snapshot) async {}

Future<Uint8List> renderReadingDesktopCard(
  ReadingWidgetSnapshot snapshot,
  ReadingDesktopSize size, {
  required Brightness brightness,
  bool paintQuote = true,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final logical = size.logicalSize;
  const scale = 2.0;
  canvas.scale(scale, scale);

  final isDark = brightness == Brightness.dark;
  final bg = isDark ? const Color(0xFF1A1917) : const Color(0xFFF7F3EB);
  final fg = isDark ? const Color(0xFFF3EFEA) : const Color(0xFF22201D);

  final rrect = RRect.fromRectAndRadius(
    Offset.zero & logical,
    const Radius.circular(24),
  );
  canvas.drawRRect(rrect, Paint()..color = bg);

  final titlePainter = TextPainter(
    text: TextSpan(
      text: '${snapshot.design.label} · ${snapshot.skin.label}',
      style: TextStyle(
        color: fg.withValues(alpha: 0.72),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: logical.width - 36);
  titlePainter.paint(canvas, const Offset(18, 18));

  final bodyText = paintQuote
      ? '${widgetMinutes(snapshot.verifiedTodaySeconds)} 分钟今日阅读'
      : '累计 ${widgetMinutes(snapshot.verifiedTotalSeconds)} 分钟';
  final bodyPainter = TextPainter(
    text: TextSpan(
      text: bodyText,
      style: TextStyle(
        color: fg,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
  )..layout(maxWidth: logical.width - 36);
  bodyPainter.paint(canvas, Offset(18, logical.height - bodyPainter.height - 22));

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (logical.width * scale).round(),
    (logical.height * scale).round(),
  );
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List() ?? Uint8List(0);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Map<String, Uint8List>> renderReadingDesktopCards(
  ReadingWidgetSnapshot snapshot,
) async {
  final result = <String, Uint8List>{};
  for (final brightness in Brightness.values) {
    for (final size in ReadingDesktopSize.values) {
      final key = '${size.name}_${brightness.name}';
      result[key] = await renderReadingDesktopCard(
        snapshot,
        size,
        brightness: brightness,
      );
    }
  }
  return result;
}
