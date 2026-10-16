import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/touch_sampling.dart';

void main() {
  test(
    'input alignment follows display cadence with a bounded negative offset',
    () {
      expect(touchSamplingOffset(120).inMicroseconds, -10333);
      expect(touchSamplingOffset(90).inMicroseconds, -13111);
      expect(touchSamplingOffset(60).inMicroseconds, -18667);
      expect(touchSamplingOffset(30).inMicroseconds, -20000);
      expect(touchSamplingOffset(1000).inMicroseconds, -6000);
      for (final rate in [0.0, -1.0, double.nan, double.infinity]) {
        expect(touchSamplingOffset(rate), touchSamplingOffset(60));
      }
    },
  );

  test(
    'irregular touch packets interpolate steadily on a 120Hz frame clock',
    () {
      // A deterministic sensor/delivery fixture, not a phone FPS measurement.
      final sampler = PointerEventResampler();
      sampler.addEvent(const PointerAddedEvent(device: 1));
      sampler.addEvent(const PointerDownEvent(device: 1, pointer: 1));
      var sensorUs = 0;
      var packet = 0;
      var delivered = 0.0;
      var sampled = 0.0;
      final rawSteps = <double>[];
      final alignedSteps = <double>[];
      var previousRaw = 0.0;
      var previousAligned = 0.0;
      const interval = 8333;
      final offset = touchSamplingOffset(120).inMicroseconds;
      for (var frame = 1; frame < 100; frame++) {
        final frameUs = frame * interval;
        while (sensorUs + const [3000, 6000, 5000, 7000][packet % 4] <=
            frameUs - 2000) {
          final nextUs = sensorUs + const [3000, 6000, 5000, 7000][packet % 4];
          delivered = nextUs / 1000;
          sampler.addEvent(
            PointerMoveEvent(
              device: 1,
              pointer: 1,
              timeStamp: Duration(microseconds: nextUs),
              position: Offset(delivered, 0),
              delta: Offset((nextUs - sensorUs) / 1000, 0),
            ),
          );
          sensorUs = nextUs;
          packet++;
        }
        final time = Duration(microseconds: frameUs + offset);
        sampler.sample(time, time + const Duration(microseconds: interval), (
          event,
        ) {
          if (event is PointerMoveEvent) sampled = event.position.dx;
        });
        if (frame > 6) {
          rawSteps.add(delivered - previousRaw);
          alignedSteps.add(sampled - previousAligned);
        }
        previousRaw = delivered;
        previousAligned = sampled;
      }
      double rms(List<double> values) => math.sqrt(
        values.fold(
              0.0,
              (sum, step) => sum + math.pow(step - interval / 1000, 2),
            ) /
            values.length,
      );
      expect(rms(rawSteps), greaterThan(1));
      expect(rms(alignedSteps), lessThan(.0001));
      sampler.addEvent(
        PointerCancelEvent(
          device: 1,
          pointer: 1,
          timeStamp: const Duration(seconds: 1),
        ),
      );
      sampler.stop((_) {});
      expect(sampler.hasPendingEvents, isFalse);
    },
  );

  testWidgets(
    'Android policy enables resampling without the SDK -38ms offset',
    (tester) async {
      final binding = tester.binding;
      final oldEnabled = binding.resamplingEnabled;
      final oldOffset = binding.samplingOffset;
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final policy = TouchSamplingPolicy(
        binding,
        platform: TargetPlatform.android,
      );
      expect(binding.resamplingEnabled, isTrue);
      expect(binding.samplingOffset, touchSamplingOffset(120));
      policy.dispose();
      expect(binding.resamplingEnabled, oldEnabled);
      expect(binding.samplingOffset, oldOffset);
    },
  );

  testWidgets('refresh changes wait for all contacts, including cancellation', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final policy = TouchSamplingPolicy(
      tester.binding,
      platform: TargetPlatform.android,
    );
    addTearDown(policy.dispose);
    tester.binding.pointerRouter.route(const PointerDownEvent(pointer: 1));
    tester.binding.pointerRouter.route(const PointerDownEvent(pointer: 2));
    tester.view.display.refreshRate = 60;
    policy.didChangeMetrics();
    expect(tester.binding.samplingOffset, touchSamplingOffset(120));
    tester.binding.pointerRouter.route(const PointerUpEvent(pointer: 1));
    expect(tester.binding.samplingOffset, touchSamplingOffset(120));
    tester.binding.pointerRouter.route(const PointerCancelEvent(pointer: 2));
    expect(tester.binding.samplingOffset, touchSamplingOffset(60));
  });

  testWidgets('suspending contact does not pin the old cadence after resume', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final policy = TouchSamplingPolicy(
      tester.binding,
      platform: TargetPlatform.android,
    );
    addTearDown(policy.dispose);
    tester.binding.pointerRouter.route(const PointerDownEvent(pointer: 1));
    tester.view.display.refreshRate = 60;
    policy.didChangeMetrics();
    expect(tester.binding.samplingOffset, touchSamplingOffset(120));
    policy.didChangeAppLifecycleState(AppLifecycleState.paused);
    policy.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(tester.binding.samplingOffset, touchSamplingOffset(60));
  });

  testWidgets(
    'desktop and explicitly disabled policies leave input untouched',
    (tester) async {
      final oldEnabled = tester.binding.resamplingEnabled;
      final oldOffset = tester.binding.samplingOffset;
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.iOS,
      ]) {
        final policy = TouchSamplingPolicy(tester.binding, platform: platform);
        expect(tester.binding.resamplingEnabled, oldEnabled);
        expect(tester.binding.samplingOffset, oldOffset);
        policy.dispose();
      }
      final policy = TouchSamplingPolicy(
        tester.binding,
        platform: TargetPlatform.android,
        enabled: false,
      );
      expect(tester.binding.resamplingEnabled, oldEnabled);
      expect(tester.binding.samplingOffset, oldOffset);
      policy.dispose();
    },
  );
}
