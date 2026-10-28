import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(LocalPlatform.channel, null),
  );

  testWidgets('unanswered directory and source calls end with a timeout', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      LocalPlatform.channel,
      (_) => Completer<Object?>().future,
    );
    final checks = [
      expectLater(
        LocalPlatform.scanLocalFolder('content://test/tree'),
        throwsA(isA<TimeoutException>()),
      ),
      expectLater(
        LocalPlatform.readLocalText('content://test/book'),
        throwsA(isA<TimeoutException>()),
      ),
      expectLater(
        LocalPlatform.prepareLocalText('content://test/book'),
        throwsA(isA<TimeoutException>()),
      ),
      expectLater(
        LocalPlatform.prepareLocalTextSource('content://test/book'),
        throwsA(isA<TimeoutException>()),
      ),
      expectLater(
        LocalPlatform.fingerprintLocalText('content://test/book'),
        throwsA(isA<TimeoutException>()),
      ),
    ];
    await tester.pump(const Duration(seconds: 31));
    await Future.wait(checks);
  });
}
