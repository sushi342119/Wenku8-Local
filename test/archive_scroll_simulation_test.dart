import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/archive_scroll_simulation.dart';

ArchiveScrollSimulation _sim(
  double position,
  double velocity, [
  double pitch = 27,
]) => ArchiveScrollSimulation(
  position: position,
  velocity: velocity,
  pitch: pitch,
  tolerance: const Tolerance(distance: .3, velocity: 20),
);

void main() {
  test(
    'fast flicks coast farther than slow flicks without a three-book ceiling',
    () {
      final slow = _sim(0, 300);
      final fast = _sim(0, 1200);
      expect(fast.target, greaterThan(slow.target * 3));
      expect(fast.target / 27, greaterThan(3));
      expect(fast.coastDuration, greaterThan(slow.coastDuration));
      expect(fast.x(.15), greaterThan(fast.x(.05)));
      expect(fast.dx(.15), greaterThan(100));
    },
  );

  test('the momentum-to-detent handoff preserves position and velocity', () {
    for (final v in [-4000.0, -600.0, 600.0, 4000.0]) {
      final sim = _sim(7.25 * 27, v);
      final t = sim.coastDuration;
      expect(t, greaterThan(0));
      const dt = .000001;
      expect(sim.x(t - dt), closeTo(sim.x(t + dt), .001));
      expect(sim.dx(t - dt), closeTo(sim.dx(t + dt), .01));
      final derivative = (sim.x(t + dt) - sim.x(t - dt)) / (2 * dt);
      expect(derivative, closeTo(sim.dx(t), .01));
    }
  });

  test(
    'all loop offsets settle exactly, monotonically and without a reverse pulse',
    () {
      for (final pitch in [25.0, 27.0, 29.0]) {
        for (final lane in [-1000.99, -.5, 0.0, .49, 10.75, 10000.0]) {
          for (final speed in [50.0, 80.0, 300.0, 1800.0, 8000.0]) {
            for (final sign in [-1.0, 1.0]) {
              final v = speed * sign;
              final position = lane * pitch;
              final sim = _sim(position, v, pitch);
              expect(sim.x(0), closeTo(position, .000001));
              expect(sim.dx(0), closeTo(v, .000001));
              var previous = position;
              var previousSpeed = speed;
              for (var tick = 1; tick <= 720; tick++) {
                final time = tick / 240;
                final x = sim.x(time);
                expect((x - previous) * sign, greaterThanOrEqualTo(-.000001));
                expect(
                  sim.dx(time).abs(),
                  lessThanOrEqualTo(previousSpeed + .000001),
                );
                previous = x;
                previousSpeed = sim.dx(time).abs();
              }
              expect(sim.isDone(3), isTrue);
              expect(sim.x(3), sim.target);
              expect(
                sim.target / pitch,
                closeTo((sim.target / pitch).roundToDouble(), .000001),
              );
              expect(sim.dx(3), 0);
            }
          }
        }
      }
    },
  );

  test(
    'resting release gently chooses the nearest lane, including negative lanes',
    () {
      for (final lane in [-10.4, -.6, -.4, 0.0, .4, .6, 10.4]) {
        final sim = _sim(lane * 27, 0);
        expect(sim.target / 27, lane.roundToDouble());
        expect(sim.isDone(3), isTrue);
        expect(sim.x(3), sim.target);
        expect(sim.dx(3), 0);
      }
    },
  );
}
