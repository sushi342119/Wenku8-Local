import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/local_scan_follow_up.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalPlatform.channel, null);
  });

  test('权限查询失败时读写都按未确认处理，不默认读为 true', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      if (call.method == 'queryTreePermission') {
        throw PlatformException(code: 'unavailable');
      }
      throw UnimplementedError(call.method);
    });
    final permission =
        await LocalPlatform.queryTreePermission('content://p/tree/a');
    expect(permission.persistedRead, isFalse);
    expect(permission.persistedWrite, isFalse);
    // 重授权流程会因读权限未确认而拒绝，不会走到扫描与删除。
    await expectLater(
      finishLocalReauthorization(
        previousFolder: 'old',
        pickedFolder: 'new',
        permission: permission,
        scanAndApply: () async => fail('权限未确认时不应扫描'),
      ),
      throwsStateError,
    );
  });

  test('权限查询成功时按原生返回值解析', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      return {'persistedRead': true, 'persistedWrite': false};
    });
    final permission =
        await LocalPlatform.queryTreePermission('content://p/tree/a');
    expect(permission.persistedRead, isTrue);
    expect(permission.persistedWrite, isFalse);
  });
}
