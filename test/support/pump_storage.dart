import 'package:flutter_test/flutter_test.dart';

/// Preferences can complete on the host event loop while widget callbacks use
/// the fake clock. Advance both until the operation actually finishes.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() complete,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (complete()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  throw TestFailure('Storage operation did not complete after pumping both clocks');
}

Future<T> pumpStorage<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  final future = operation();
  var completed = false;
  future.then<void>(
    (_) { completed = true; },
    onError: (Object error, StackTrace stack) { completed = true; },
  );
  await pumpUntil(tester, () => completed);
  return future;
}
