import 'package:flutter/material.dart';

/// Optional local material colors; other app surfaces keep their defaults.
@immutable
class GlassPalette extends ThemeExtension<GlassPalette> {
  const GlassPalette({required this.tint, required this.thumb});
  final Color tint, thumb;
  @override
  GlassPalette copyWith({Color? tint, Color? thumb}) =>
      GlassPalette(tint: tint ?? this.tint, thumb: thumb ?? this.thumb);
  @override
  GlassPalette lerp(GlassPalette? other, double t) => other == null
      ? this
      : GlassPalette(
          tint: Color.lerp(tint, other.tint, t)!,
          thumb: Color.lerp(thumb, other.thumb, t)!,
        );
}
