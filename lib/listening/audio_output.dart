import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'controller.dart';
import 'models.dart';

/// Both online MP3 and system-generated WAV use the same hardware audio player.
/// No TTS speak()/stop() simulation: pause and seek preserve the exact audio position.
class NativeListeningOutput implements ListeningAudioOutput {
  NativeListeningOutput(this.controller);
  final ListeningController controller;
  final _player = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );
  final _completed = StreamController<void>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  AudioSession? _session;
  int _playEpoch = 0;
  bool _sessionActive = false;

  Future<void> initialize() async {
    _session = await AudioSession.instance;
    await _session!.configure(const AudioSessionConfiguration.speech());
    _subscriptions.add(
      _session!.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(controller.pause());
        // Resuming after calls/navigation/audio focus loss is an explicit action.
      }),
    );
    _subscriptions.add(
      _session!.becomingNoisyEventStream.listen((_) {
        unawaited(controller.pause());
      }),
    );
    _subscriptions.add(
      _player.processingStateStream.distinct().listen((state) {
        if (state == ProcessingState.completed) _completed.add(null);
      }),
    );
    _subscriptions.add(
      _player.playbackEventStream.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _completed.addError(error, stack);
        },
      ),
    );
  }

  @override
  Stream<Duration> get positions => _player.createPositionStream(
    steps: 200,
    minPeriod: const Duration(milliseconds: 250),
    maxPeriod: const Duration(milliseconds: 500),
  );
  @override
  Stream<void> get completions => _completed.stream;
  @override
  Future<Duration?> load(File file, Duration position) {
    _playEpoch++;
    return _player.setFilePath(file.path, initialPosition: position);
  }

  @override
  Future<void> play() async {
    final epoch = ++_playEpoch;
    final active = _sessionActive || await _session!.setActive(true);
    if (epoch != _playEpoch) return;
    if (!active) {
      throw const SpeechFailure('音频正在被其他应用使用，请稍后继续听书');
    }
    _sessionActive = true;
    await _player.play();
  }

  @override
  Future<void> suspend() async {
    _playEpoch++;
    await _player.pause();
    // Keep speech focus across paragraph changes instead of briefly resuming
    // another app's music at every boundary.
  }

  @override
  Future<void> pause() async {
    _playEpoch++;
    await _player.pause();
    _sessionActive = false;
    await _session?.setActive(false);
  }

  @override
  Future<void> stop() async {
    _playEpoch++;
    await _player.stop();
    _sessionActive = false;
    await _session?.setActive(false);
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _completed.close();
  }
}

Future<ListeningAudioOutput> createListeningOutput(
  ListeningController controller,
) async {
  await prepareListeningService(controller);
  final output = NativeListeningOutput(controller);
  try {
    await output.initialize();
    return output;
  } catch (_) {
    await output.dispose();
    rethrow;
  }
}

Future<void>? _serviceReady;
Future<void> prepareListeningService(ListeningController controller) async {
  await (_serviceReady ??= _registerService(controller));
}

// Keep this name in sync with res/raw/listening_keep.xml. The Android plugin
// resolves it at runtime, so debug playback alone cannot validate release builds.
const listeningAndroidNotificationIcon = 'drawable/ic_listening_notification';

Future<void> _registerService(ListeningController controller) async {
  final handler = ListeningAudioHandler(controller);
  try {
    await AudioService.init(
      builder: () => handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'org.mewx.wenku8_flutter.listening',
        androidNotificationChannelName: '文库听书',
        androidNotificationChannelDescription: '听书播放、章节切换与续听',
        androidNotificationIcon: listeningAndroidNotificationIcon,
        notificationColor: Color(0xFF202020),
        // Remain foreground through short segment synthesis gaps. Explicit stop
        // releases the service; otherwise Android 12+ can reject background resume.
        androidStopForegroundOnPause: false,
        androidResumeOnClick: false,
        fastForwardInterval: Duration(seconds: 15),
        rewindInterval: Duration(seconds: 15),
      ),
    );
  } catch (_) {
    handler.close();
    _serviceReady = null;
    rethrow;
  }
}

