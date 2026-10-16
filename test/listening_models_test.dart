import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/listening/edge_tts.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('segments preserve reader offsets and skip illustrations', () {
    final text = '　序章。${'慢慢翻开书页，' * 70}🌙晚安。';
    final segments = speechSegments([
      text,
      '<!--image-->https://img.wenku8.com/a.jpg<!--image-->',
      '',
      '下一段。',
    ]);
    expect(segments.any((s) => s.paragraph == 1 || s.paragraph == 2), false);
    expect(segments.last.paragraph, 3);
    for (final segment in segments.where((s) => s.paragraph == 0)) {
      expect(segment.text, text.substring(segment.start, segment.end));
      expect(utf8.encode(segment.text), isNotEmpty);
      expect(segment.text.runes.any((r) => r >= 0xD800 && r <= 0xDFFF), false);
      expect(segment.text.length, lessThanOrEqualTo(244));
    }
    expect(segments.first.start, 1);
    expect(
      speechSegments([
        '[插图]',
        '<!--image-->https://invalid.example/cover.jpg<!--image-->',
      ]),
      isEmpty,
    );
  });
  test('paragraph speech removes controls without moving offsets', () {
    final segment = speechSegments(['甲\x01乙']).single;
    expect(segment.text, '甲 乙');
    expect(segment.end, 3);
    expect(() => speechSegments(['x'], maximum: 1), throwsArgumentError);
  });
  test(
    'punctuation, emoji and invisible-only paragraphs are not synthesized',
    () {
      final segments = speechSegments([
        '……？！——',
        '🌙✨',
        '\u200B\uFEFF',
        '正文。',
        '１２３',
        '𠀀',
      ]);
      expect(segments.map((part) => part.paragraph), [3, 4, 5]);
      expect(segments.last.text, '𠀀');
    },
  );
  test(
    'invalid XML scalars and isolated surrogates are replaced at the same offsets',
    () {
      final original = String.fromCharCodes([
        0x7532,
        0xD800,
        0x4E59,
        0xFFFF,
        0x200B,
        0xFEFF,
        0x10FFFF,
        0x4E19,
      ]);
      final segment = speechSegments([original]).single;
      expect(segment.text, '甲 乙     丙');
      expect(segment.text.length, original.length);
      expect(segment.start, 0);
      expect(segment.end, original.length);
      expect(speechText('名字🌙与𠀀。'), '名字🌙与𠀀。');
    },
  );
  test(
    'shorter recovery clauses keep paragraph and original UTF-16 offsets',
    () {
      final text = '${'甲乙，' * 65}𠀀结尾。';
      final original = SpeechSegment(7, 25, 25 + text.length, text);
      final parts = speechRecoverySegments(original);
      expect(parts.length, greaterThan(1));
      expect(parts.map((part) => part.text).join(), text);
      for (final part in parts) {
        expect(part.paragraph, 7);
        expect(part.text, text.substring(part.start - 25, part.end - 25));
        expect(part.text.length, lessThanOrEqualTo(84));
      }
      expect(speechRecoverySegments(parts.first).length, 1);
    },
  );
  test('ISO Chinese aliases normalize without vendor-specific aliases', () {
    for (final locale in ['chi', 'zho', 'zh', 'ZH']) {
      expect(chineseSpeechLocale(locale), 'zh-CN');
    }
    expect(chineseSpeechLocale('ZH_tw'), 'zh-TW');
    expect(chineseSpeechLocale('zh-hant-hk'), 'zh-Hant-HK');
    for (final locale in [
      'chn',
      'CHN',
      'usa',
      'en-US',
      'ja-JP',
      '',
      'zh--CN',
    ]) {
      expect(chineseSpeechLocale(locale), isNull);
    }
  });
  test('long clauses prefer punctuation and do not cut numeric commas', () {
    final text = '${'甲' * 12}，${'乙' * 30}';
    final segments = speechSegments([text], maximum: 20);
    expect(segments.first.end, 13);
    expect(segments.first.text.endsWith('，'), true);
    expect(segments.map((s) => s.text).join(), text);
    for (final segment in segments) {
      expect(segment.text, text.substring(segment.start, segment.end));
    }
    final number = '${'甲' * 12}1,000${'乙' * 30}';
    final numbered = speechSegments([number], maximum: 20);
    expect(numbered.first.end, 20);
    expect(numbered.first.text.endsWith('1,'), false);
  });
  test('English word boundaries are preferred over mid-word restarts', () {
    const text = 'The light moved past the old window into the silent room.';
    final segments = speechSegments([text], maximum: 20);
    for (final segment in segments.take(segments.length - 1)) {
      expect(segment.text.endsWith(' '), true);
      expect(segment.text, text.substring(segment.start, segment.end));
    }
  });
  test('different engines and voices never share a cache key', () {
    const segment = SpeechSegment(0, 0, 1, '字');
    const local = SpeechVoice(
      id: 'voice',
      label: 'System',
      source: ListeningSource.system,
      engine: 'org.example.tts',
      offline: true,
    );
    expect(
      segment.key(defaultEdgeVoice),
      isNot(segment.key(alternateEdgeVoice)),
    );
    expect(segment.key(local), isNot(segment.key(defaultEdgeVoice)));
    expect(local.supported, true);
    expect(SpeechVoice.fromJson(local.toJson()).engine, local.engine);
  });
  test('Edge rejects unreadable input before opening a connection', () async {
    await expectLater(
      EdgeSpeechClient().synthesize(
        '……\uFFFF🌙',
        defaultEdgeVoice,
        SpeechCancellation(),
      ),
      throwsA(
        isA<SpeechFailure>().having(
          (error) => error.kind,
          'kind',
          SpeechFailureKind.content,
        ),
      ),
    );
    const invalid = SpeechVoice(
      id: 'invalid-voice',
      label: 'invalid',
      source: ListeningSource.edge,
    );
    await expectLater(
      EdgeSpeechClient().synthesize('正文。', invalid, SpeechCancellation()),
      throwsA(
        isA<SpeechFailure>().having(
          (error) => error.kind,
          'kind',
          SpeechFailureKind.unavailable,
        ),
      ),
    );
  });
  test('cancellation is idempotent and completed callbacks can be removed', () {
    final token = SpeechCancellation();
    var calls = 0;
    final remove = token.onCancel(() => calls++);
    remove();
    token.cancel();
    token.cancel();
    expect(calls, 0);
    token.onCancel(() => calls++);
    expect(calls, 1);
    expect(token.check, throwsA(isA<SpeechCancelled>()));
  });
  test(
    'cancellation releases a stuck future and consumes late errors',
    () async {
      final token = SpeechCancellation(), pending = Completer<int>();
      final waiting = token.wait(pending.future);
      final rejected = expectLater(waiting, throwsA(isA<SpeechCancelled>()));
      token.cancel();
      await rejected.timeout(const Duration(seconds: 1));
      pending.completeError(StateError('late vendor failure'));
      await Future<void>.delayed(Duration.zero);
    },
  );
  test(
    'Edge proof is stable inside five-minute interval; framing is bounded',
    () {
      final time = DateTime.utc(2026, 10, 8, 2, 1);
      expect(
        EdgeSpeechClient.timeProof(time),
        EdgeSpeechClient.timeProof(time.add(const Duration(minutes: 1))),
      );
      expect(
        EdgeSpeechClient.timeProof(time),
        matches(RegExp(r'^[A-F0-9]{16}-[A-F0-9]{64}$')),
      );
      expect(
        EdgeSpeechClient.timeProof(time),
        isNot(EdgeSpeechClient.timeProof(time.add(const Duration(minutes: 5)))),
      );
      expect(EdgeSpeechClient.escapeXml('<&"\'>'), '&lt;&amp;&quot;&apos;&gt;');
      final header = utf8.encode('Path:audio\r\nContent-Type:audio/mpeg\r\n');
      final frame = EdgeSpeechClient.binaryAudio([
        header.length >> 8,
        header.length & 255,
        ...header,
        1,
        2,
        3,
      ]);
      expect(frame.path, 'audio');
      expect(frame.audio, [1, 2, 3]);
      expect(
        () => EdgeSpeechClient.binaryAudio([0, 100, 0]),
        throwsA(isA<SpeechFailure>()),
      );
    },
  );
  test(
    'speech preferences and cursor stay separate from reader settings',
    () async {
      SharedPreferences.setMockInitialValues({
        'fontSize': 21.0,
        'listening.voice.v1': 'broken',
      });
      final preferences = await SharedPreferences.getInstance(),
          store = ListeningStore(await SharedPreferences.getInstance());
      expect(store.voice.id, defaultEdgeVoice.id);
      await Future.wait([
        store.saveSpeed(8),
        store.saveFollow(false),
        store.saveVoice(alternateEdgeVoice),
      ]);
      expect(store.speed, 2);
      expect(store.follow, false);
      expect(store.voice.id, alternateEdgeVoice.id);
      expect(preferences.getDouble('fontSize'), 21);
      const cursor = ListeningCursor(
        novelId: 1,
        chapterId: 77,
        chapter: 2,
        paragraph: 3,
        start: 20,
        positionMs: 4000,
        segmentHash: 'abc',
      );
      await store.saveCursor(cursor);
      expect(store.cursor(1)!.positionMs, 4000);
      expect(store.cursor(2), null);
      final damaged = ListeningCursor.fromJson({
        'chapter': -5,
        'paragraph': 'bad',
      });
      expect(damaged.chapter, 0);
      expect(damaged.paragraph, 0);
    },
  );
}
