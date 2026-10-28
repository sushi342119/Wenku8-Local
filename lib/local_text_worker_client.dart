import 'dart:async';
import 'dart:isolate';

/// Serialized request/reply transport. A dead or unresponsive isolate gets one
/// replacement; application errors from a live worker are returned unchanged.
class LocalTextWorkerClient {
  LocalTextWorkerClient(
    this.entryPoint, {
    this.readyTimeout = const Duration(seconds: 3),
    this.replyTimeout = const Duration(seconds: 12),
  });

  final void Function(SendPort) entryPoint;
  final Duration readyTimeout;
  final Duration replyTimeout;
  _WorkerSession? _session;
  Future<void> _queue = Future.value();
  bool _closed = false;

  Future<Object?> run(Map<String, Object?> job) {
    final next = _queue.then((_) => _run(job));
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Object?> _run(Map<String, Object?> job) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_closed) throw StateError('Text worker disposed');
      if (_session?.closed == true) _session = null;
      final session = _session ??= _WorkerSession();
      try {
        if (session.requests == null) {
          await session
              .start(entryPoint)
              .timeout(
                readyTimeout,
                onTimeout: () => throw const TextWorkerUnavailable('文本处理启动超时'),
              );
        }
        if (session.closed) throw const TextWorkerUnavailable('文本处理已退出');
        final reply = ReceivePort();
        try {
          session.requests!.send((reply.sendPort, job));
          final response =
              await Future.any<Object?>([
                reply.first,
                session.failure.future.then<Object?>((error) => throw error),
              ]).timeout(
                replyTimeout,
                onTimeout: () => throw const TextWorkerUnavailable('文本处理回复超时'),
              );
          if (response is! List || response.length < 2) {
            throw const TextWorkerUnavailable('文本处理回复无效');
          }
          if (response[0] == false) {
            Error.throwWithStackTrace(
              response[1] as Object,
              response.length > 2 && response[2] is StackTrace
                  ? response[2] as StackTrace
                  : StackTrace.current,
            );
          }
          return response[1];
        } finally {
          reply.close();
        }
      } on TextWorkerUnavailable {
        session.close();
        if (identical(_session, session)) _session = null;
        if (attempt == 1 || _closed) rethrow;
      }
    }
    throw const TextWorkerUnavailable('文本处理失败，请重试');
  }

  void dispose() {
    _closed = true;
    _session?.close();
    _session = null;
  }
}

class TextWorkerUnavailable implements Exception {
  const TextWorkerUnavailable(this.message);
  final String message;
  @override
  String toString() => '$message，请重试';
}

class _WorkerSession {
  final ready = ReceivePort();
  final exited = ReceivePort();
  final errors = ReceivePort();
  final failure = Completer<TextWorkerUnavailable>();
  Isolate? isolate;
  SendPort? requests;
  bool closed = false;

  Future<void> start(void Function(SendPort) entryPoint) async {
    exited.listen((_) => _fail('文本处理进程已退出'));
    errors.listen((_) => _fail('文本处理进程异常退出'));
    try {
      // Install listeners before entryPoint can run, including early exits.
      final spawning = Isolate.spawn(
        entryPoint,
        ready.sendPort,
        onExit: exited.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
      isolate = await spawning;
      if (closed) {
        isolate!.kill(priority: Isolate.immediate);
        throw const TextWorkerUnavailable('文本处理已取消');
      }
      final port = await Future.any<Object?>([
        ready.first,
        failure.future.then<Object?>((error) => throw error),
      ]);
      if (port is! SendPort) {
        throw const TextWorkerUnavailable('文本处理握手无效');
      }
      if (closed) throw const TextWorkerUnavailable('文本处理已取消');
      requests = port;
    } on TextWorkerUnavailable {
      rethrow;
    } catch (_) {
      throw const TextWorkerUnavailable('文本处理无法启动');
    } finally {
      ready.close();
    }
  }

  void _fail(String message) {
    requests = null;
    if (!failure.isCompleted) failure.complete(TextWorkerUnavailable(message));
    // Clear the old SendPort even when the worker exits between requests.
    close();
  }

  void close() {
    if (closed) return;
    closed = true;
    requests = null;
    if (!failure.isCompleted) {
      failure.complete(const TextWorkerUnavailable('文本处理已终止'));
    }
    isolate?.kill(priority: Isolate.immediate);
    ready.close();
    exited.close();
    errors.close();
  }
}
