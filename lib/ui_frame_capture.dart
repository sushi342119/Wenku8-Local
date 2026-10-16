import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

enum FrameCapturePhase { idle, preparing, recording, draining, ready }

/// FrameTiming is build/raster-thread evidence, not actual presentation FPS.
class UiFrameReport {
  UiFrameReport({
    required this.label,
    required this.startedUs,
    required this.endedUs,
    required this.environment,
    required List<ui.FrameTiming> frames,
    this.truncated = false,
    this.source = 'supplied FrameTiming records',
  }) : frames = List.unmodifiable(
         frames.where((frame) {
           final wall = frame.timestampInMicroseconds(
             ui.FramePhase.rasterFinishWallTime,
           );
           return wall >= startedUs && wall <= endedUs;
         }),
       );

  final String label;
  final int startedUs;
  final int endedUs;
  final Map<String, Object?> environment;
  final List<ui.FrameTiming> frames;
  final bool truncated;
  final String source;
  static const budgetUs = 1000000 / 120;

  Map<String, Object?> get summary {
    final builds = frames
        .map((frame) => frame.buildDuration.inMicroseconds)
        .toList();
    final rasters = frames
        .map((frame) => frame.rasterDuration.inMicroseconds)
        .toList();
    final vsync =
        frames
            .map(
              (frame) =>
                  frame.timestampInMicroseconds(ui.FramePhase.vsyncStart),
            )
            .toSet()
            .toList()
          ..sort();
    final intervals = [
      for (var i = 1; i < vsync.length; i++) vsync[i] - vsync[i - 1],
    ];
    return {
      'schema_version': 1,
      'label': label,
      'source': source,
      'label_source': 'caller-selected scene; not gesture-classified',
      'meaning':
          'Build/raster duration and rendered-frame vsync intervals; NOT actual-present FPS or a 120fps certification',
      'window_start_wall_us': startedUs,
      'window_end_wall_us': endedUs,
      'environment': environment,
      'samples': frames.length,
      'status': frames.length < 120
          ? 'insufficient_samples'
          : truncated
          ? 'truncated'
          : 'recorded',
      'target_frame_budget_us': budgetUs,
      'build_median_us': percentile(builds, .5),
      'build_p95_us': percentile(builds, .95),
      'build_max_us': percentile(builds, 1),
      'raster_median_us': percentile(rasters, .5),
      'raster_p95_us': percentile(rasters, .95),
      'raster_max_us': percentile(rasters, 1),
      'build_over_budget': builds.where((value) => value > budgetUs).length,
      'raster_over_budget': rasters.where((value) => value > budgetUs).length,
      'vsync_interval_median_us': percentile(intervals, .5),
      'vsync_interval_p95_us': percentile(intervals, .95),
    };
  }

  String toJson() => const JsonEncoder.withIndent('  ').convert({
    ...summary,
    'export_mode': 'full_timings',
    'frames': [
      for (final frame in frames)
        {
          'wall_us': frame.timestampInMicroseconds(
            ui.FramePhase.rasterFinishWallTime,
          ),
          'vsync_us': frame.timestampInMicroseconds(ui.FramePhase.vsyncStart),
          'build_us': frame.buildDuration.inMicroseconds,
          'raster_us': frame.rasterDuration.inMicroseconds,
          'raster_finish_us': frame.timestampInMicroseconds(
            ui.FramePhase.rasterFinish,
          ),
          'total_us': frame.totalSpan.inMicroseconds,
        },
    ],
  });

  static int? percentile(List<int> values, double quantile) {
    if (values.isEmpty) return null;
    final sorted = List<int>.of(values)..sort();
    return sorted[((sorted.length - 1) * quantile).round()];
  }
}

/// Dormant until explicitly started. No per-frame UI/log updates, FPS ticker,
/// synthetic motion, network, theme notifications or rendering settings changes.
class UiFrameCapture extends ValueNotifier<FrameCapturePhase>
    with WidgetsBindingObserver {
  UiFrameCapture({WidgetsBinding? binding, DateTime Function()? now})
    : _binding = binding ?? WidgetsBinding.instance,
      _now = now ?? DateTime.now,
      super(FrameCapturePhase.idle);

  static final instance = UiFrameCapture();
  final WidgetsBinding _binding;
  final DateTime Function() _now;
  final _frames = <ui.FrameTiming>[];
  Timer? _timer;
  int? _startedUs;
  int? _endedUs;
  String _label = '';
  Map<String, Object?> _environment = const {};
  bool _attached = false;
  bool _truncated = false;
  UiFrameReport? report;
  bool get active =>
      value == FrameCapturePhase.preparing ||
      value == FrameCapturePhase.recording ||
      value == FrameCapturePhase.draining;

  bool start({
    required String label,
    required Map<String, Object?> environment,
  }) {
    if (active) return false;
    _label = label;
    _environment = Map.unmodifiable(environment);
    _frames.clear();
    _startedUs = _endedUs = null;
    _truncated = false;
    report = null;
    _binding.addObserver(this);
    _binding.addTimingsCallback(_onTimings);
    _attached = true;
    _timer = Timer(const Duration(seconds: 3), () {
      _startedUs = _now().microsecondsSinceEpoch;
      _timer = Timer(const Duration(seconds: 20), stop);
      value = FrameCapturePhase.recording;
    });
    value = FrameCapturePhase.preparing;
    return true;
  }

  void _onTimings(List<ui.FrameTiming> frames) {
    if (value != FrameCapturePhase.recording &&
        value != FrameCapturePhase.draining) {
      return;
    }
    final started = _startedUs;
    if (started == null) return;
    for (final frame in frames) {
      final wall = frame.timestampInMicroseconds(
        ui.FramePhase.rasterFinishWallTime,
      );
      if (wall < started || (_endedUs != null && wall > _endedUs!)) continue;
      if (_frames.length == 6000) {
        _truncated = true;
        break;
      }
      _frames.add(frame);
    }
  }

  void stop() {
    if (value == FrameCapturePhase.preparing) {
      cancel();
      return;
    }
    if (value != FrameCapturePhase.recording) return;
    _timer?.cancel();
    _endedUs = _now().microsecondsSinceEpoch;
    // Release/Profile timings arrive in batches. Drain then select the frame's
    // own wall time, so a late batch is not assigned to the next scene.
    _timer = Timer(const Duration(milliseconds: 1200), () {
      _detach();
      final environment = <String, Object?>{
        ..._environment,
        'timing_batch_drain_ms': 1200,
      };
      for (final view in _binding.platformDispatcher.views) {
        if (view.viewId != _environment['view_id']) continue;
        environment['refresh_hz_at_end'] = view.display.refreshRate;
        environment['physical_size_at_end'] = [
          view.physicalSize.width,
          view.physicalSize.height,
        ];
        break;
      }
      report = UiFrameReport(
        label: _label,
        startedUs: _startedUs!,
        endedUs: _endedUs!,
        environment: Map.unmodifiable(environment),
        frames: _frames,
        truncated: _truncated,
        source:
            'WidgetsBinding timing callback; user-triggered manual window; no injected gestures',
      );
      _frames.clear();
      value = FrameCapturePhase.ready;
    });
    value = FrameCapturePhase.draining;
  }

  void _detach() {
    _timer?.cancel();
    _timer = null;
    if (_attached) {
      _binding.removeTimingsCallback(_onTimings);
      _binding.removeObserver(this);
      _attached = false;
    }
  }

  void cancel() {
    _detach();
    _frames.clear();
    _startedUs = _endedUs = null;
    value = report == null ? FrameCapturePhase.idle : FrameCapturePhase.ready;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) stop();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
