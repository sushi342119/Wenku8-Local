part of 'local_library.dart';

/// One request at a time bounds the live input/output buffers to one book.
/// Scans return only counts and chapter tables; body strings stay in the worker.
class _LocalTextWorker {
  Isolate? _isolate;
  SendPort? _requests;
  Future<void>? _starting;
  bool _closed = false;

  Future<void> _start() => _starting ??= () async {
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn(_textWorkerMain, ready.sendPort);
      _isolate = isolate;
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('Text worker disposed');
      }
      _requests = await ready.first as SendPort;
    } finally {
      ready.close();
    }
  }();

  Future<Object?> run(Map<String, Object?> job) async {
    if (_closed) throw StateError('Text worker disposed');
    await _start();
    final reply = ReceivePort();
    try {
      _requests!.send((reply.sendPort, job));
      final response = await reply.first as List;
      if (response[0] == false) {
        Error.throwWithStackTrace(
          response[1] as Object,
          response[2] as StackTrace,
        );
      }
      return response[1];
    } finally {
      reply.close();
    }
  }

  Future<_TextMetadata> analyze(
    String path, {
    String? outputPath,
    bool normalize = false,
    int? maxBytes,
    bool preserveBom = false,
  }) async =>
      await run({
            'path': path,
            'output': outputPath,
            'normalize': normalize,
            'maxBytes': maxBytes,
            'preserveBom': preserveBom,
          })
          as _TextMetadata;

  Future<String> read(String path, {bool preserveBom = false}) async =>
      await run({'path': path, 'read': true, 'preserveBom': preserveBom})
          as String;

  void dispose() {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _textWorkerMain(SendPort ready) async {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  await for (final message in requests) {
    final (reply, job) = message as (SendPort, Map<String, Object?>);
    try {
      final path = job['path'] as String;
      final result = job['read'] == true
          ? await _decodeTextChunks(
              _boundedTextBytes(path, null),
              job['preserveBom'] == true,
            ).join()
          : await _analyzeTextFile(
              path,
              outputPath: job['output'] as String?,
              normalize: job['normalize'] == true,
              maxBytes: job['maxBytes'] as int?,
              preserveBom: job['preserveBom'] == true,
            );
      reply.send([true, result]);
    } catch (error, stack) {
      reply.send([false, error, stack]);
    }
  }
}

class _TextMetadata {
  const _TextMetadata(
    this.length,
    this.wordCount,
    this.chapters, {
    this.inputLength = 0,
    this.fingerprint = '',
  });
  final String fingerprint;
  final int inputLength;
  final int length;
  final int wordCount;
  final List<LocalChapterIndex> chapters;
}

class _TextSourceException implements Exception {
  const _TextSourceException(this.cause);
  final Object cause;
  @override
  String toString() => cause.toString();
}

Stream<List<int>> _boundedTextBytes(String path, int? maxBytes) async* {
  var bytes = 0;
  try {
    await for (final chunk in File(path).openRead()) {
      bytes += chunk.length;
      if (maxBytes != null && bytes > maxBytes) {
        throw const FormatException('Text file exceeds 16 MB');
      }
      yield chunk;
    }
  } on FileSystemException catch (error) {
    throw _TextSourceException(error);
  }
}

// Utf8Decoder normally consumes an initial BOM. Native String decoding keeps it;
// a one-byte sentinel lets us preserve that distinction without a full buffer.
Stream<String> _decodeTextChunks(
  Stream<List<int>> bytes,
  bool preserveBom,
) async* {
  if (!preserveBom) {
    yield* bytes.transform(utf8.decoder);
    return;
  }
  Stream<List<int>> prefixed() async* {
    yield const [0];
    yield* bytes;
  }

  var first = true;
  await for (final chunk in prefixed().transform(utf8.decoder)) {
    if (first) {
      first = false;
      yield chunk.substring(1);
    } else {
      yield chunk;
    }
  }
}

/// Retains CR across chunks, so CRLF spanning two reads is still one newline.
Stream<String> _normalizeText(Stream<String> chunks) async* {
  var first = true;
  var carriageReturn = false;
  await for (var chunk in chunks) {
    if (chunk.isEmpty) continue;
    if (first) {
      first = false;
      if (chunk.startsWith('\uFEFF')) chunk = chunk.substring(1);
    }
    if (carriageReturn) {
      yield '\n';
      if (chunk.startsWith('\n')) chunk = chunk.substring(1);
    }
    carriageReturn = chunk.endsWith('\r');
    if (carriageReturn) chunk = chunk.substring(0, chunk.length - 1);
    if (chunk.isNotEmpty) {
      yield chunk
          .replaceAll('\r\n', '\n')
          .replaceAll(RegExp(r'[\r\u2028\u2029]'), '\n');
    }
  }
  if (carriageReturn) yield '\n';
}

Future<_TextMetadata> _analyzeTextFile(
  String path, {
  required bool normalize,
  String? outputPath,
  int? maxBytes,
  bool preserveBom = false,
}) async {
  var inputLength = 0;
  final digest = _DigestSink();
  final hashing = sha256.startChunkedConversion(digest);
  var chunks = _decodeTextChunks(_boundedTextBytes(path, maxBytes), preserveBom || normalize)
      .map((chunk) {
        inputLength += chunk.length;
        return chunk;
      });
  if (normalize) chunks = _normalizeText(chunks);
  final analysis = _StreamingTextIndex();
  final temporary = outputPath == null ? null : File('$outputPath.importing');
  RandomAccessFile? output;
  try {
    if (temporary != null) {
      await temporary.parent.create(recursive: true);
      output = await temporary.open(mode: FileMode.write);
    }
    await for (final chunk in chunks) {
      analysis.add(chunk);
      hashing.add(utf8.encode(chunk));
      // Await each write, instead of accumulating an unbounded IOSink queue.
      if (output != null) await output.writeString(chunk);
    }
    await output?.close();
    output = null;
    hashing.close();
    final result = analysis.finish();
    if (temporary != null && inputLength > 0) {
      await temporary.rename(outputPath!);
    }
    return _TextMetadata(
      result.length,
      result.wordCount,
      result.chapters,
      inputLength: inputLength,
      fingerprint: digest.value.toString(),
    );
  } finally {
    await output?.close();
    if (temporary != null && await temporary.exists()) await temporary.delete();
  }
}

class _StreamingTextIndex {
  final _index = ChapterTextIndex();
  var _words = 0;
  int? _highSurrogate;
  void add(String chunk) {
    var text = chunk;
    if (_highSurrogate case final high?) {
      text = '${String.fromCharCode(high)}$text';
      _highSurrogate = null;
    }
    if (text.isNotEmpty) {
      final last = text.codeUnitAt(text.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        _highSurrogate = last;
        text = text.substring(0, text.length - 1);
      }
    }
    _words += _countWords(text);
    _index.add(chunk);
  }

  _TextMetadata finish() => _TextMetadata(
    _index.length,
    _words + (_highSurrogate == null ? 0 : 1),
    _index.finish(),
  );
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
