# Wenku8 performance patch

Based on the unmodified **liquid_glass_easy 5.0.0** pub.dev source archive,
by Ahmed Gamil. The upstream MIT license is retained in `LICENSE`.

Source: https://pub.dev/packages/liquid_glass_easy/versions/5.0.0
Upstream: https://github.com/AhmeedGamil/liquid_glass_easy

## 2026-10-15 — Bound single-lens shader output

`lib/assets/shaders/liquid_glass.frag` returns transparent pixels outside the
lens's output box before evaluating its shape, normals, refraction, lights and
texture samples. A derivative guard includes the antialiasing band and expands
under inverse ancestor transforms, preserving rounded, continuous, squircle,
scaled, rotated and flex-deformed edges.

The material equations, backdrop coordinate mapping, sampling, public widgets,
gestures, blender and morph APIs are unchanged. No screen captures, frame-rate
limiter, lower-resolution glass or static backdrop is introduced.

Native pixel validation lives in the host app at
`integration_test/easy_glass_pixels_test.dart`. Profile timing comparisons use
identical scenes and settings. Record device/GPU identity with timings;
emulator results do not establish physical-device FPS.

The vendored pubspec omits the pub.dev screenshot entry because the publishing
thumbnail is not included in the app's source distribution.

## Physically rounded menu morphs

The opt-in `LiquidGlassLens.physicalOptics` keeps a host-clipped rounded plate's
radius, refraction width and Gaussian blur in screen units under positive,
axis-aligned ancestor scales. Foreground layout remains host-owned. Normal
lenses, rotations and existing callers keep the upstream local-space contract.
This preserves the app's circular menu origin without relaying out its labels.
