// Run: flutter test tools/generate_app_icons.dart
// SVG is the single source; no fonts, raster source assets or runtime package.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('export archive launcher icons from the vector source', () async {
    final svg = XmlDocument.parse(
      await File('assets/branding/app-icon.svg').readAsString(),
    );
    final shapes = svg.findAllElements('path').toList();
    const background = ui.Color(0xFFF4F3EF);
    final res = Directory('android/app/src/main/res');
    Future<void> write(String path, String text) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }

    String vector({bool monochrome = false}) =>
        '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
${shapes.asMap().entries.where((e) => !monochrome || e.key != 3).map((e) => '    <path android:fillColor="${monochrome ? '#000000' : e.value.getAttribute('fill')}" android:fillAlpha="${monochrome && e.key == 0 ? '.24' : e.value.getAttribute('fill-opacity') ?? '1'}" android:fillType="evenOdd" android:pathData="${e.value.getAttribute('d')}"/>').join('\n')}
</vector>
''';
    await write('${res.path}/drawable/ic_archive_foreground.xml', vector());
    await write(
      '${res.path}/drawable/ic_archive_monochrome.xml',
      vector(monochrome: true),
    );
    await write(
      '${res.path}/values/archive_icon.xml',
      '<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="archive_icon_background">#F4F3EF</color></resources>\n',
    );
    for (final version in [26, 33]) {
      await write(
        '${res.path}/mipmap-anydpi-v$version/ic_launcher.xml',
        '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/archive_icon_background"/>
    <foreground android:drawable="@drawable/ic_archive_foreground"/>
${version >= 33 ? '    <monochrome android:drawable="@drawable/ic_archive_monochrome"/>\n' : ''}</adaptive-icon>
''',
      );
    }

    Future<Uint8List> render(int size) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..scale(size / 72)
        ..translate(-18, -18);
      canvas.drawColor(background, ui.BlendMode.src);
      for (final shape in shapes) {
        final color =
            ui.Color(
              0xFF000000 |
                  int.parse(
                    shape.getAttribute('fill')!.substring(1),
                    radix: 16,
                  ),
            ).withValues(
              alpha: double.parse(shape.getAttribute('fill-opacity') ?? '1'),
            );
        canvas.drawPath(
          _path(shape.getAttribute('d')!),
          ui.Paint()..color = color,
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(size, size);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final png = _opaquePng(data.buffer.asUint8List(), size);
      image.dispose();
      picture.dispose();
      return png;
    }

    final rendered = <int, Uint8List>{};
    Future<void> png(String path, int size) async {
      final bytes = rendered[size] ??= await render(size);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }

    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      await png('${res.path}/mipmap-${entry.key}/ic_launcher.png', entry.value);
    }
    const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents =
        jsonDecode(await File('$ios/Contents.json').readAsString()) as Map;
    for (final item in contents['images'] as List) {
      final side = double.parse((item['size'] as String).split('x').first);
      final scale = double.parse((item['scale'] as String).replaceAll('x', ''));
      await png('$ios/${item['filename']}', (side * scale).round());
    }
    await png('flutter_screenshots/loading-polish/app-icon.png', 512);
  });
}

ui.Path _path(String data) {
  final tokens = RegExp(
    r'[MLZ]|-?\d+(?:\.\d+)?',
  ).allMatches(data).map((m) => m.group(0)!).toList();
  final path = ui.Path()..fillType = ui.PathFillType.evenOdd;
  for (var i = 0; i < tokens.length;) {
    final command = tokens[i++];
    if (command == 'Z') {
      path.close();
    } else {
      final x = double.parse(tokens[i++]);
      final y = double.parse(tokens[i++]);
      if (command == 'M') {
        path.moveTo(x, y);
      } else {
        assert(command == 'L');
        path.lineTo(x, y);
      }
    }
  }
  return path;
}

// RGB PNG: iOS app icons must not contain an alpha channel, even if opaque.
Uint8List _opaquePng(Uint8List rgba, int size) {
  final rows = BytesBuilder();
  for (var y = 0; y < size; y++) {
    rows.addByte(0);
    for (var x = 0; x < size; x++) {
      final offset = (y * size + x) * 4;
      assert(rgba[offset + 3] == 255);
      rows.add(rgba.sublist(offset, offset + 3));
    }
  }
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> payload) {
    final body = Uint8List.fromList([...ascii.encode(type), ...payload]);
    var crc = 0xFFFFFFFF;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0);
      }
    }
    final length = ByteData(4)..setUint32(0, payload.length);
    final checksum = ByteData(4)..setUint32(0, crc ^ 0xFFFFFFFF);
    out
      ..add(length.buffer.asUint8List())
      ..add(body)
      ..add(checksum.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert(rows.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}
