import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'app_language.dart';

import 'archive_motion.dart';
import 'canvas_halftone.dart';
import 'library_reflow.dart';

/// The archive vocabulary is foreground geometry, not another filter layer.
/// Codes, rules and registration marks are static and carry no idle ticker.
abstract final class ArchiveDesign {
  static const background = Color(0xFFF4F3EF);
  static const surface = Color(0xFFFDFCFA);
  static const milk = Color(0xFFFEFDF8);
  static const darkBackground = Color(0xFF0A0E17);
  static const darkSurface = Color(0xFF121826);
  static const darkRaised = Color(0xFF182032);
  static const darkRaisedHigh = Color(0xFF212B42);
  static const darkOutline = Color(0xFF28344E);
  static const darkInk = Color(0xFFF3F6FC);
  static const darkMuted = Color(0xFF9BA8C2);
  static const darkMilk = Color(0xFFEAF0FA);
  // Design 2026-11: cards and panels 14 (was 12); bottom sheets 24.
  static const panelRadius = 14.0;
  static const sheetRadius = 24.0;
  static const controlRadius = 10.0;
  static const coverRadius = 7.0;

  /// A thin neutral milk layer, not a white opaque sheet or another blur pass.
  static Color glassTint(Brightness brightness, {required double opacity}) =>
      brightness == Brightness.dark
      // Keep white labels legible even at the user's opaque endpoint.
      ? Color.lerp(darkMilk, darkSurface, opacity.clamp(0.0, 1.0))!
      : milk;

  static TextStyle codeStyle(BuildContext context, {Color? color}) => TextStyle(
    fontFamily: 'monospace',
    fontSize: 9,
    height: 1.35,
    letterSpacing: 1.05,
    fontWeight: FontWeight.w500,
    color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
  );

  static bool isBookCode(String code) =>
      RegExp(r'^(WK|LC)-\d+$').hasMatch(code.trim());

  static String fileCode(int id) {
    if (id >= 0x40000000 && id <= 0x7fffffff) {
      final shortId = (id - 0x40000000) % 100000;
      return 'LC-${shortId.toString().padLeft(5, '0')}';
    }
    final shortId = id.abs() % 100000;
    return 'WK-${shortId.toString().padLeft(5, '0')}';
  }
}

class ArchiveMasthead extends StatelessWidget {
  const ArchiveMasthead({
    super.key,
    required this.title,
    this.code = '',
    this.brand = false,
  });
  final String title;
  final String code;
  final bool brand;

