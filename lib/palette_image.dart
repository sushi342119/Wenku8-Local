import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

class PaletteImage {
  PaletteImage(this.png, this.rgba, this.width, this.height, this.seeds);
  final Uint8List png, rgba;
  final int width, height;
  final List<int> seeds;
  static Future<PaletteImage> decode(Uint8List png) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(png);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale =
          (256 /
                  (descriptor.width > descriptor.height
                      ? descriptor.width
                      : descriptor.height))
              .clamp(0.0, 1.0);
      codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, 256),
        targetHeight: (descriptor.height * scale).round().clamp(1, 256),
      );
      image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!;
      final rgba = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final seeds = await compute(paletteImageSeeds, rgba);
      return PaletteImage(png, rgba, image.width, image.height, seeds);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Rect imageRect(Size viewport) => Alignment.center.inscribe(
    applyBoxFit(
      BoxFit.contain,
      Size(width.toDouble(), height.toDouble()),
      viewport,
    ).destination,
    Offset.zero & viewport,
  );
  Color? colorAt(Offset point, Size viewport) {
    final rect = imageRect(viewport);
    if (!rect.contains(point) || rect.isEmpty) return null;
    final x = ((point.dx - rect.left) / rect.width * width).floor().clamp(
      0,
      width - 1,
    );
    final y = ((point.dy - rect.top) / rect.height * height).floor().clamp(
      0,
      height - 1,
    );
    final i = (y * width + x) * 4;
    return rgba[i + 3] < 16 ? null : Color(_opaquePixel(rgba, i));
  }
}

int _opaquePixel(Uint8List rgba, int i) {
  final alpha = rgba[i + 3];
  int channel(int offset) =>
      ((rgba[i + offset] * alpha + 255 * (255 - alpha)) / 255).round();
  return 0xff000000 | (channel(0) << 16) | (channel(1) << 8) | channel(2);
}

/// Runs once per image in an isolate, never during dragging or app frames.
Future<List<int>> paletteImageSeeds(Uint8List rgba) async {
  final pixels = <int>[];
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] >= 128) pixels.add(_opaquePixel(rgba, i));
  }
  if (pixels.isEmpty) throw const FormatException('图片中没有可用颜色，请选择其他图片');
  final quantized = (await QuantizerCelebi().quantize(pixels, 64)).colorToCount;
  final dominant = quantized.entries
      .reduce((a, b) => a.value >= b.value ? a : b)
      .key;
  return Score.score(quantized, desired: 6, fallbackColorARGB: dominant);
}
