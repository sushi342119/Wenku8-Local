import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyu/reader_purification.dart';
import 'package:shuyu/reading_activity.dart';

void main() {
  test('ReaderPurificationRule applies literal and regex rules safely', () {
    const literalRule = ReaderPurificationRule(
      id: 'r1',
      name: 'Literal',
      pattern: '亚丝娜',
      replacement: '结城明日奈',
      enabled: true,
    );
    expect(literalRule.apply('桐人与亚丝娜'), '桐人与结城明日奈');

    const regexRule = ReaderPurificationRule(
      id: 'r2',
      name: 'Regex',
      pattern: r'\.{3,}',
      replacement: '……',
      isRegex: true,
      enabled: true,
    );
    expect(regexRule.apply('“为什么......”'), '“为什么……”');

    const invalidRegex = ReaderPurificationRule(
      id: 'r3',
      name: 'Invalid Regex',
      pattern: '[unclosed',
      replacement: 'x',
      isRegex: true,
      enabled: true,
    );
    expect(invalidRegex.apply('safe text'), 'safe text');
  });

  test('ReaderPurificationStore persists rules and skips illustrations', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ReaderPurificationStore.shared;
    await store.ensureLoaded();
    await store.addCustomRule(
      name: 'Fix name',
      pattern: 'Foo',
      replacement: 'Bar',
      isRegex: false,
    );
    expect(store.purifyParagraph('Hello Foo!'), 'Hello Bar!');
    expect(store.purifyParagraph('[插图]'), '[插图]');
    expect(
      store.purifyParagraph('https://pic.wenku8.com/pictures/1/1.jpg'),
      'https://pic.wenku8.com/pictures/1/1.jpg',
    );
  });

  test('ReadingActivitySession records foreground reading intervals', () async {
    final store = ReadingActivityStore();
    var currentNow = DateTime(2026, 11, 4, 10, 0, 0);
    var currentElapsed = Duration.zero;
    final session = ReadingActivitySession(
      store: store,
      bookId: 1001,
      now: () => currentNow,
      elapsed: () => currentElapsed,
    );
    session.setActive(true);
    currentElapsed = const Duration(seconds: 45);
    currentNow = currentNow.add(currentElapsed);
    session.setActive(false);
    session.dispose();
    expect(store.totalSeconds, 45);
    expect(store.daysForBook(1001).single.seconds, 45);
  });
}
