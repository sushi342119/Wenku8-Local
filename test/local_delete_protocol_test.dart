import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/local-delete');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void respond(Map<String, Object?> response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'deleteLocalDocument');
      return response;
    });
  }

  test('provider 无法确认时抛 io_error', () async {
    respond({
      'deleted': false,
      'outcome': 'unconfirmed',
      'code': 'io_error',
    });
    await expectLater(
      deleteLocalDocumentWithChannel(channel, 'content://p/document/a'),
      throwsA(
        isA<LocalDeleteException>()
            .having((error) => error.code, 'code', 'io_error'),
      ),
    );
  });

  test('旧版 notFound:true 不再接受为成功，同样抛 io_error', () async {
    respond({'deleted': true, 'notFound': true});
    await expectLater(
      deleteLocalDocumentWithChannel(channel, 'content://p/document/a'),
      throwsA(
        isA<LocalDeleteException>()
            .having((error) => error.code, 'code', 'io_error'),
      ),
    );
  });

  test('旧版真实删除成功返回仍可接受', () async {
    respond({'deleted': true});
    await deleteLocalDocumentWithChannel(
      channel,
      'content://p/document/a',
    );
  });

  test('新版确认删除成功返回可接受', () async {
    respond({'deleted': true, 'outcome': 'deleted'});
    await deleteLocalDocumentWithChannel(
      channel,
      'content://p/document/a',
    );
  });

  test('provider 拒绝删除时抛 delete_rejected', () async {
    respond({'deleted': false, 'code': 'delete_rejected'});
    await expectLater(
      deleteLocalDocumentWithChannel(channel, 'content://p/document/a'),
      throwsA(
        isA<LocalDeleteException>()
            .having((error) => error.code, 'code', 'delete_rejected'),
      ),
    );
  });
}
