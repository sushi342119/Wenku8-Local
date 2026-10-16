import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/listening/audio_output.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';

import 'support/listening_fixture.dart';

Novel speechBook(List<String> paragraphs, {String? nextChapter}) =>
    demoNovels.first.withChapters([
      NovelChapter('容错章节', paragraphs.join('\n\n')),
      if (nextChapter != null) NovelChapter('下一章', nextChapter),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ListeningController controller;
  late FakeListeningOutput output;
  late FakeSpeechAudio audio;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    output = FakeListeningOutput();
    audio = FakeSpeechAudio();
    controller = ListeningController(
      repository: const DemoNovelRepository(),
      audio: audio,
      store: ListeningStore(await SharedPreferences.getInstance()),
      outputFactory: (_) async => output,
    );
  });
  tearDown(() async {
    await controller.dispose();
  });
  Future<void> shortDeadlines() async {
    final store = controller.store;
    await controller.dispose();
    await output.dispose();
    output = FakeListeningOutput();
    controller = ListeningController(
      repository: const DemoNovelRepository(),
      audio: audio,
      store: store,
      outputFactory: (_) async => output,
      preparationTimeout: const Duration(milliseconds: 15),
      decoderTimeout: const Duration(milliseconds: 15),
    );
  }

  test(
    'online voices skip a rejected fragment and keep reading the next paragraph',
    () async {
      for (final voice in [defaultEdgeVoice, alternateEdgeVoice]) {
        await controller.setVoice(voice);
        audio.errorFor = (segment) => segment.paragraph == 0
            ? const SpeechFailure('此文字未合成', kind: SpeechFailureKind.content)
            : null;
        await controller.start(speechBook(['被拒绝的字。', '仍然可以继续读。']), chapter: 0);
        expect(controller.snapshot.value.phase, ListeningPhase.playing);
        expect(controller.snapshot.value.current!.paragraph, 1);
        expect(controller.snapshot.value.skippedSegments, 1);
        expect(controller.snapshot.value.error, isNull);
        expect(output.playing, true);
        await controller.saveCursor();
        expect(controller.savedCursor(1)!.paragraph, 1);
      }
    },
  );
  test(
    'symbol-only chapter inserts finish or advance without calling a speech engine',
    () async {
      await controller.start(
        speechBook(['……', '✨🌙'], nextChapter: '真正的正文。'),
        chapter: 0,
      );
      expect(controller.snapshot.value.chapter, 1);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(audio.prepared.every((segment) => segment.text == '真正的正文。'), true);
      final calls = audio.prepared.length;
      await controller.start(speechBook(['……', '✨🌙']), chapter: 0);
      expect(controller.snapshot.value.phase, ListeningPhase.completed);
      expect(audio.prepared.length, calls);
    },
  );
  test(
    'long rejected text is retried as shorter clauses without discarding the paragraph',
    () async {
      audio.errorFor = (segment) => segment.text.length > 100
          ? const SpeechFailure('长文本被拒绝', kind: SpeechFailureKind.content)
          : null;
      final book = speechBook(['${'甲乙，' * 65}结束。']);
      await controller.start(book, chapter: 0);
      final state = controller.snapshot.value;
      expect(state.phase, ListeningPhase.playing);
      expect(state.current!.text.length, lessThanOrEqualTo(84));
      expect(state.segments.length, greaterThan(1));
      expect(
        state.segments.map((part) => part.text).join(),
        book.chapters.first.content,
      );
      expect(state.skippedSegments, 0);
      output.complete();
      await listeningMicrotasks();
      final recovered = controller.snapshot.value.current!;
      await controller.seek(const Duration(seconds: 6));
      await controller.stop();
      await controller.start(book, chapter: 0, resume: true);
      expect(controller.snapshot.value.current!.start, recovered.start);
      expect(output.initialPosition.inSeconds, 6);
    },
  );
  test(
    'three consecutive rejected fragments pause visibly instead of skipping the whole book',
    () async {
      audio.errorFor = (segment) => segment.paragraph < 3
          ? const SpeechFailure('文字未合成', kind: SpeechFailureKind.content)
          : null;
      await controller.start(
        speechBook(['甲。', '乙。', '丙。', '可读段落。'], nextChapter: '下一章。'),
        chapter: 0,
      );
      expect(controller.snapshot.value.phase, ListeningPhase.failed);
      expect(controller.snapshot.value.current!.paragraph, 2);
      expect(controller.snapshot.value.skippedSegments, 2);
      expect(controller.snapshot.value.error, contains('连续三段'));
      expect(output.plays, 0);
      await controller.skipSegment();
      expect(controller.snapshot.value.current!.paragraph, 3);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
    },
  );
  test(
    'transport or missing-engine failures never automatically discard text',
    () async {
      audio.fail = true;
      await controller.start(demoNovels.first, chapter: 0);
      expect(controller.snapshot.value.phase, ListeningPhase.failed);
      expect(controller.snapshot.value.current!.paragraph, 0);
      expect(controller.snapshot.value.skippedSegments, 0);
      expect(audio.prepared.length, 1);
    },
  );
  test(
    'a vendor future that never completes is bounded and the next paragraph plays',
    () async {
      await shortDeadlines();
      final gate = Completer<void>();
      audio.gateFor = (segment) => segment.paragraph == 0 ? gate : null;
      await controller
          .start(speechBook(['阻塞文字。', '下一段正文。']), chapter: 0)
          .timeout(const Duration(seconds: 1));
      expect(controller.snapshot.value.current!.paragraph, 1);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(controller.snapshot.value.skippedSegments, 1);
      gate.complete();
      await listeningMicrotasks();
      expect(output.loaded.length, 1);
    },
  );
  test(
    'hung decoding is retried once and cannot hold the player command queue',
    () async {
      await shortDeadlines();
      final book = speechBook(['坏音频。', '正常音频。']);
      final badKey = speechSegments(['坏音频。']).first.key(defaultEdgeVoice);
      final hung = Completer<Duration?>();
      output.loadHook = (file, _) async => file.path.contains(badKey)
          ? hung.future
          : const Duration(seconds: 30);
      await controller
          .start(book, chapter: 0)
          .timeout(const Duration(seconds: 1));
      expect(controller.snapshot.value.current!.paragraph, 1);
      expect(
        output.loaded.where((file) => file.path.contains(badKey)).length,
        2,
      );
      expect(audio.invalidated.length, 2);
      expect(audio.protected.any((path) => path.contains(badKey)), false);
      expect(output.playing, true);
      hung.completeError(StateError('late decoder error'));
      await listeningMicrotasks();
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
    },
  );
  test(
    'a single decoder failure regenerates the clip before any skip',
    () async {
      var attempts = 0;
      output.loadHook = (file, _) async {
        if (attempts++ == 0) throw StateError('corrupt cache');
        return const Duration(seconds: 30);
      };
      await controller.start(demoNovels.first, chapter: 0);
      expect(audio.invalidated.length, 1);
      expect(output.loaded.length, 2);
      expect(controller.snapshot.value.current!.paragraph, 0);
      expect(controller.snapshot.value.skippedSegments, 0);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
    },
  );
  test(
    'failed final paragraph advances normally and still respects end-of-chapter sleep',
    () async {
      audio.errorFor = (segment) => segment.text == '失败。'
          ? const SpeechFailure('未合成', kind: SpeechFailureKind.content)
          : null;
      final book = speechBook(['成功。', '失败。'], nextChapter: '下一章正文。');
      await controller.start(book, chapter: 0);
      controller.setSleep(afterChapter: true);
      output.complete();
      await listeningMicrotasks();
      expect(controller.snapshot.value.chapter, 0);
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      expect(controller.snapshot.value.sleepAfterChapter, false);
      await controller.resume();
      await listeningMicrotasks();
      expect(controller.snapshot.value.chapter, 1);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
    },
  );
  test(
    'double-tapping the active paragraph toggles accurate pause without regenerating',
    () async {
      await controller.start(demoNovels.first, chapter: 0, paragraph: 2);
      await controller.seek(const Duration(seconds: 7));
      final prepared = audio.prepared.length, loaded = output.loaded.length;
      await controller.paragraphDoubleTap(novelId: 1, chapter: 0, paragraph: 2);
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      expect(output.playing, false);
      await controller.paragraphDoubleTap(novelId: 1, chapter: 0, paragraph: 2);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(output.playing, true);
      expect(controller.progress.value.position.inSeconds, 7);
      expect(output.loaded.length, loaded);
      expect(audio.prepared.length, prepared);
    },
  );
  test(
    'double-tapping another paragraph starts at its first phrase even while paused',
    () async {
      await controller.start(demoNovels.first, chapter: 0);
      await controller.pause();
      await controller.paragraphDoubleTap(novelId: 1, chapter: 0, paragraph: 3);
      expect(controller.snapshot.value.current!.paragraph, 3);
      expect(controller.snapshot.value.current!.start, 0);
      expect(output.initialPosition, Duration.zero);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      await controller.paragraphDoubleTap(novelId: 1, chapter: 1, paragraph: 1);
      expect(controller.snapshot.value.chapter, 1);
      expect(controller.snapshot.value.current!.paragraph, 1);
    },
  );
  test(
    'double-tapping another book or a stopped session has no playback side effect',
    () async {
      await controller.start(demoNovels.first, chapter: 0);
      await controller.paragraphDoubleTap(novelId: 2, chapter: 0, paragraph: 1);
      expect(controller.snapshot.value.current!.paragraph, 0);
      await controller.stop();
      final plays = output.plays;
      await controller.paragraphDoubleTap(novelId: 1, chapter: 0, paragraph: 1);
      expect(output.plays, plays);
      expect(controller.snapshot.value.phase, ListeningPhase.stopped);
    },
  );
  test(
    'a rapid second paragraph jump cancels synthesis without waiting for its result',
    () async {
      final gate = Completer<void>();
      audio.gateFor = (segment) => segment.paragraph == 1 ? gate : null;
      await controller.start(demoNovels.first, chapter: 0);
      final old = controller.paragraphDoubleTap(
        novelId: 1,
        chapter: 0,
        paragraph: 1,
      );
      await listeningMicrotasks();
      await controller.paragraphDoubleTap(novelId: 1, chapter: 0, paragraph: 3);
      await old.timeout(const Duration(seconds: 1));
      gate.complete();
      await listeningMicrotasks();
      expect(controller.snapshot.value.current!.paragraph, 3);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(output.loaded.length, 2);
    },
  );
  test(
    'rapid pause and resume serialize player commands so an old pause cannot win',
    () async {
      await controller.start(demoNovels.first, chapter: 0);
      final gate = output.pauseGate = Completer<void>();
      final paused = controller.paragraphDoubleTap(
        novelId: 1,
        chapter: 0,
        paragraph: 0,
      );
      await listeningMicrotasks();
      final resumed = controller.paragraphDoubleTap(
        novelId: 1,
        chapter: 0,
        paragraph: 0,
      );
      gate.complete();
      output.pauseGate = null;
      await Future.wait([paused, resumed]);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(output.playing, true);
      expect(output.loaded.length, 1);
    },
  );
  test(
    'a late play failure from the previous clip cannot stop the new paragraph',
    () async {
      final oldPlay = Completer<void>();
      output.playHook = () =>
          output.plays == 1 ? oldPlay.future : Future.value();
      await controller.start(demoNovels.first, chapter: 0);
      output.complete();
      await listeningMicrotasks();
      expect(controller.snapshot.value.current!.paragraph, 1);
      oldPlay.completeError(StateError('old clip interrupted'));
      await listeningMicrotasks();
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      expect(output.playing, true);
    },
  );
  test(
    'starts at reader paragraph, pauses accurately and saves independent cursor',
    () async {
      await controller.start(demoNovels.first, chapter: 0, paragraph: 2);
      expect(controller.snapshot.value.current!.paragraph, 2);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
      output.positionEvents.add(const Duration(seconds: 7));
      await controller.pause();
      expect(output.playing, false);
      expect(controller.savedCursor(1)!.positionMs, 7000);
      await controller.resume();
      expect(controller.progress.value.position.inSeconds, 7);
      expect(output.playing, true);
    },
  );
  test('pause while synthesis is pending prevents late auto-play', () async {
    audio.gate = Completer<void>();
    final starting = controller.start(demoNovels.first, chapter: 0);
    await listeningMicrotasks();
    await controller.pause();
    audio.gate!.complete();
    await starting;
    expect(controller.snapshot.value.phase, ListeningPhase.paused);
    expect(output.plays, 0);
  });
  test('stale book synthesis cannot replace a newer session', () async {
    final oldGate = audio.gate = Completer<void>();
    final old = controller.start(demoNovels.first, chapter: 0);
    await listeningMicrotasks();
    audio.gate = null;
    await controller.start(demoNovels[1], chapter: 0);
    final currentPath = output.loaded.last.path;
    oldGate.complete();
    await old;
    expect(controller.snapshot.value.novel!.id, 2);
    expect(output.loaded.last.path, currentPath);
    expect(output.loaded.length, 1);
  });
  test('completion advances paragraphs and then chapters once', () async {
    await controller.start(demoNovels.first, chapter: 0, paragraph: 4);
    output.complete();
    output.complete();
    await listeningMicrotasks();
    expect(controller.snapshot.value.chapter, 1);
    expect(controller.snapshot.value.segment, 0);
    expect(controller.snapshot.value.phase, ListeningPhase.playing);
  });
  test(
    'end-of-chapter sleep stops without advancing and clears deadline',
    () async {
      await controller.start(demoNovels.first, chapter: 0, paragraph: 4);
      controller.setSleep(duration: const Duration(minutes: 15));
      expect(controller.snapshot.value.sleepUntil, isNotNull);
      controller.setSleep(afterChapter: true);
      expect(controller.snapshot.value.sleepUntil, null);
      output.complete();
      await listeningMicrotasks();
      expect(controller.snapshot.value.chapter, 0);
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      expect(controller.snapshot.value.sleepAfterChapter, false);
      await controller.resume();
      await listeningMicrotasks();
      expect(controller.snapshot.value.chapter, 1);
      expect(controller.snapshot.value.phase, ListeningPhase.playing);
    },
  );
  test('short sleep timer pauses, stop cancels pending preparation', () async {
    await controller.start(demoNovels.first, chapter: 0);
    controller.setSleep(duration: const Duration(milliseconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.snapshot.value.phase, ListeningPhase.paused);
    audio.gate = Completer<void>();
    final start = controller.start(demoNovels[1], chapter: 0);
    await listeningMicrotasks();
    await controller.stop();
    audio.gate!.complete();
    await start;
    expect(controller.snapshot.value.phase, ListeningPhase.stopped);
    expect(audio.protected, isEmpty);
  });
  test('switching voice restarts current phrase and preserves pause', () async {
    await controller.start(demoNovels.first, chapter: 0, paragraph: 2);
    await controller.pause();
    await controller.setVoice(alternateEdgeVoice);
    expect(controller.snapshot.value.voice.id, alternateEdgeVoice.id);
    expect(controller.snapshot.value.current!.paragraph, 2);
    expect(controller.snapshot.value.phase, ListeningPhase.paused);
    expect(output.initialPosition, Duration.zero);
  });
  test(
    'failure can retry; position ticks never rebuild snapshot subscribers',
    () async {
      audio.fail = true;
      await controller.start(demoNovels.first, chapter: 0);
      expect(controller.snapshot.value.phase, ListeningPhase.failed);
      audio.fail = false;
      await controller.resume();
      var rebuilds = 0;
      controller.snapshot.addListener(() => rebuilds++);
      for (var i = 1; i < 20; i++) {
        output.positionEvents.add(Duration(milliseconds: i * 250));
      }
      expect(rebuilds, 0);
      expect(controller.progress.value.position.inMilliseconds, 4750);
    },
  );
  test('saved phrase hash controls precise seek when resuming', () async {
    await controller.start(demoNovels.first, chapter: 0, paragraph: 2);
    await controller.seek(const Duration(seconds: 6));
    await controller.stop();
    await controller.start(demoNovels.first, chapter: 0, resume: true);
    expect(output.initialPosition.inSeconds, 6);
    expect(controller.snapshot.value.current!.paragraph, 2);
    await controller.setSpeed(1.5);
    expect(output.speed, 1.5);
  });
  test(
    'offline is pending development and never calls a system engine',
    () async {
      await controller.refreshVoices(online: false);
      expect(controller.voices.value.offline, isEmpty);
      expect(controller.voices.value.message, contains('待开发'));
      final voice = (await audio.offlineVoices()).first;
      await expectLater(
        controller.setVoice(voice),
        throwsA(isA<SpeechFailure>()),
      );
      expect(controller.snapshot.value.voice.source, ListeningSource.edge);
    },
  );
  test(
    'media metadata switches voices even if clip durations are identical',
    () async {
      final handler = ListeningAudioHandler(controller);
      try {
        await controller.start(demoNovels.first, chapter: 0);
        expect(handler.mediaItem.value!.artist, defaultEdgeVoice.label);
        await controller.pause();
        await controller.setVoice(alternateEdgeVoice);
        expect(handler.mediaItem.value!.artist, alternateEdgeVoice.label);
        expect(handler.mediaItem.value!.duration, isNull);
      } finally {
        handler.close();
      }
    },
  );

  test(
    'chapter slider and media metadata stay continuous across decoder handoffs',
    () async {
      final handler = ListeningAudioHandler(controller);
      final metadata = <MediaItem?>[];
      final states = <PlaybackState>[];
      final mediaSubscription = handler.mediaItem.listen(metadata.add);
      final playbackSubscription = handler.playbackState.listen(states.add);
      try {
        await controller.start(speechBook(['甲甲。', '乙乙。', '丙丙。']), chapter: 0);
        await listeningMicrotasks();
        final key = handler.mediaItem.value!.id;
        final count = metadata.whereType<MediaItem>().length;
        output.positionEvents.add(const Duration(seconds: 30));
        final before = controller.chapterProgress.value.fraction;
        final stateCount = states.length;
        output.complete();
        await listeningMicrotasks();
        expect(controller.snapshot.value.segment, 1);
        expect(
          controller.chapterProgress.value.fraction,
          closeTo(before, .00001),
        );
        expect(
          controller.chapterProgress.value.position,
          const Duration(seconds: 30),
        );
        expect(handler.mediaItem.value!.id, key);
        expect(metadata.whereType<MediaItem>().length, count);
        expect(
          states
              .skip(stateCount)
              .any((s) => s.processingState == AudioProcessingState.buffering),
          false,
        );
        output.positionEvents.add(const Duration(seconds: 15));
        expect(controller.chapterProgress.value.fraction, closeTo(.5, .0001));
        expect(
          handler.playbackState.value.updatePosition,
          const Duration(seconds: 45),
        );
      } finally {
        handler.close();
        await mediaSubscription.cancel();
        await playbackSubscription.cancel();
      }
    },
  );

  test(
    'chapter seek lands within the target clip and keeps a paused session paused',
    () async {
      await controller.start(speechBook(['甲甲。', '乙乙。', '丙丙。']), chapter: 0);
      await controller.pause();
      await controller.seekChapterFraction(.5);
      expect(controller.snapshot.value.segment, 1);
      expect(controller.progress.value.position, const Duration(seconds: 15));
      expect(controller.chapterProgress.value.fraction, closeTo(.5, .00001));
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      expect(output.playing, false);
    },
  );

  test(
    'chapter seeking stays available during a stalled clip handoff',
    () async {
      final gate = Completer<void>();
      try {
        await controller.start(speechBook(['甲。', '乙。', '丙。']), chapter: 0);
        audio.gateFor = (segment) => segment.paragraph == 1 ? gate : null;
        output.complete();
        await listeningMicrotasks();
        expect(controller.snapshot.value.phase, ListeningPhase.preparing);
        await controller.seekChapterFraction(.9);
        expect(controller.snapshot.value.segment, 2);
        expect(controller.chapterProgress.value.fraction, closeTo(.9, .00001));
        expect(controller.progress.value.position.inSeconds, 21);
        expect(output.playing, true);
      } finally {
        gate.complete();
        await listeningMicrotasks();
      }
    },
  );

  test(
    'seeking a paused chapter to its end resumes into completion, not the last clip again',
    () async {
      await controller.start(speechBook(['甲。', '乙。']), chapter: 0);
      await controller.pause();
      await controller.seekChapterFraction(1);
      expect(controller.snapshot.value.segment, 1);
      expect(controller.progress.value.position, const Duration(seconds: 30));
      expect(controller.chapterProgress.value.fraction, 1);
      expect(controller.snapshot.value.phase, ListeningPhase.paused);
      await controller.resume();
      await listeningMicrotasks();
      expect(controller.snapshot.value.phase, ListeningPhase.completed);
    },
  );

  test(
    'real buffering is reported after grace, while pause remains immediate',
    () async {
      final handler = ListeningAudioHandler(
        controller,
        bufferingGrace: const Duration(milliseconds: 10),
      );
      final gate = Completer<void>();
      try {
        await controller.start(speechBook(['甲。', '乙。']), chapter: 0);
        audio.gateFor = (segment) => segment.paragraph == 1 ? gate : null;
        output.complete();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.buffering,
        );
        await handler.pause();
        expect(handler.playbackState.value.playing, false);
        gate.complete();
        await listeningMicrotasks();
        expect(handler.playbackState.value.playing, false);
        expect(controller.snapshot.value.phase, ListeningPhase.paused);
      } finally {
        if (!gate.isCompleted) gate.complete();
        handler.close();
      }
    },
  );

  test(
    'retired saved voices reset without playback and cannot be reselected',
    () async {
      const voice = SpeechVoice(
        id: 'old',
        label: 'old',
        engine: 'com.oplus.ttsaccessibilityengine',
        source: ListeningSource.system,
        offline: true,
      );
      await controller.store.preferences.setString(
        'listening.voice.v1',
        '{"id":"old","label":"old","engine":"com.oplus.ttsaccessibilityengine","source":"system","offline":true}',
      );
      expect(controller.store.voice.id, defaultEdgeVoice.id);
      await expectLater(
        controller.setVoice(voice),
        throwsA(isA<SpeechFailure>()),
      );
      expect(output.plays, 0);
    },
  );
}
