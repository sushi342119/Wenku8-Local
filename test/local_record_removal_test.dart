import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_record_removal.dart';
import 'package:wenku8_flutter/local_source_identity.dart';

class _Store {
  String? intent;
  Set<String> ignored = {};
  bool indexed = true;
  bool copyExists = true;
  bool failIndex = false;
  bool failIgnoredOnce = false;
  final events = <String>[];

  RecordRemovalJournal journal() => RecordRemovalJournal(
        readIntent: () => intent,
        writeIntent: (value) async {
          intent = value;
          if (value == null) {
            events.add('clear');
          } else {
            events.add(
              jsonDecode(value)['committed'] == true ? 'commit' : 'prepare',
            );
          }
        },
        readIgnored: () => Set<String>.of(ignored),
        writeIgnored: (value) async {
          ignored = Set<String>.of(value);
          events.add('ignore');
          if (failIgnoredOnce) {
            failIgnoredOnce = false;
            throw StateError('ignored write failed');
          }
        },
        finishRemoval: (id) async {
          expect(id, 7);
          copyExists = false;
          events.add('copy');
          if (failIndex) throw StateError('index write failed');
          indexed = false;
          events.add('index');
        },
      );
}

void main() {
  const path = '/data/app/novels/a.txt';

  test('旧记录仅移出后，appFolder 扫描键命中忽略名单', () async {
    final store = _Store();
    final oldSource = LocalSourceIdentity.forBook(
      sourceId: '',
      sourceKey: '',
      fileUri: path,
      folderUri: 'content://provider/tree/other',
    );
    await store.journal().remove(
          bookId: 7,
          ignoreKey: oldSource.ignoredKey,
        );
    expect(store.indexed, isFalse);
    expect(
      store.ignored.contains(
        LocalSourceIdentity.appFolder(path).ignoredKey,
      ),
      isTrue,
    );
    expect(store.events, [
      'prepare',
      'ignore',
      'commit',
      'copy',
      'index',
      'clear',
    ]);
  });

  test('提交前写忽略名单失败，书籍和原忽略名单都恢复', () async {
    final store = _Store()
      ..ignored = {'unrelated'}
      ..failIgnoredOnce = true;
    await expectLater(
      store.journal().remove(bookId: 7, ignoreKey: 'book-key'),
      throwsStateError,
    );
    expect(store.ignored, {'unrelated'});
    expect(store.indexed, isTrue);
    expect(store.copyExists, isTrue);
    expect(store.intent, isNull);
  });

  test('写忽略名单后、提交前中断，启动恢复执行回滚', () async {
    final store = _Store()
      ..ignored = {'unrelated', 'book-key'}
      ..intent = jsonEncode({
        'bookId': 7,
        'ignoreKey': 'book-key',
        'wasIgnored': false,
        'committed': false,
      });
    await store.journal().recover();
    expect(store.ignored, {'unrelated'});
    expect(store.indexed, isTrue);
    expect(store.copyExists, isTrue);
    expect(store.intent, isNull);
  });

  test('索引保存失败后，新实例恢复完成移除', () async {
    final store = _Store()..failIndex = true;
    await expectLater(
      store.journal().remove(bookId: 7, ignoreKey: 'book-key'),
      throwsA(isA<RecordRemovalPending>()),
    );
    expect(store.intent, isNotNull);
    expect(jsonDecode(store.intent!)['committed'], isTrue);
    expect(store.ignored, contains('book-key'));
    store.failIndex = false;
    await store.journal().recover();
    expect(store.indexed, isFalse);
    expect(store.copyExists, isFalse);
    expect(store.ignored, contains('book-key'));
    expect(store.intent, isNull);
  });

  test('索引已经保存但待办未清除，恢复可以重复执行', () async {
    final store = _Store()
      ..indexed = false
      ..copyExists = false
      ..ignored = {'book-key'}
      ..intent = jsonEncode({
        'bookId': 7,
        'ignoreKey': 'book-key',
        'wasIgnored': false,
        'committed': true,
      });
    await store.journal().recover();
    expect(store.indexed, isFalse);
    expect(store.ignored, contains('book-key'));
    expect(store.intent, isNull);
  });
}