class ListeningAudioHandler extends BaseAudioHandler {
  ListeningAudioHandler(
    this.controller, {
    this.bufferingGrace = const Duration(milliseconds: 500),
  }) {
    controller.snapshot.addListener(_state);
    controller.chapterProgress.addListener(_position);
    _state();
  }
  final ListeningController controller;
  final Duration bufferingGrace;
  Timer? _bufferingTimer;
  bool _holdingTransition = false;
  String? _readyKey;
  void close() {
    _bufferingTimer?.cancel();
    controller.snapshot.removeListener(_state);
    controller.chapterProgress.removeListener(_position);
  }

  String? _mediaKey;
  void _state() {
    final state = controller.snapshot.value;
    final key =
        '${state.novel?.id}/${state.chapter}/${state.chapterTitle}/${state.voice.engine}/${state.voice.id}';
    if (_mediaKey != key && state.novel != null) {
      _mediaKey = key;
      mediaItem.add(
        MediaItem(
          id: 'wenku:${state.novel!.id}:${state.chapter}',
          title: state.chapterTitle.isEmpty
              ? '正在准备章节'
              : '第 ${state.chapter + 1} 章 · ${state.chapterTitle}',
          album: state.novel!.title,
          artist: state.voice.label,
          // Clips are implementation details, not separate tracks. Future
          // speech durations are unknown; do not expose a per-clip seek bar as
          // if it were a chapter duration or republish metadata at every boundary.
          extras: {'bookId': state.novel!.id, 'chapter': state.chapter},
        ),
      );
    }
    if (state.phase == ListeningPhase.preparing &&
        state.requestingPlayback &&
        _readyKey == key) {
      if (_bufferingTimer == null) {
        _holdingTransition = true;
        _bufferingTimer = Timer(bufferingGrace, () {
          _holdingTransition = false;
          _position();
        });
      }
    } else {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
      _holdingTransition = false;
      if (state.phase == ListeningPhase.playing ||
          state.phase == ListeningPhase.paused) {
        _readyKey = key;
      }
    }
    _position();
  }

  void _position() {
    final state = controller.snapshot.value;
    if (_holdingTransition && state.phase == ListeningPhase.preparing) return;
    final progress = controller.chapterProgress.value;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          state.requestingPlayback ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (state.phase) {
          ListeningPhase.stopped => AudioProcessingState.idle,
          ListeningPhase.preparing => AudioProcessingState.buffering,
          ListeningPhase.completed => AudioProcessingState.completed,
          ListeningPhase.failed => AudioProcessingState.error,
          _ => AudioProcessingState.ready,
        },
        playing: state.requestingPlayback,
        updatePosition: progress.position,
        bufferedPosition: progress.position,
        speed: state.speed,
        errorCode: state.phase == ListeningPhase.failed ? 1 : null,
        errorMessage: state.error,
      ),
    );
  }

  @override
  Future<void> play() => controller.resume();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> stop() => controller.stop();
  @override
  Future<void> seek(Duration position) => controller.seek(position);
  @override
  Future<void> skipToNext() => controller.moveChapter(1);
  @override
  Future<void> skipToPrevious() => controller.moveChapter(-1);
  @override
  Future<void> fastForward() => controller.seek(
    controller.progress.value.position + const Duration(seconds: 15),
  );
  @override
  Future<void> rewind() => controller.seek(
    controller.progress.value.position - const Duration(seconds: 15),
  );
  @override
  Future<void> setSpeed(double speed) => controller.setSpeed(speed);
  @override
  Future<void> onTaskRemoved() async {
    if (!controller.snapshot.value.requestingPlayback) {
      await stop();
    }
  }
}
