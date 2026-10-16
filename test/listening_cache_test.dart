import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/listening/cache.dart';
import 'package:wenku8_flutter/listening/edge_tts.dart';
import 'package:wenku8_flutter/listening/models.dart';

class _EdgeFixture extends EdgeSpeechClient {
  int calls = 0;
  final texts = <String>[];
  Completer<void>? gate;
  @override
  Future<Uint8List> synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) async {
    calls++;
    texts.add(text);
    final pending = gate;
    if (pending != null) await pending.future;
    cancellation.check();
    return Uint8List(300)..[0] = 255;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _EdgeFixture edge;
  late SpeechAudioCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wenku-speech-test-');
    edge = _EdgeFixture();
    cache = SpeechAudioCache(directory, edge);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SpeechAudioCache.system, null);
    await directory.delete(recursive: true);
  });
  const segment = SpeechSegment(0, 0, 2, '中文');
  test('same phrase is deduplicated, atomically cached and reused', () async {
    final token = SpeechCancellation();
    final files = await Future.wait([
      cache.prepare(segment, defaultEdgeVoice, token),
      cache.prepare(segment, defaultEdgeVoice, token),
    ]);
    expect(edge.calls, 1);
    expect(files.first.path, files.last.path);
    await cache.prepare(segment, defaultEdgeVoice, SpeechCancellation());
    expect(edge.calls, 1);
    expect(
      await directory
          .list()
          .where((file) => file.path.endsWith('.part'))
          .isEmpty,
      true,
    );
  });
  test(
    'synthesis sanitizes both sources and rejects symbol-only input before transport',
    () async {
      final raw = SpeechSegment(0, 0, 5, '甲\uFFFF\u200B乙');
      await cache.prepare(raw, defaultEdgeVoice, SpeechCancellation());
      expect(edge.texts.single, '甲  乙');
      await expectLater(
        cache.prepare(
          const SpeechSegment(1, 0, 4, '……🌙'),
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
      expect(edge.calls, 1);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SpeechAudioCache.system, (call) async {
            final args = call.arguments as Map;
            expect(args['text'], '甲  乙');
            await File(args['path']).writeAsBytes(Uint8List(300));
            return args['path'];
          });
      const voice = SpeechVoice(
        id: 'local',
        label: 'System',
        source: ListeningSource.system,
        engine: 'org.example.tts',
        offline: true,
      );
      await cache.prepare(raw, voice, SpeechCancellation());
    },
  );
  test(
    'native input errors and deadlines are recoverable; engine failures are not',
    () async {
      const voice = SpeechVoice(
        id: 'local',
        label: 'System',
        source: ListeningSource.system,
        engine: 'org.example.tts',
        offline: true,
      );
      for (final entry in {
        'TTS_CONTENT': SpeechFailureKind.content,
        'TTS_TIMEOUT': SpeechFailureKind.timeout,
        'TTS_OFFLINE': SpeechFailureKind.unavailable,
        'TTS_SYNTH': SpeechFailureKind.unavailable,
      }.entries) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SpeechAudioCache.system, (call) async {
              await File(
                (call.arguments as Map)['path'],
              ).writeAsBytes(Uint8List(120));
              throw PlatformException(code: entry.key, message: '测试失败');
            });
        await expectLater(
          cache.prepare(segment, voice, SpeechCancellation()),
          throwsA(
            isA<SpeechFailure>().having(
              (error) => error.kind,
              'kind',
              entry.value,
            ),
          ),
        );
        expect(await directory.list().isEmpty, true);
      }
    },
  );
  test(
    'invalid audio is regenerated while protected clips remain untouched',
    () async {
      final file = await cache.prepare(
        segment,
        defaultEdgeVoice,
        SpeechCancellation(),
      );
      cache.protect(file);
      await cache.invalidate(file);
      expect(await file.exists(), true);
      cache.unprotect(file);
      await cache.invalidate(file);
      expect(await file.exists(), false);
      await cache.prepare(segment, defaultEdgeVoice, SpeechCancellation());
      expect(edge.calls, 2);
    },
  );
  test(
    'cancelled waiter does not wait for an older pending cache request',
    () async {
      final gate = edge.gate = Completer<void>();
      final old = cache.prepare(
        segment,
        defaultEdgeVoice,
        SpeechCancellation(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final token = SpeechCancellation();
      final fresh = cache.prepare(segment, defaultEdgeVoice, token);
      final rejected = expectLater(fresh, throwsA(isA<SpeechCancelled>()));
      token.cancel();
      await rejected.timeout(const Duration(seconds: 1));
      gate.complete();
      await old;
      expect(edge.calls, 1);
    },
  );
  test(
    'a new request retries after previous cancellation, leaving no partial file',
    () async {
      final oldToken = SpeechCancellation(),
          gate = edge.gate = Completer<void>();
      final old = cache.prepare(segment, defaultEdgeVoice, oldToken);
      final rejected = expectLater(old, throwsA(isA<SpeechCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      oldToken.cancel();
      final fresh = cache.prepare(
        segment,
        defaultEdgeVoice,
        SpeechCancellation(),
      );
      edge.gate = null;
      gate.complete();
      await rejected;
      expect(await (await fresh).exists(), true);
      expect(edge.calls, 2);
    },
  );
  test(
    'offline catalog rejects network voices, missing data and non-Chinese voices',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SpeechAudioCache.system, (call) async {
            if (call.method == 'engines') {
              return [
                {'id': 'org.example.tts'},
              ];
            }
            if (call.method == 'voices') {
              return [
                {
                  'id': 'local',
                  'locale': 'zh-CN',
                  'networkRequired': false,
                  'quality': 400,
                  'features': [],
                },
                {
                  'id': 'online',
                  'locale': 'zh-CN',
                  'networkRequired': true,
                  'features': [],
                },
                {
                  'id': 'english',
                  'locale': 'en-US',
                  'networkRequired': false,
                  'features': [],
                },
                {
                  'id': 'missing',
                  'locale': 'zh-CN',
                  'networkRequired': false,
                  'features': ['notInstalled'],
                },
              ];
            }
            return null;
          });
      final voices = await cache.offlineVoices();
      expect(voices.single.id, 'local');
      expect(voices.single.engine, 'org.example.tts');
    },
  );
  test(
    'system synthesis uses only native channel and retains engine-specific cache',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SpeechAudioCache.system, (call) async {
            expect(call.method, 'synthesize');
            final arguments = call.arguments as Map;
            expect(arguments['engine'], 'org.example.tts');
            expect(arguments['requestId'], matches(RegExp(r'^[a-f0-9]{32}$')));
            calls++;
            await File(arguments['path']).writeAsBytes(Uint8List(300));
            return arguments['path'];
          });
      const voice = SpeechVoice(
        id: 'local',
        label: 'System',
        engine: 'org.example.tts',
        source: ListeningSource.system,
        offline: true,
      );
      final file = await cache.prepare(segment, voice, SpeechCancellation());
      expect(file.path.endsWith('.wav'), true);
      await cache.prepare(segment, voice, SpeechCancellation());
      expect(calls, 1);
      expect(edge.calls, 0);
    },
  );
  test(
    'retired vendor engines are neither queried nor synthesized, including cached audio',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SpeechAudioCache.system, (call) async {
            if (call.method == 'engines') {
              return [
                {'id': 'com.oplus.ttsaccessibilityengine'},
                {'id': 'com.oppo.tts'},
                {'id': 'com.heytap.speech'},
              ];
            }
            fail('A retired engine must never be invoked');
          });
      final voices = await cache.offlineVoices();
      expect(voices, isEmpty);
      const voice = SpeechVoice(
        id: 'old',
        label: 'old',
        engine: 'com.oplus.ttsaccessibilityengine',
        source: ListeningSource.system,
        offline: true,
      );
      await File(
        '${directory.path}/${segment.key(voice)}.wav',
      ).writeAsBytes(Uint8List(300));
      await expectLater(
        cache.prepare(segment, voice, SpeechCancellation()),
        throwsA(isA<SpeechFailure>()),
      );
    },
  );
  test(
    'LRU is bounded and does not delete the protected playing file',
    () async {
      final files = [
        for (var i = 0; i < 3; i++) File('${directory.path}/$i.mp3'),
      ];
      for (var i = 0; i < files.length; i++) {
        final handle = await files[i].open(mode: FileMode.write);
        await handle.truncate(49 * 1024 * 1024);
        await handle.close();
        await files[i].setLastModified(DateTime.utc(2020, 1, i + 1));
      }
      cache.protect(files.first);
      await cache.trim();
      expect(await files.first.exists(), true);
      expect(await files[1].exists(), false);
      expect(await files[2].exists(), false);
    },
  );
}
