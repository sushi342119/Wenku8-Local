import 'dart:async';
import 'dart:io';

import 'package:wenku8_flutter/listening/cache.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/models.dart';

class FakeListeningOutput implements ListeningAudioOutput {
  final positionEvents = StreamController<Duration>.broadcast(sync: true);
  final completionEvents = StreamController<void>.broadcast(sync: true);
  final loaded = <File>[];
  Duration initialPosition = Duration.zero;
  double speed = 1;
  int plays = 0, pauses = 0, stops = 0;
  bool playing = false;
  Completer<void>? pauseGate;
  Future<Duration?> Function(File file, Duration position)? loadHook;
  Future<void> Function()? playHook;
  @override
  Stream<Duration> get positions => positionEvents.stream;
  @override
  Stream<void> get completions => completionEvents.stream;
  @override
  Future<Duration?> load(File file, Duration position) async {
    loaded.add(file);
    initialPosition = position;
    if (loadHook != null) return loadHook!(file, position);
    return const Duration(seconds: 30);
  }

  @override
  Future<void> play() async {
    plays++;
    playing = true;
    if (playHook != null) await playHook!();
  }

  @override
  Future<void> suspend() => pause();
  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    if (pauseGate != null) await pauseGate!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  Future<void> seek(Duration position) async {
    initialPosition = position;
    positionEvents.add(position);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  void complete() {
    playing = false;
    completionEvents.add(null);
  }

  @override
  Future<void> dispose() async {
    await positionEvents.close();
    await completionEvents.close();
  }
}

class FakeSpeechAudio implements SpeechAudioSource {
  Completer<void>? gate;
  bool fail = false;
  SpeechFailure? Function(SpeechSegment segment)? errorFor;
  Completer<void>? Function(SpeechSegment segment)? gateFor;
  final prepared = <SpeechSegment>[];
  final invalidated = <String>[];
  final protected = <String>{};
  @override
  Future<File> prepare(
    SpeechSegment segment,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) async {
    prepared.add(segment);
    final wait = gateFor?.call(segment) ?? gate;
    if (wait != null) await wait.future;
    cancellation.check();
    if (fail) throw const SpeechFailure('测试音源连接失败');
    final error = errorFor?.call(segment);
    if (error != null) throw error;
    return File('/speech-fixture/${segment.key(voice)}.mp3');
  }

  @override
  Future<List<SpeechVoice>> offlineVoices() async => const [
    SpeechVoice(
      id: 'zh-fixture',
      label: 'System 离线中文',
      engine: 'org.example.tts',
      source: ListeningSource.system,
      offline: true,
    ),
  ];
  @override
  Future<List<SpeechVoice>> onlineVoices() async => const [
    defaultEdgeVoice,
    alternateEdgeVoice,
  ];
  @override
  void protect(File file) => protected.add(file.path);
  @override
  void unprotect(File file) => protected.remove(file.path);
  @override
  Future<void> invalidate(File file) async => invalidated.add(file.path);
  @override
  Future<void> trim() async {}
}

Future<void> listeningMicrotasks() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
