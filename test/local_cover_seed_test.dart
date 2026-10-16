import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legacy_cover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local GPU fixture never invokes the original cover bridge', () async {
    var remoteCalls = 0;
    const channel = MethodChannel('org.mewx.wenku8/legacy_api');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          remoteCalls++;
          return Uint8List(0);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final source = Uint8List.fromList([1, 2, 3]);
    LegacyCover.seedLocalBytes(987654, source);
    source[0] = 9;
    expect(await LegacyCover.bytes(987654), [1, 2, 3]);
    expect(LegacyCover.peek(987654), [1, 2, 3]);
    expect(() => LegacyCover.peek(987654)![0] = 9, throwsUnsupportedError);
    expect(remoteCalls, 0);
    expect(() => LegacyCover.seedLocalBytes(0, source), throwsArgumentError);
    expect(
      () => LegacyCover.seedLocalBytes(987654, Uint8List(0)),
      throwsArgumentError,
    );
    expect(await LegacyCover.bytes(987654), [1, 2, 3]);
  });
}
