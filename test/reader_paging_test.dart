import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyu/reader_paging.dart';
import 'package:shuyu/reader_preferences.dart';

void main() {
  const size = Size(400, 800);
  const left = Offset(40, 200), leftLow = Offset(40, 700);
  const centre = Offset(200, 400);
  const right = Offset(360, 200), rightLow = Offset(360, 700);

  test('tap paging off: every tap toggles controls', () {
    const prefs = ReaderPreferences();
    for (final p in [left, centre, right]) {
      expect(readerTapAction(p, size, prefs), ReaderTapAction.toggle);
    }
  });

  test('常规 layout: left previous, centre toggle, right next', () {
    const prefs = ReaderPreferences(tapPaging: true);
    expect(readerTapAction(left, size, prefs), ReaderTapAction.previous);
    expect(readerTapAction(centre, size, prefs), ReaderTapAction.toggle);
    expect(readerTapAction(right, size, prefs), ReaderTapAction.next);
  });

  test('右手 layout splits the right column', () {
    const prefs = ReaderPreferences(
      tapPaging: true,
      tapLayout: ReaderTapLayout.rightHand,
    );
    expect(readerTapAction(right, size, prefs), ReaderTapAction.previous);
    expect(readerTapAction(rightLow, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(left, size, prefs), ReaderTapAction.next);
  });

  test('左手 layout splits the left column', () {
    const prefs = ReaderPreferences(
      tapPaging: true,
      tapLayout: ReaderTapLayout.leftHand,
    );
    expect(readerTapAction(left, size, prefs), ReaderTapAction.previous);
    expect(readerTapAction(leftLow, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(right, size, prefs), ReaderTapAction.next);
  });

  test('both sides next', () {
    const prefs = ReaderPreferences(tapPaging: true, tapBothSidesNext: true);
    expect(readerTapAction(left, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(right, size, prefs), ReaderTapAction.next);
    expect(readerTapAction(centre, size, prefs), ReaderTapAction.toggle);
  });

  test('reader mode defaults stay on scroll and survive a round trip', () {
    const prefs = ReaderPreferences();
    expect(prefs.mode, ReaderMode.scroll);
    final paged = prefs.copyWith(mode: ReaderMode.vertical, tapPaging: true);
    final back = ReaderPreferences.fromJson(paged.toJson());
    expect(back.mode, ReaderMode.vertical);
    expect(back.tapPaging, isTrue);
  });
}
