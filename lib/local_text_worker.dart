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
    bool stripBomForChapters = false,
  }) async =>
      await run({
            'path': path,
            'output': outputPath,
            'normalize': normalize,
            'maxBytes': maxBytes,
            'preserveBom': preserveBom,
            'stripBomForChapters': stripBomForChapters,
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
              stripBomForChapters: job['stripBomForChapters'] == true,
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
  });
  final int inputLength;
  final int length;
  final int wordCount;
  final List<LocalChapterIndex> chapters;
}

class _TextSourceException implements Exception {
  const _TextSourceException(this.cause);
  final Object cause;
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
      yield chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
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
  bool stripBomForChapters = false,
}) async {
  var inputLength = 0;
  var chunks = _decodeTextChunks(_boundedTextBytes(path, maxBytes), preserveBom)
      .map((chunk) {
        inputLength += chunk.length;
        return chunk;
      });
  if (normalize) chunks = _normalizeText(chunks);
  final analysis = _StreamingTextIndex(
    stripBomForChapters: stripBomForChapters,
  );
  final temporary = outputPath == null ? null : File('$outputPath.importing');
  RandomAccessFile? output;
  try {
    if (temporary != null) {
      await temporary.parent.create(recursive: true);
      output = await temporary.open(mode: FileMode.write);
    }
    await for (final chunk in chunks) {
      analysis.add(chunk);
      // Await each write, instead of accumulating an unbounded IOSink queue.
      if (output != null) await output.writeString(chunk);
    }
    await output?.close();
    output = null;
    final result = analysis.finish();
    var chapters = result.chapters;
    if (analysis.hasNonLfLineTerminators) {
      // The legacy multiline regex also treats CR/Unicode separators as anchors,
      // while its body ranges end at LF. Keep that rare case exactly compatible.
      var text = await _decodeTextChunks(
        _boundedTextBytes(temporary?.path ?? path, null),
        temporary != null || preserveBom,
      ).join();
      if (normalize && temporary == null) {
        text = await _normalizeText(Stream.value(text)).join();
      }
      if (stripBomForChapters && text.startsWith('\uFEFF')) {
        text = text.substring(1);
      }
      chapters = List.unmodifiable(LocalLibraryStore._splitChapters(text));
    }
    if (temporary != null && inputLength > 0) {
      await temporary.rename(outputPath!);
    }
    return _TextMetadata(
      result.length,
      result.wordCount,
      chapters,
      inputLength: inputLength,
    );
  } finally {
    await output?.close();
    if (temporary != null && await temporary.exists()) await temporary.delete();
  }
}

class _StreamingTextIndex {
  _StreamingTextIndex({this.stripBomForChapters = false});
  final bool stripBomForChapters;
  bool _firstChunk = true;
  var _length = 0;
  bool hasNonLfLineTerminators = false;
  var _words = 0;
  var _lineStart = 0;
  var _line = '';
  var _longLine = false;
  int? _highSurrogate;
  final _headings = <({String title, int start, int content})>[];

  void add(String chunk) {
    hasNonLfLineTerminators =
        hasNonLfLineTerminators || chunk.contains(RegExp(r'[\r\u2028\u2029]'));
    // Rune counts must treat a surrogate pair crossing chunks as one character.
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
    if (_firstChunk && chunk.isNotEmpty) {
      _firstChunk = false;
      if (stripBomForChapters && chunk.startsWith('\uFEFF')) {
        chunk = chunk.substring(1);
      }
    }
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf('\n', start);
      final end = newline < 0 ? chunk.length : newline;
      if (!_longLine) {
        // A valid title trims to <=64 units, with at most 32 leading and 40
        // trailing regex units. Longer body lines can be discarded immediately.
        if (_line.length + end - start > 256) {
          _line = '';
          _longLine = true;
        } else {
          _line += chunk.substring(start, end);
        }
      }
      if (newline < 0) break;
      _finishLine(_length + newline + 1);
      _lineStart = _length + newline + 1;
      start = newline + 1;
    }
    _length += chunk.length;
  }

  void _finishLine(int contentStart) {
    if (!_longLine) {
      final match = _chapterTitlePattern.firstMatch(_line);
      if (match != null) {
        final title = match.group(0)!.trim();
        if (title.isNotEmpty && title.length <= 64) {
          _headings.add((
            title: title,
            start: _lineStart + match.start,
            content: contentStart,
          ));
        }
      }
    }
    _line = '';
    _longLine = false;
  }

  _TextMetadata finish() {
    if (_highSurrogate != null) _words++;
    _finishLine(_length);
    final chapters = _headings.length < 2
        ? [LocalChapterIndex('正文', 0, _length)]
        : [
            for (var i = 0; i < _headings.length; i++)
              LocalChapterIndex(
                _headings[i].title,
                _headings[i].content,
                ((i + 1 < _headings.length ? _headings[i + 1].start : _length) -
                        _headings[i].content)
                    .clamp(0, _length),
              ),
          ];
    return _TextMetadata(_length, _words, List.unmodifiable(chapters));
  }
}
