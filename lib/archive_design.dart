import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'app_language.dart';

import 'archive_motion.dart';
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

/// The diagram is limited to the header margin. The reading canvas stays plain.
class ArchiveBackdrop extends StatelessWidget {
  const ArchiveBackdrop({super.key, this.filmColor = ArchiveDesign.milk});
  final Color filmColor;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Align(
        alignment: Alignment.topCenter,
        // Bound the raster-cache candidate to the diagram itself, rather than
        // allocating a full-screen layer for an almost empty static painter.
        child: SizedBox(
          width: double.infinity,
          height: MediaQuery.viewPaddingOf(context).top + 240,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _ArchiveBackdropPainter(
                color: Theme.of(context).colorScheme.onSurface,
                filmColor: filmColor,
                top: MediaQuery.viewPaddingOf(context).top,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ArchiveBackdropPainter extends CustomPainter {
  const _ArchiveBackdropPainter({
    required this.color,
    required this.top,
    required this.filmColor,
  });
  final Color color;
  final Color filmColor;
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    final bottom = math.min(size.height, top + 240);
    final dark = color.computeLuminance() > .5;
    final primaryOrbRect = Rect.fromCircle(
      center: Offset(size.width * .18, top + 30),
      radius: math.max(140.0, size.width * .48),
    );
    final primaryOrb = Paint()
      ..shader = RadialGradient(
        colors: [
          (dark ? const Color(0xFF6366F1) : const Color(0xFF818CF8)).withValues(
            alpha: dark ? .18 : .085,
          ),
          Colors.transparent,
        ],
      ).createShader(primaryOrbRect);
    canvas.drawRect(Offset.zero & Size(size.width, bottom), primaryOrb);

    final secondaryOrbRect = Rect.fromCircle(
      center: Offset(size.width * .84, top + 58),
      radius: math.max(115.0, size.width * .40),
    );
    final secondaryOrb = Paint()
      ..shader = RadialGradient(
        colors: [
          (dark ? const Color(0xFF2DD4BF) : const Color(0xFF38BDF8)).withValues(
            alpha: dark ? .13 : .065,
          ),
          Colors.transparent,
        ],
      ).createShader(secondaryOrbRect);
    canvas.drawRect(Offset.zero & Size(size.width, bottom), secondaryOrb);

    final film = Paint()
      ..color = filmColor.withValues(alpha: dark ? .032 : .46);
    // Two restrained frosted prism planes in the existing small header raster.
    // They are paint geometry: no backdrop filter, full-screen layer or ticker.
    final firstPrism = Path()
      ..moveTo(size.width * .42, top)
      ..lineTo(size.width, top)
      ..lineTo(size.width, bottom * .82)
      ..lineTo(size.width * .78, bottom * .82)
      ..close();
    canvas.drawPath(firstPrism, film);

    film.color = filmColor.withValues(alpha: dark ? .020 : .32);
    final secondPrism = Path()
      ..moveTo(size.width * .60, top + 18)
      ..lineTo(size.width, top + 18)
      ..lineTo(size.width, bottom)
      ..lineTo(size.width * .92, bottom)
      ..close();
    canvas.drawPath(secondPrism, film);

    final rimPaint = Paint()
      ..color = filmColor.withValues(alpha: dark ? .09 : .65)
      ..strokeWidth = .8
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(size.width * .42, top),
      Offset(size.width * .78, bottom * .82),
      rimPaint,
    );

    final paint = Paint()
      ..color = color.withValues(alpha: dark ? .028 : .04)
      ..strokeWidth = .5;
    for (var x = 24.0; x < size.width; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, bottom), paint);
    }
    for (var y = top + 4; y < bottom; y += 48) {
      canvas.drawLine(Offset(24, y), Offset(size.width - 24, y), paint);
    }
    paint.color = color.withValues(alpha: dark ? .12 : .15);
    final y = top + 60;
    for (final x in [24.0, size.width - 24]) {
      canvas.drawLine(Offset(x - 3, y), Offset(x + 3, y), paint);
      canvas.drawLine(Offset(x, y - 3), Offset(x, y + 3), paint);
    }
  }

  @override
  bool shouldRepaint(_ArchiveBackdropPainter oldDelegate) =>
      color != oldDelegate.color ||
      top != oldDelegate.top ||
      filmColor != oldDelegate.filmColor;
}
