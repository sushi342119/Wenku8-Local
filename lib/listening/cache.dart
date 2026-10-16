import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'edge_tts.dart';
import 'models.dart';

abstract interface class SpeechAudioSource {
  Future<File> prepare(
    SpeechSegment segment,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  );
  Future<List<SpeechVoice>> offlineVoices();
  Future<List<SpeechVoice>> onlineVoices();
  void protect(File file);
  void unprotect(File file);
  Future<void> invalidate(File file);
  Future<void> trim();
}

class SpeechAudioCache implements SpeechAudioSource {
  SpeechAudioCache(this.directory, this.edge);
  final Directory directory;
  final EdgeSpeechClient edge;
  static const system = MethodChannel('org.mewx.wenku8/system_speech');
  final Map<String, ({SpeechCancellation token, Future<File> future})>
  _pending = {};
  Future<void> _nativeQueue = Future.value();
  final Set<String> _protected = {};
  static const maximumBytes = 96 * 1024 * 1024;
  static Future<SpeechAudioCache> forApp() async => SpeechAudioCache(
    Directory('${(await getTemporaryDirectory()).path}/listening-audio-v1'),
    EdgeSpeechClient(),
  );

  Future<T> _native<T>(Future<T> Function() action) {
    final next = _nativeQueue.then((_) => action());
    _nativeQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  @override
  Future<List<SpeechVoice>> onlineVoices() => edge.voices();

  @override
  Future<List<SpeechVoice>> offlineVoices() => _native(() async {
    final engines = await system.invokeListMethod<dynamic>('engines') ?? [];
    final found = <SpeechVoice>[];
    for (final raw in engines) {
      if (raw is! Map || raw['id'] is! String) continue;
      final engine = raw['id'] as String;
      if (!supportedSystemSpeechEngine(engine)) continue;
      try {
        final voices =
            await system
                .invokeListMethod<dynamic>('voices', {'engine': engine})
                .timeout(const Duration(seconds: 25)) ??
            [];
        for (final voice in voices) {
          if (voice is! Map ||
              voice['id'] is! String ||
              voice['locale'] is! String ||
              voice['networkRequired'] != false ||
              chineseSpeechLocale(voice['locale'] as String) == null ||
              (voice['features'] is List &&
                  (voice['features'] as List).contains('notInstalled'))) {
            continue;
          }
          final name = '${raw['name'] ?? engine} 离线';
          found.add(
            SpeechVoice(
              id: voice['id'],
              label: '$name · ${voice['id']}',
              engine: engine,
              locale: chineseSpeechLocale(voice['locale'])!,
              source: ListeningSource.system,
              offline: true,
              quality: voice['quality'] is int ? voice['quality'] : 0,
            ),
          );
        }
      } on PlatformException {
        /* One unusable engine does not hide other installed engines. */
      } on TimeoutException {
        /* Slow vendor metadata must not hold the panel's controls indefinitely. */
      }
    }
    found.sort((a, b) {
      final quality = b.quality.compareTo(a.quality);
      if (quality != 0) return quality;
      final engine = a.engine!.compareTo(b.engine!);
      return engine != 0 ? engine : a.id.compareTo(b.id);
    });
    return List.unmodifiable(found);
  });

  @override
  Future<File> prepare(
    SpeechSegment segment,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) async {
    cancellation.check();
    if (!voice.supported) {
      throw const SpeechFailure('该音色已不再支持，请重新选择听书音色');
    }
    final key = segment.key(voice);
    final pending = _pending[key];
    if (pending != null) {
      try {
        final file = await cancellation.wait(pending.future);
        cancellation.check();
        return file;
      } catch (_) {
        cancellation.check();
        if (identical(pending.token, cancellation)) rethrow;
        // A new seek/source switch must not inherit an old cancelled request.
      }
    }
    final future = _prepare(segment, voice, cancellation, key);
    _pending[key] = (token: cancellation, future: future);
    try {
      return await future;
    } finally {
      if (identical(_pending[key]?.future, future)) _pending.remove(key);
    }
  }

  Future<File> _prepare(
    SpeechSegment segment,
    SpeechVoice voice,
    SpeechCancellation cancellation,
    String key,
  ) async {
    try {
      final text = speechText(segment.text);
      if (!hasSpeechText(text)) {
        throw const SpeechFailure(
          '这一段没有可朗读的文本',
          kind: SpeechFailureKind.content,
        );
      }
      await directory.create(recursive: true);
      final extension = voice.source == ListeningSource.edge ? 'mp3' : 'wav';
      final file = File('${directory.path}/$key.$extension');
      if (await file.exists() && await file.length() > 100) {
        await file.setLastModified(DateTime.now());
        cancellation.check();
        return file;
      }
      final temporary = File('${file.path}.part');
      try {
        if (voice.source == ListeningSource.edge) {
          final data = await edge.synthesize(text, voice, cancellation);
          cancellation.check();
          await temporary.writeAsBytes(data, flush: true);
        } else {
          if (!voice.offline || voice.engine == null) {
            throw const SpeechFailure('请选择已安装的离线中文音色');
          }
          await _native(() async {
            cancellation.check();
            final requestId = EdgeSpeechClient.connectionId();
            final remove = cancellation.onCancel(() {
              unawaited(
                system
                    .invokeMethod<void>('cancel', {'requestId': requestId})
                    .catchError((Object _) {}),
              );
            });
            try {
              await system
                  .invokeMethod<String>('synthesize', {
                    'text': text,
                    'engine': voice.engine,
                    'voice': voice.id,
                    'path': temporary.path,
                    'requestId': requestId,
                  })
                  .timeout(
                    const Duration(seconds: 35),
                    onTimeout: () {
                      unawaited(
                        system
                            .invokeMethod<void>('cancel', {
                              'requestId': requestId,
                            })
                            .catchError((Object _) {}),
                      );
                      throw const SpeechFailure(
                        '系统语音准备超时',
                        kind: SpeechFailureKind.timeout,
                      );
                    },
                  );
            } finally {
              remove();
            }
          });
        }
        cancellation.check();
        if (!await temporary.exists() || await temporary.length() <= 100) {
          throw const SpeechFailure(
            '这一段没有生成有效语音',
            kind: SpeechFailureKind.content,
          );
        }
        await temporary.rename(file.path);
        return file;
      } on PlatformException catch (error) {
        cancellation.check();
        throw SpeechFailure(
          error.message ?? '系统离线音色暂未就绪',
          kind: switch (error.code) {
            'TTS_CONTENT' => SpeechFailureKind.content,
            'TTS_TIMEOUT' => SpeechFailureKind.timeout,
            _ => SpeechFailureKind.unavailable,
          },
        );
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    } on SpeechCancelled {
      rethrow;
    } catch (_) {
      cancellation.check();
      rethrow;
    }
  }

  @override
  void protect(File file) {
    _protected.add(file.path);
  }

  @override
  void unprotect(File file) {
    _protected.remove(file.path);
  }

  @override
  Future<void> invalidate(File file) async {
    if (file.absolute.parent.path != directory.absolute.path ||
        !RegExp(
          r'^[a-f0-9]{64}\.(mp3|wav)$',
        ).hasMatch(file.uri.pathSegments.last)) {
      return;
    }
    try {
      if (await file.exists() && !_protected.contains(file.path)) {
        await file.delete();
      }
    } on FileSystemException {
      /* A decoder failure remains bounded even if cache cleanup is unavailable. */
    }
  }

  @override
  Future<void> trim() async {
    if (!await directory.exists()) return;
    final entries = <({File file, FileStat stat})>[];
    await for (final item in directory.list()) {
      if (item is File && !item.path.endsWith('.part')) {
        entries.add((file: item, stat: await item.stat()));
      }
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var bytes = entries.fold<int>(0, (sum, e) => sum + e.stat.size);
    for (final entry in entries) {
      if (bytes <= maximumBytes) break;
      if (_protected.contains(entry.file.path)) continue;
      try {
        await entry.file.delete();
        bytes -= entry.stat.size;
      } on FileSystemException {
        /* Active files remain available. */
      }
    }
  }
}
