import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:wenku8_flutter/book_tags.dart';

/// 写任何 *_quarantine_v1 键时模拟平台写入失败（setValue 返回 false），
/// 其余读写走内存实现。脚手架复用仓库已有模式
///（local_library_performance_test.dart 的 _Preferences）。
class _QuarantineWriteFailingStore extends InMemorySharedPreferencesStore {
  _QuarantineWriteFailingStore() : super.empty();

  final List<String> rejectedKeys = <String>[];

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.endsWith('_quarantine_v1')) {
      rejectedKeys.add(key);
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('标签已损坏且隔离归档写入失败时，TagStore.load() 仍完成且 store 可用',
      () async {
    final fakeStore = _QuarantineWriteFailingStore();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = fakeStore;
    final prefs = await SharedPreferences.getInstance();
    // 非法 JSON：解码进入 catch，damaged = true，走归档分支。
    await prefs.setString('book_tags', 'not json{');
    await prefs.setString('book_tag_map', 'not json{');

    await TagStore.load();

    // 证明两个 key 都真实走了 damaged → 归档分支，
    // 且第一个归档失败后继续处理了第二个 key（测试不是空跑通过）。
    // 注意：平台层键带 flutter. 前缀（旧版 SharedPreferences API 在调用平台时加前缀，
    // prefs 侧读写时自动剥离，见 batch_b_recovery_test 的 getStringList 断言）。
    expect(
      fakeStore.rejectedKeys,
      containsAll(<String>[
        'flutter.book_tags_quarantine_v1',
        'flutter.book_tag_map_quarantine_v1',
      ]),
    );

    // _rebuildIndexes() 已执行、_shared 已赋值、store 可用。
    expect(() => TagStore.shared.tagsForBook(1), returnsNormally);
    expect(() => TagStore.shared.exportTagRecords(), returnsNormally);
  });
}
