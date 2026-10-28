part of 'local_library.dart';

/// Body strings and chapter analysis stay in the worker isolate.
class _LocalTextWorker extends LocalTextWorkerClient {
  _LocalTextWorker({super.readyTimeout, super.replyTimeout})
    : super(_textWorkerMain);

  Future<_TextMetadata> analyze(
    String path, {
    String? outputPath,
    bool normalize = false,
    int? maxBytes,
    bool preserveBom = false,
    String? sourceFingerprint,
  }) async =>
      await run({
            'path': path,
            'sourceFingerprint': sourceFingerprint,
            'output': outputPath,
            'normalize': normalize,
            'maxBytes': maxBytes,
            'preserveBom': preserveBom,
          })
          as _TextMetadata;

  Future<String> fingerprint(String path) async =>
      await run({'path': path, 'hash': true}) as String;

  Future<String> read(String path, {bool preserveBom = false}) async =>
      await run({'path': path, 'read': true, 'preserveBom': preserveBom})
          as String;

  Future<String> readRange(String path, int offset, int length) async =>
      await run({'path': path, 'offset': offset, 'length': length}) as String;
}

void _textWorkerMain(SendPort ready) async {
  final requests = ReceivePort();
  _TextSeekIndex? seekIndex;
  ready.send(requests.sendPort);
  await for (final message in requests) {
    try {
      final (reply, job) = message as (SendPort, Map<String, Object?>);
      final path = job['path'] as String;
      if (job['offset'] != null) {
        final stat = await File(path).stat();
        if (seekIndex?.path != path ||
            seekIndex?.size != stat.size ||
            seekIndex?.modified != stat.modified) {
          seekIndex = _TextSeekIndex(path, stat.size, stat.modified);
        }
        reply.send([
          true,
          await seekIndex!.read(job['offset'] as int, job['length'] as int),
        ]);
        continue;
      }
      final result = job['read'] == true
          ? await _readSmallText(path, job['preserveBom'] == true)
          : job['hash'] == true
          ? await sha256
                .bind(_boundedTextBytes(path, localTextMaxSourceBytes))
                .first
                .then((d) => d.toString())
          : await _analyzeTextFile(
              path,
              sourceFingerprint: job['sourceFingerprint'] as String?,
              outputPath: job['output'] as String?,
              normalize: job['normalize'] == true,
              maxBytes: job['maxBytes'] as int?,
              preserveBom: job['preserveBom'] == true,
            );
      reply.send([true, result]);
    } catch (error, stack) {
      // Ordinary job errors are replies. If even the error cannot be sent,
      // let onError/onExit fail the transport and trigger its bounded retry.
      try {
        final reply = (message as (SendPort, Map<String, Object?>)).$1;
        reply.send([false, error, stack]);
      } catch (_) {
        rethrow;
      }
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
    this.sourceFingerprint = '',
  });
  final String fingerprint;
  final String sourceFingerprint;
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
        throw FormatException(
          'TXT 文件过大：超过 ${maxBytes ~/ (1024 * 1024)} MiB 上限',
        );
      }
      yield chunk;
    }
  } on FileSystemException catch (error) {
    throw _TextSourceException(error);
  }
}

Future<String> _readSmallText(String path, bool preserveBom) async {
  final text = StringBuffer();
  await for (final chunk in _decodeTextChunks(
    _boundedTextBytes(path, localTextMaxReadCodeUnits),
    preserveBom,
  )) {
    if (text.length + chunk.length > localTextMaxReadCodeUnits) {
      throw const FormatException('文本过大，请按章节读取');
    }
    text.write(chunk);
  }
  return text.toString();
}

class _TextSeekIndex {
  _TextSeekIndex(this.path, this.size, this.modified);
  final String path;
  final int size;
  final DateTime modified;
  final _checkpoints = <({int bytes, int units})>[(bytes: 0, units: 0)];

  Future<String> read(int offset, int length) async {
    if (size > localTextMaxDecodedBytes) {
      throw const FormatException('TXT 解码后文件过大：超过 768 MiB 上限');
    }
    if (offset < 0 || length < 0) throw StateError('章节范围损坏，请重新扫描');
    if (length > localTextMaxReadCodeUnits) {
      throw const FormatException('单章正文过大：超过 4194304 个 UTF-16 字符，请拆分章节');
    }
    var low = 0;
    var high = _checkpoints.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (_checkpoints[middle].units <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    var bytes = _checkpoints[low].bytes;
    var units = _checkpoints[low].units;
    final end = offset + length;
    final text = StringBuffer();
    await for (final chunk in _decodeTextChunks(
      File(path).openRead(bytes),
      true,
    )) {
      final next = units + chunk.length;
      if (next > offset && units < end) {
        final startInChunk = offset > units ? offset - units : 0;
        final endInChunk = end < next ? end - units : chunk.length;
        text.write(chunk.substring(startInChunk, endInChunk));
      }
      units = next;
      bytes += utf8.encode(chunk).length;
      if (bytes - _checkpoints.last.bytes >= 64 * 1024) {
        _checkpoints.add((bytes: bytes, units: units));
      }
      if (units >= end) break;
    }
    if (units < end || text.length != length) {
      throw StateError('章节范围损坏，请重新扫描');
    }
    return text.toString();
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
  String? sourceFingerprint,
  String? outputPath,
  int? maxBytes = localTextMaxDecodedBytes,
  bool preserveBom = false,
}) async {
  var inputLength = 0;
  var outputBytes = 0;
  final digest = _DigestSink();
  final hashing = sha256.startChunkedConversion(digest);
  final rawDigest = _DigestSink();
  final rawHash = sha256.startChunkedConversion(rawDigest);
  final bytes = _boundedTextBytes(path, maxBytes ?? localTextMaxDecodedBytes)
      .map((chunk) {
        if (sourceFingerprint == null) rawHash.add(chunk);
        return chunk;
      });
  var chunks = _decodeTextChunks(bytes, preserveBom || normalize).map((chunk) {
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
      final encoded = utf8.encode(chunk);
      outputBytes += encoded.length;
      if (outputBytes > localTextMaxDecodedBytes) {
        throw const FormatException('TXT 解码后文件过大：超过 768 MiB 上限');
      }
      hashing.add(encoded);
      // Await each write, instead of accumulating an unbounded IOSink queue.
      if (output != null) await output.writeFrom(encoded);
    }
    await output?.close();
    output = null;
    hashing.close();
    rawHash.close();
    final result = analysis.finish();
    if (temporary != null && result.length > 0) {
      await temporary.rename(outputPath!);
    }
    return _TextMetadata(
      result.length,
      result.wordCount,
      result.chapters,
      inputLength: inputLength,
      fingerprint: digest.value.toString(),
      sourceFingerprint: sourceFingerprint ?? rawDigest.value.toString(),
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
