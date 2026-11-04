import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// EPUB image sizing travels beside the existing image marker. Asset URLs,
/// paragraph indices and old imported chapters keep their original meaning.
class LocalImageLayout {
  const LocalImageLayout({
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
  });
  final String? width, height, maxWidth, maxHeight;
  static const _prefix = '<!--epub-image:';
  static final _length = RegExp(r'^(\d+(?:\.\d+)?|\.\d+)(px|em|rem|%|pt)?$');
  static String? length(String? value) {
    final text = value?.trim().toLowerCase();
    if (text == null || !_length.hasMatch(text)) return null;
    final number = double.tryParse(_length.firstMatch(text)![1]!);
    return number != null && number.isFinite && number > 0 ? text : null;
  }

  factory LocalImageLayout.fromProperties(Map<String, String> values) =>
      LocalImageLayout(
        width: length(values['width']),
        height: length(values['height']),
        maxWidth: length(values['max-width']),
        maxHeight: length(values['max-height']),
      );
  bool get isEmpty =>
      width == null && height == null && maxWidth == null && maxHeight == null;
  String get suffix => isEmpty
      ? ''
      : '$_prefix${[if (width != null) 'w=$width', if (height != null) 'h=$height', if (maxWidth != null) 'mw=$maxWidth', if (maxHeight != null) 'mh=$maxHeight'].join(';')}-->';
  static LocalImageLayout? parseSuffix(String text) {
    if (text.isEmpty) return const LocalImageLayout();
    if (!text.startsWith(_prefix) || !text.endsWith('-->')) return null;
    final values = <String, String>{};
    const keys = {
      'w': 'width',
      'h': 'height',
      'mw': 'max-width',
      'mh': 'max-height',
    };
    for (final part
        in text.substring(_prefix.length, text.length - 3).split(';')) {
      final pair = part.split('=');
      if (pair.length != 2 ||
          !keys.containsKey(pair[0]) ||
          length(pair[1]) == null ||
          values.containsKey(keys[pair[0]])) {
        return null;
      }
      values[keys[pair[0]]!] = pair[1];
    }
    return LocalImageLayout.fromProperties(values);
  }

  static LocalImageLayout fromParagraph(String paragraph) {
    const marker = '<!--image-->';
    final end = paragraph.indexOf(marker, marker.length);
    return end < 0
        ? const LocalImageLayout()
        : parseSuffix(paragraph.substring(end + marker.length).trim()) ??
              const LocalImageLayout();
  }

  Size resolve({
    required Size natural,
    required Size available,
    double fontSize = 19,
  }) {
    double? pixels(String? text, double extent) {
      if (text == null) return null;
      final match = _length.firstMatch(text)!;
      final value = double.parse(match[1]!);
      if (match[2] == '%' && !extent.isFinite) return null;
      return value *
          switch (match[2]) {
            'em' || 'rem' => fontSize,
            '%' => extent / 100,
            'pt' => 96 / 72,
            _ => 1.0,
          };
    }

    final w = pixels(width, available.width),
        h = pixels(height, available.height);
    final ratio = natural.aspectRatio;
    final desired = Size(
      w ?? (h == null ? natural.width : h * ratio),
      h ?? (w == null ? natural.height : w / ratio),
    );
    final bound = Size(
      math.min(
        available.width,
        pixels(maxWidth, available.width) ?? available.width,
      ),
      math.min(
        available.height,
        pixels(maxHeight, available.height) ?? available.height,
      ),
    );
    return applyBoxFit(BoxFit.scaleDown, desired, bound).destination;
  }
}