  @override
  Widget build(BuildContext context) => LibraryReflowPart(
    child: Row(
      children: [
        if (brand) ...[
          ExcludeSemantics(
            child: SizedBox(
              width: 30,
              height: 34,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Image.asset(
                    'assets/branding/app-icon.png',
                    key: const ValueKey('discovery-app-icon'),
                    width: 30,
                    height: 30,
                    fit: BoxFit.contain,
                    cacheWidth: (30 * MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          // Keep the fixed 56 px toolbar usable with large system text, without
          // shrinking any reading content or enlarging its pinned hitbox plane.
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Keep the navigation landmark immediately readable; the
                  // archive address below it performs the terminal assembly.
                  AppText(
                    title,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 23,
                      height: 1.18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.7,
                      shadows: [],
                    ),
                  ),
                  if (ArchiveDesign.isBookCode(code)) ...[
                    const SizedBox(height: 3),
                    ArchivePart(start: .16, end: .88, child: ArchiveCode(code)),
                  ] else
                    const ArchivePart(
                      start: .16,
                      end: .88,
                      child: SizedBox.shrink(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class ArchiveCode extends StatelessWidget {
  const ArchiveCode(this.text, {super.key, this.inverse = false, this.color});
  final String text;
  final bool inverse;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = AppText(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textScaler: TextScaler.noScaling,
      style: ArchiveDesign.codeStyle(
        context,
        color: color ?? (inverse ? scheme.surface : null),
      ),
    );
    return ExcludeSemantics(
      child: inverse
          ? ColoredBox(
              color: scheme.onSurface,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: label,
              ),
            )
          : label,
    );
  }
}

class ArchiveSection extends StatelessWidget {
  const ArchiveSection({
    super.key,
    required this.title,
    this.code = '',
    this.subtitle = '',
  });
  final String title;
  final String code;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final showCode = ArchiveDesign.isBookCode(code);
    return LibraryReflowPart(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showCode) ...[
            LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.max(0, constraints.maxWidth - 17),
                    ),
                    child: ArchivePart(
                      start: .1,
                      end: .68,
                      child: ArchiveCode(code),
                    ),
                  ),
                  const SizedBox(width: 9),
                  if (constraints.hasBoundedWidth)
                    Expanded(
                      child: const ArchivePart(
                        start: 0,
                        end: .46,
                        child: ExcludeSemantics(
                          child: Divider(height: 1, thickness: .6),
                        ),
                      ),
                    ),
                  const SizedBox(width: 5),
                  ExcludeSemantics(
                    child: SizedBox(
                      width: 3,
                      height: 3,
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
          ] else ...[
            const ArchivePart(start: .1, end: .68, child: SizedBox.shrink()),
            const ArchivePart(start: 0, end: .46, child: SizedBox.shrink()),
          ],
          ArchivePart(
            start: .16,
            end: .82,
            child: AppText(
              title,
              style: const TextStyle(
                fontSize: 18,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -.3,
              ),
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 5),
            AppText(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Readable route title plus a restrained archive address below it.
class ArchiveRouteTitle extends StatelessWidget {
  const ArchiveRouteTitle({
    super.key,
    required this.title,
    this.code = '',
  });
  final String title;
  final String code;

  @override
  Widget build(BuildContext context) {
    final showCode = ArchiveDesign.isBookCode(code);
    return LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: constraints.maxWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              if (showCode) ...[
                const SizedBox(height: 3),
                ArchiveCode(code),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ArchiveRegistration extends StatelessWidget {
  const ArchiveRegistration({super.key, required this.child, this.inset = 0});
  final Widget child;
  final double inset;

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _RegistrationPainter(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .5),
      inset: inset,
    ),
    child: child,
  );
}

class _RegistrationPainter extends CustomPainter {
  const _RegistrationPainter({required this.color, required this.inset});
  final Color color;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = .7
      ..style = PaintingStyle.stroke;
    final r = (Offset.zero & size).deflate(inset + .5);
    final length = math.min(7.0, math.min(r.width, r.height) / 3);
    if (length <= 0) return;
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx + dx * length, corner.dy)
          ..lineTo(corner.dx, corner.dy)
          ..lineTo(corner.dx, corner.dy + dy * length),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RegistrationPainter oldDelegate) =>
      color != oldDelegate.color || inset != oldDelegate.inset;
}

/// Static full-page "Shuyu" island-contour and micro-grid backdrop.
/// Reader pages opt out (`archiveBackdrop: false`) so reading stays plain.
class ArchiveBackdrop extends StatelessWidget {
  const ArchiveBackdrop({super.key, this.filmColor = ArchiveDesign.milk});
  final Color filmColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.viewPaddingOf(context).top;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _ArchiveBackdropPainter(
              color: scheme.onSurface,
              primary: scheme.primary,
              secondary: scheme.secondary,
              filmColor: filmColor,
              top: top,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _ArchiveBackdropPainter extends CustomPainter {
  const _ArchiveBackdropPainter({
    required this.color,
    required this.primary,
    required this.secondary,
    required this.top,
    required this.filmColor,
  });
  final Color color;
  final Color primary;
  final Color secondary;
  final Color filmColor;
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width;
    final h = size.height;
    final headerBottom = math.min(h, top + 240);
    final dark = color.computeLuminance() > .5;

    final primaryTone = dark
        ? primary
        : Color.lerp(primary, const Color(0xFF4F46E5), .24)!;
    final secondaryTone = dark
        ? secondary
        : Color.lerp(secondary, const Color(0xFF0EA5E9), .24)!;
    final contourPrimary = Color.lerp(primaryTone, color, dark ? .18 : .24)!;
    final contourSecondary = Color.lerp(
      secondaryTone,
      color,
      dark ? .20 : .28,
    )!;
    final gridTone = Color.lerp(color, primaryTone, dark ? .35 : .28)!;

    // 1. Ambient island glows across header and lower shoal margins.
    final primaryOrbRect = Rect.fromCircle(
      center: Offset(w * .16, top + 32),
      radius: math.max(150.0, w * .52),
    );
    final primaryOrb = Paint()
      ..shader = RadialGradient(
        colors: [
          primaryTone.withValues(alpha: dark ? .19 : .095),
          Colors.transparent,
        ],
      ).createShader(primaryOrbRect);
    canvas.drawRect(Offset.zero & Size(w, math.min(h, top + 340)), primaryOrb);

    final secondaryOrbRect = Rect.fromCircle(
      center: Offset(w * .85, top + 62),
      radius: math.max(125.0, w * .44),
    );
    final secondaryOrb = Paint()
      ..shader = RadialGradient(
        colors: [
          secondaryTone.withValues(alpha: dark ? .14 : .075),
          Colors.transparent,
        ],
      ).createShader(secondaryOrbRect);
    canvas.drawRect(
      Offset.zero & Size(w, math.min(h, top + 320)),
      secondaryOrb,
    );

    if (h > 280) {
      final lowerShoalRect = Rect.fromCircle(
        center: Offset(w * .84, h * .82),
        radius: math.max(160.0, w * .54),
      );
      final lowerShoalOrb = Paint()
        ..shader = RadialGradient(
          colors: [
            primaryTone.withValues(alpha: dark ? .12 : .06),
            Colors.transparent,
          ],
        ).createShader(lowerShoalRect);
      canvas.drawRect(
        Rect.fromLTRB(0, math.max(0, h * .35), w, h),
        lowerShoalOrb,
      );

      final leftMistRect = Rect.fromCircle(
        center: Offset(w * .14, h * .64),
        radius: math.max(135.0, w * .42),
      );
      final leftMistOrb = Paint()
        ..shader = RadialGradient(
          colors: [
            secondaryTone.withValues(alpha: dark ? .085 : .048),
            Colors.transparent,
          ],
        ).createShader(leftMistRect);
      canvas.drawRect(
        Rect.fromLTRB(0, math.max(0, h * .25), w, h),
        leftMistOrb,
      );
    }

    // 2. Translucent geometric prism planes.
    final film = Paint()..color = filmColor.withValues(alpha: dark ? .034 : .48);
    final firstPrism = Path()
      ..moveTo(w * .42, top)
      ..lineTo(w, top)
      ..lineTo(w, headerBottom * .82)
      ..lineTo(w * .78, headerBottom * .82)
      ..close();
    canvas.drawPath(firstPrism, film);

    film.color = filmColor.withValues(alpha: dark ? .022 : .34);
    final secondPrism = Path()
      ..moveTo(w * .60, top + 18)
      ..lineTo(w, top + 18)
      ..lineTo(w, headerBottom)
      ..lineTo(w * .92, headerBottom)
      ..close();
    canvas.drawPath(secondPrism, film);

    final rimPaint = Paint()
      ..color = filmColor.withValues(alpha: dark ? .095 : .68)
      ..strokeWidth = .8
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(w * .42, top),
      Offset(w * .78, headerBottom * .82),
      rimPaint,
    );

    if (h > 320) {
      film.color = filmColor.withValues(alpha: dark ? .018 : .28);
      final lowerPrism = Path()
        ..moveTo(0, h * .76)
        ..lineTo(w * .34, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(lowerPrism, film);
      canvas.drawLine(
        Offset(0, h * .76),
        Offset(w * .34, h),
        rimPaint..color = filmColor.withValues(alpha: dark ? .065 : .48),
      );
    }

    // 3. Architectural micro-grid with smooth vertical attenuation.
    final gridPaint = Paint()
      ..strokeWidth = .6
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0.0, 0.34, 0.66, 1.0],
        colors: [
          gridTone.withValues(alpha: dark ? .058 : .068),
          gridTone.withValues(alpha: dark ? .036 : .042),
          gridTone.withValues(alpha: dark ? .016 : .020),
          gridTone.withValues(alpha: dark ? .044 : .052),
        ],
      ).createShader(Offset.zero & size);
    for (var x = 24.0; x < w; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }
    if (w > 48) {
      for (var y = top + 4; y < h; y += 48) {
        canvas.drawLine(Offset(24, y), Offset(w - 24, y), gridPaint);
      }
    }

    // Sparse micro-intersection node dots in header and footer margins.
    final nodePaint = Paint()
      ..color = gridTone.withValues(alpha: dark ? .095 : .105);
    var colIndex = 0;
    for (var x = 24.0; x < w; x += 48, colIndex++) {
      var rowIndex = 0;
      for (var y = top + 4; y < h; y += 48, rowIndex++) {
        if ((colIndex + rowIndex).isOdd) continue;
        final inUpper = y <= top + 200;
        final inLower = h > 360 && y >= h - 148;
        if (inUpper || inLower) {
          canvas.drawCircle(Offset(x, y), 1.05, nodePaint);
        }
      }
    }

    // 4. Radial halftone sand/mist dot clusters at opposite corners.
    final upperHalftoneHeight = math.min(math.max(0.0, h - top), 196.0);
    if (upperHalftoneHeight > 24) {
      paintCanvasHalftone(
        canvas,
        Rect.fromLTWH(0, top, math.min(w * .54, 240), upperHalftoneHeight),
        color: contourPrimary.withValues(alpha: dark ? .095 : .085),
        falloff: HalftoneFalloff.radial,
        focus: const Offset(.18, .22),
        radialExtent: .78,
        pitch: 16,
        maxRadius: 1.35,
      );
    }
    if (h > 340) {
      final lowerWidth = math.min(w * .54, 240.0);
      paintCanvasHalftone(
        canvas,
        Rect.fromLTWH(math.max(0, w - lowerWidth), h - 210, lowerWidth, 210),
        color: contourSecondary.withValues(alpha: dark ? .085 : .075),
        falloff: HalftoneFalloff.radial,
        focus: const Offset(.82, .78),
        radialExtent: .76,
        pitch: 16,
        maxRadius: 1.25,
      );
    }

    // 5. "Shuyu" (书屿) topographic island & water-ripple contour curves.
    final contourPaint = Paint()..style = PaintingStyle.stroke;

    // 5a. Upper-right main island elevation contours (5 nested flowing curves).
    final summitLoop = Path()
      ..moveTo(w * .68, 0)
      ..quadraticBezierTo(w * .79, top + 64, w, math.min(h, top + 58));
    contourPaint
      ..color = contourPrimary.withValues(alpha: dark ? .115 : .095)
      ..strokeWidth = .9;
    canvas.drawPath(summitLoop, contourPaint);

    for (var i = 0; i < 5; i++) {
      final startX = w * (.48 - i * .068);
      final endY = math.min(h, top + 114 + i * 34.0);
      final midY1 = math.min(h, top + 44 + i * 16.0);
      final midY2 = math.min(h, top + 86 + i * 24.0);
      final midY3 = math.min(h, top + 96 + i * 27.0);
      final contour = Path()
        ..moveTo(startX, 0)
        ..cubicTo(
          startX + w * .04,
          midY1,
          w * (.66 - i * .045),
          midY2,
          w * (.82 - i * .03),
          midY3,
        )
        ..cubicTo(
          w * (.91 - i * .015),
          math.min(h, top + 102 + i * 29.0),
          w * .96,
          math.max(0, endY - 12),
          w,
          endY,
        );
      final alpha = (dark ? .13 : .11) - i * (dark ? .018 : .015);
      contourPaint
        ..color = contourPrimary.withValues(alpha: alpha.clamp(0.02, 1.0))
        ..strokeWidth = i == 1 ? 1.05 : (i == 0 ? .95 : .78);
      canvas.drawPath(contour, contourPaint);
    }

    // 5b. Middle-left shoreline S-wave contours along the page margin.
    if (h > 220) {
      for (var i = 0; i < 4; i++) {
        final waveTop = top + 108 + i * 20.0;
        final waveMidY = h * .44 + i * 14.0;
        final waveBot = math.min(h, h * .74 + i * 22.0);
        final crestX = math.min(w * .36, 36.0 + i * 20.0);
        if (waveBot <= waveTop + 36) continue;
        final shoreline = Path()
          ..moveTo(0, waveTop)
          ..cubicTo(
            crestX * .85,
            waveTop + (waveMidY - waveTop) * .38,
            crestX * 1.12,
            waveMidY - (waveMidY - waveTop) * .22,
            crestX,
            waveMidY,
          )
          ..cubicTo(
            crestX * .88,
            waveMidY + (waveBot - waveMidY) * .28,
            crestX * .32,
            waveBot - (waveBot - waveMidY) * .24,
            0,
            waveBot,
          );
        final alpha = (dark ? .105 : .088) - i * (dark ? .017 : .014);
        contourPaint
          ..color = contourSecondary.withValues(alpha: alpha.clamp(0.02, 1.0))
          ..strokeWidth = i == 0 ? .95 : .78;
        canvas.drawPath(shoreline, contourPaint);
      }
    }

    // 5c. Lower-right shoal ripple contours anchoring the bottom corner.
    if (h > 280) {
      for (var i = 0; i < 4; i++) {
        final rightY = math.max(top + 72.0, h - 188 - i * 32.0);
        final bottomX = math.max(0.0, w - 142 - i * 42.0);
        final shoal = Path()
          ..moveTo(w, rightY)
          ..cubicTo(
            w - 48 - i * 18.0,
            rightY + (h - rightY) * .18,
            bottomX + (w - bottomX) * .36,
            h - (h - rightY) * .52,
            bottomX,
            h,
          );
        final alpha = (dark ? .11 : .092) - i * (dark ? .018 : .015);
        contourPaint
          ..color = contourPrimary.withValues(alpha: alpha.clamp(0.02, 1.0))
          ..strokeWidth = i == 0 ? .95 : .78;
        canvas.drawPath(shoal, contourPaint);
      }
    }

    // 6. Delicate geometric compass arc & calibration crosshairs.
    final compassCenter = Offset(w * .84, top + 48);
    const compassRadius = 64.0;
    final markPaint = Paint()
      ..color = gridTone.withValues(alpha: dark ? .13 : .14)
      ..strokeWidth = .75
      ..style = PaintingStyle.stroke;
    canvas.drawArc(
      Rect.fromCircle(center: compassCenter, radius: compassRadius),
      .58 * math.pi,
      .54 * math.pi,
      false,
      markPaint,
    );
    for (var t = 0; t <= 5; t++) {
      final angle = (.60 + t * .10) * math.pi;
      final tickLen = t == 2 ? 5.5 : 3.2;
      final p1 = Offset(
        compassCenter.dx + math.cos(angle) * (compassRadius - tickLen),
        compassCenter.dy + math.sin(angle) * (compassRadius - tickLen),
      );
      final p2 = Offset(
        compassCenter.dx + math.cos(angle) * (compassRadius + 1.5),
        compassCenter.dy + math.sin(angle) * (compassRadius + 1.5),
      );
      canvas.drawLine(p1, p2, markPaint);
    }

    markPaint
      ..color = gridTone.withValues(alpha: dark ? .14 : .16)
      ..strokeWidth = .8;
    final crossYPositions = <double>[
      top + 60,
      if (h > 360) h - 72,
    ];
    for (final y in crossYPositions) {
      if (y >= h) continue;
      for (final x in [24.0, if (w > 48) w - 24]) {
        canvas.drawLine(Offset(x - 3.5, y), Offset(x + 3.5, y), markPaint);
        canvas.drawLine(Offset(x, y - 3.5), Offset(x, y + 3.5), markPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_ArchiveBackdropPainter oldDelegate) =>
      color != oldDelegate.color ||
      primary != oldDelegate.primary ||
      secondary != oldDelegate.secondary ||
      top != oldDelegate.top ||
      filmColor != oldDelegate.filmColor;
}
