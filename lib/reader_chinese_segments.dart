import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_jieba/dart_jieba.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The small bundled MIT word list is decoded only in a lazy worker. Only Han
/// runs reach Jieba: its fallback UTF-16 tokenizer never receives emoji/Japanese.
class ReaderChineseSegmenter {
  ReaderChineseSegmenter({
    Directory? directory,
    Future<Uint8List> Function()? loadData,
  }) : _directory = directory,
       _loadData = loadData;
  static final shared = ReaderChineseSegmenter();
  final Directory? _directory;
  final Future<Uint8List> Function()? _loadData;
  Isolate? _worker;
  ReceivePort? _messages, _failures;
  SendPort? _port;
  Future<void>? _starting;
  Completer<void>? _ready;
  bool _disposed = false;
  int _requestId = 0;
  final _pending = <int, Completer<List<List<String>>>>{};
  final _cache = <String, List<List<String>>>{};

  Future<void> _start() => _starting ??=
      () async {
        if (_disposed) throw StateError('分词器已关闭');
        final data =
            await (_loadData?.call() ??
                rootBundle
                    .load('assets/tokenizer/jieba-1.0.1.dgz')
                    .then(
                      (value) => value.buffer.asUint8List(
                        value.offsetInBytes,
                        value.lengthInBytes,
                      ),
                    ));
        if (_disposed) throw StateError('分词器已关闭');
        final root =
            _directory ??
            Directory(
              '${(await getApplicationSupportDirectory()).path}/reader-word-segmentation',
            );
        await root.create(recursive: true);
        final path = '${root.path}/jieba-1.0.1.dgz';
        final part = File('$path.part');
        await part.writeAsBytes(data, flush: true);
        await part.rename(path);
        if (_disposed) throw StateError('分词器已关闭');
        final ready = _ready = Completer<void>();
        ready.future.ignore();
        final messages = _messages = ReceivePort(),
            failures = _failures = ReceivePort();
        messages.listen((message) {
          if (message is SendPort) {
            _port = message;
            ready.complete();
          } else if (message is List && message.length == 3) {
            final request = _pending.remove(message[0]);
            if (request == null) return;
            if (message[1] == true) {
              request.complete(
                (message[2] as List)
                    .map((value) => List<String>.from(value as List))
                    .toList(),
              );
            } else {
              request.completeError(FormatException(message[2] as String));
            }
          }
        });
        failures.listen((_) {
          final error = const FormatException('离线分词未能初始化，可切换按字选择');
          if (!ready.isCompleted) ready.completeError(error);
          for (final request in _pending.values) {
            request.completeError(error);
          }
          _pending.clear();
          _worker?.kill();
          _worker = null;
          _port = null;
          _starting = null;
          messages.close();
          failures.close();
        });
        _worker = await Isolate.spawn(
          _jiebaWorker,
          (messages.sendPort, path),
          onError: failures.sendPort,
          onExit: failures.sendPort,
        );
        if (_disposed) {
          _worker?.kill();
          throw StateError('分词器已关闭');
        }
        await ready.future;
      }().catchError((Object error, StackTrace stack) {
        _starting = null;
        Error.throwWithStackTrace(error, stack);
      });

  /// Input is a bounded batch of Han-only strings; output preserves them exactly.
  Future<List<List<String>>> cut(List<String> runs) async {
    final key = runs.join('\u0000');
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    await _start();
    if (_disposed) throw StateError('分词器已关闭');
    final id = ++_requestId;
    final response = Completer<List<List<String>>>();
    _pending[id] = response;
    _port!.send([id, runs]);
    final result = await response.future;
    _cache[key] = result;
    while (_cache.length > 64) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  void dispose() {
    _disposed = true;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('分词器已关闭'));
    }
    _worker?.kill();
    _messages?.close();
    _failures?.close();
    for (final request in _pending.values) {
      request.completeError(StateError('分词器已关闭'));
    }
    _pending.clear();
    _cache.clear();
  }
}

void _jiebaWorker((SendPort, String) input) {
  final segmenter = JiebaSegmenter()..initializeSync(dictPath: input.$2);
  final requests = ReceivePort();
  input.$1.send(requests.sendPort);
  requests.listen((message) {
    if (message is! List || message.length != 2) return;
    try {
      final result = (message[1] as List)
          .map((value) => segmenter.cut(value as String))
          .toList();
      input.$1.send([message[0], true, result]);
    } catch (_) {
      input.$1.send([message[0], false, '离线分词未完成，可切换按字选择']);
    }
  });
}
