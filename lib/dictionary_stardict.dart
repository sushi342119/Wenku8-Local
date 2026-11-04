import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

const _maxSourceBytes = 512 * 1024 * 1024;
const _maxIndexBytes = 64 * 1024 * 1024;
const _maxDictionaryBytes = 2 * 1024 * 1024 * 1024;
const _maxDefinitionBytes = 2 * 1024 * 1024;
const _maxEntries = 1000000;
const _maxSynonyms = 1000000;
const _magic = [0x57, 0x38, 0x53, 0x44, 0x49, 0x44, 0x58, 0x31];
const _sourceSuffixes = [
  '.ifo',
  '.idx',
  '.idx.gz',
  '.dict',
  '.dict.dz',
  '.syn',
];

/// Imports a StarDict file group into a reusable local index. Sources are never
/// modified. A compressed dictionary is expanded once, with a streaming limit.
/// Call from the dictionary worker isolate, rather than the UI isolate.
Future<(int entries, String title)> buildStarDictIndex(String ifoPath) async {
  final stem = _stemFor(ifoPath);
  final before = await _fingerprints(stem);
  final info = await _readInfo(ifoPath);
  final indexPath = await _choose(stem, '.idx', '.idx.gz', '词条索引');
  final dictionaryPath = await _choose(stem, '.dict', '.dict.dz', '词典正文');
  final compressedData = dictionaryPath.endsWith('.dz');
  final dataPart = File('$ifoPath.data.part');
  final dataFile = File('$ifoPath.data');
  final indexPart = File('$ifoPath.index.part');
  try {
    final index = await _readIndexBytes(indexPath);
    if (index.length != info.indexBytes) {
      throw const FormatException('StarDict 索引大小与 IFO 不一致');
    }
    final sourceEntries = _parseIndex(index, info);
    final entries = List<_IndexEntry>.of(sourceEntries);
    final syn = File('$stem.syn');
    if (await syn.exists()) {
      if (info.synonyms == null) {
        throw const FormatException('StarDict 同义词文件缺少 synwordcount');
      }
      final bytes = await _readBounded(syn, _maxIndexBytes, '同义词索引');
      _appendSynonyms(bytes, sourceEntries, entries, info.synonyms!);
    } else if ((info.synonyms ?? 0) != 0) {
      throw const FormatException('StarDict 同义词文件缺失');
    }
    final dataLength = compressedData
        ? await _expandDictionary(File(dictionaryPath), dataPart)
        : await File(dictionaryPath).length();
    if (dataLength > _maxDictionaryBytes) {
      throw const FormatException('StarDict 正文展开后超过 2 GiB');
    }
    for (final entry in sourceEntries) {
      _checkRange(entry.offset, entry.length, dataLength);
    }
    entries.sort((a, b) {
      final folded = _asciiFold(a.word).compareTo(_asciiFold(b.word));
      return folded != 0 ? folded : a.word.compareTo(b.word);
    });
    final after = await _fingerprints(stem);
    if (jsonEncode(before) != jsonEncode(after)) {
      throw const FormatException('StarDict 文件在导入时发生变化，请重新选择');
    }
    final metadata = utf8.encode(
      jsonEncode({
        'title': info.title,
        'sameType': info.sameType,
        'wordCount': sourceEntries.length,
        'sources': before,
        'dataLength': dataLength,
        'compressedData': compressedData,
      }),
    );
    final cache = _encodeIndex(entries, metadata);
    await indexPart.writeAsBytes(cache, flush: true);
    if (compressedData) await dataPart.rename(dataFile.path);
    await indexPart.rename('$ifoPath.index');
    return (sourceEntries.length, info.title);
  } finally {
    if (await dataPart.exists()) await dataPart.delete();
    if (await indexPart.exists()) await indexPart.delete();
  }
}

/// Opens the persistent index without rescanning IDX or decompressing DICT.DZ.
/// Queries binary-search its byte table and read only matching definitions.
class StarDictReader {
  StarDictReader._(
    this._cache,
    this._table,
    this._bodyStart,
    this._sameType,
    this._dataLength,
    this._data,
  );

  final Uint8List _cache;
  final Uint32List _table;
  final int _bodyStart, _dataLength;
  final String? _sameType;
  final RandomAccessFile _data;
  Future<void> _operations = Future.value();
  bool _closed = false;

  /// Verifies the index belongs to the current app-owned source file group.
  static Future<StarDictReader> open(String ifoPath) async {
    final stem = _stemFor(ifoPath);
    final file = File('$ifoPath.index');
    if (!await file.exists()) {
      throw const FormatException('StarDict 离线索引缺失，请重新导入');
    }
    final bytes = await _readBounded(file, _maxIndexBytes, '离线索引');
    if (bytes.length < 16 || !_sameBytes(bytes, 0, _magic)) {
      throw const FormatException('StarDict 离线索引格式有误，请重新导入');
    }
    final view = ByteData.sublistView(bytes);
    final metadataLength = view.getUint32(8);
    if (metadataLength == 0 ||
        metadataLength > 32768 ||
        12 + metadataLength + 4 > bytes.length) {
      throw const FormatException('StarDict 离线索引头有误，请重新导入');
    }
    final metadata = jsonDecode(
      _utf8(Uint8List.sublistView(bytes, 12, 12 + metadataLength), '离线索引'),
    );
    if (metadata is! Map ||
        metadata['sources'] is! List ||
        metadata['dataLength'] is! int ||
        metadata['compressedData'] is! bool ||
        metadata['wordCount'] is! int ||
        metadata['wordCount'] <= 0 ||
        metadata['wordCount'] > _maxEntries ||
        metadata['title'] is! String ||
        metadata['title'].length > 160 ||
        (metadata['sameType'] != null && metadata['sameType'] is! String)) {
      throw const FormatException('StarDict 离线索引记录有误，请重新导入');
    }
    final sameType = metadata['sameType'] as String?;
    if (sameType != null) _checkTypes(sameType);
    final current = await _fingerprints(stem);
    if (jsonEncode(metadata['sources']) != jsonEncode(current)) {
      throw const FormatException('StarDict 源文件已变化，请重新导入');
    }
    final dataLength = metadata['dataLength'] as int;
    if (dataLength < 0 || dataLength > _maxDictionaryBytes) {
      throw const FormatException('StarDict 正文大小记录有误');
    }
    final countOffset = 12 + metadataLength;
    final count = view.getUint32(countOffset);
    if (count == 0 ||
        count > _maxEntries + _maxSynonyms ||
        countOffset + 4 + count * 4 > bytes.length) {
      throw const FormatException('StarDict 离线词条表有误，请重新导入');
    }
    final bodyStart = countOffset + 4 + count * 4;
    final bodyLength = bytes.length - bodyStart;
    final offsets = Uint32List(count);
    var previous = -1;
    for (var i = 0; i < count; i++) {
      final offset = view.getUint32(countOffset + 4 + i * 4);
      if (offset <= previous ||
          offset >= bodyLength ||
          (i == 0 && offset != 0)) {
        throw const FormatException('StarDict 离线词条偏移有误，请重新导入');
      }
      offsets[i] = offset;
      previous = offset;
    }
    final dataPath = metadata['compressedData'] == true
        ? '$ifoPath.data'
        : '$stem.dict';
    final data = File(dataPath);
    if (!await data.exists() || await data.length() != dataLength) {
      throw const FormatException('StarDict 正文缓存缺失或已损坏，请重新导入');
    }
    return StarDictReader._(
      bytes,
      offsets,
      bodyStart,
      sameType,
      dataLength,
      await data.open(),
    );
  }

  /// Returns matching headwords/aliases without reading unrelated definitions.
  /// ASCII case-folding follows StarDict's locale-independent comparison.
  Future<List<String>> lookup(String query) {
    if (_closed) return Future.error(StateError('词典已关闭'));
    final operation = _operations.then((_) => _lookup(query));
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<List<String>> _lookup(String query) async {
    final target = _asciiFold(query.trim());
    if (target.isEmpty || utf8.encode(target).length >= 256) return const [];
    var low = 0, high = _table.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_asciiFold(_entry(middle).word).compareTo(target) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final results = <String>[];
    final seen = <(int, int)>{};
    var totalBytes = 0;
    for (var i = low; i < _table.length; i++) {
      final entry = _entry(i);
      if (_asciiFold(entry.word) != target) break;
      if (!seen.add((entry.offset, entry.length))) continue;
      _checkRange(entry.offset, entry.length, _dataLength);
      totalBytes += entry.length;
      if (totalBytes > _maxDefinitionBytes || seen.length > 64) {
        throw const FormatException('StarDict 该词的同名释义过多或总内容超过 2 MiB');
      }
      await _data.setPosition(entry.offset);
      final bytes = await _data.read(entry.length);
      if (bytes.length != entry.length) {
        throw const FormatException('StarDict 正文读取不完整，请重新导入');
      }
      results.add(_decodeDefinition(bytes, _sameType));
    }
    return results;
  }

  _IndexEntry _entry(int index) {
    final start = _bodyStart + _table[index];
    final end = index + 1 < _table.length
        ? _bodyStart + _table[index + 1]
        : _cache.length;
    final keyEnd = end - 13;
    if (keyEnd <= start || keyEnd - start >= 256 || _cache[keyEnd] != 0) {
      throw const FormatException('StarDict 离线词条记录有误，请重新导入');
    }
    final word = _utf8(Uint8List.sublistView(_cache, start, keyEnd), '离线词条');
    final view = ByteData.sublistView(_cache);
    return _IndexEntry(
      word,
      view.getUint64(keyEnd + 1),
      view.getUint32(keyEnd + 9),
    );
  }

  /// Releases the dictionary file after already-submitted lookups finish.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operations;
    await _data.close();
  }
}

class _Info {
  const _Info(
    this.title,
    this.words,
    this.indexBytes,
    this.offsetWidth,
    this.sameType,
    this.synonyms,
  );
  final String title;
  final int words, indexBytes, offsetWidth;
  final String? sameType;
  final int? synonyms;
}

class _IndexEntry {
  const _IndexEntry(this.word, this.offset, this.length);
  final String word;
  final int offset, length;
}

String _stemFor(String ifoPath) {
  if (!ifoPath.toLowerCase().endsWith('.ifo')) {
    throw const FormatException('请选择 StarDict 的 IFO 文件');
  }
  return ifoPath.substring(0, ifoPath.length - 4);
}

Future<_Info> _readInfo(String path) async {
  final bytes = await _readBounded(File(path), 1024 * 1024, 'IFO 文件');
  final lines = const LineSplitter().convert(_utf8(bytes, 'IFO 文件'));
  if (lines.length < 2 || lines.first != "StarDict's dict ifo file") {
    throw const FormatException('不是有效的 StarDict 普通词典 IFO 文件');
  }
  final fields = <String, String>{};
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final equal = line.indexOf('=');
    if (equal <= 0) throw const FormatException('StarDict IFO 字段格式有误');
    final key = line.substring(0, equal).trim();
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key) || fields.containsKey(key)) {
      throw const FormatException('StarDict IFO 字段重复或无效');
    }
    if (fields.isEmpty && key != 'version') {
      throw const FormatException('StarDict IFO 首个字段必须是版本');
    }
    fields[key] = line.substring(equal + 1).trim();
  }
  final version = fields['version'];
  if (version != '2.4.2' && version != '3.0.0') {
    throw UnsupportedError('仅支持 StarDict 2.4.2 和 3.0.0 普通词典');
  }
  final title = fields['bookname'];
  if (title == null || title.isEmpty || title.length > 160) {
    throw const FormatException('StarDict 缺少有效的词典名称');
  }
  int number(String key, int maximum, {bool allowZero = false}) {
    final raw = fields[key];
    final value = raw != null && RegExp(r'^[0-9]+$').hasMatch(raw)
        ? int.tryParse(raw)
        : null;
    if (value == null || value < (allowZero ? 0 : 1) || value > maximum) {
      throw FormatException('StarDict $key 数值缺失或超出范围');
    }
    return value;
  }

  final bits = fields['idxoffsetbits'] ?? '32';
  if ((bits != '32' && bits != '64') || (bits == '64' && version != '3.0.0')) {
    throw const FormatException('StarDict 索引偏移位宽无效');
  }
  final sameType = fields['sametypesequence'];
  if (sameType != null) _checkTypes(sameType);
  return _Info(
    title,
    number('wordcount', _maxEntries),
    number('idxfilesize', _maxIndexBytes),
    bits == '64' ? 8 : 4,
    sameType,
    fields.containsKey('synwordcount')
        ? number('synwordcount', _maxSynonyms, allowZero: true)
        : null,
  );
}

Future<String> _choose(
  String stem,
  String raw,
  String compressed,
  String label,
) async {
  final rawExists = await File('$stem$raw').exists();
  final compressedExists = await File('$stem$compressed').exists();
  if (rawExists && compressedExists) {
    throw FormatException('StarDict $label同时存在两个版本，请只保留一份');
  }
  if (!rawExists && !compressedExists) {
    throw FormatException('StarDict $label缺失，请选择完整文件组');
  }
  return '$stem${rawExists ? raw : compressed}';
}

Future<List<Map<String, Object>>> _fingerprints(String stem) async {
  final result = <Map<String, Object>>[];
  for (final suffix in _sourceSuffixes) {
    final file = File('$stem$suffix');
    if (!await file.exists()) continue;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size > _maxSourceBytes) {
      throw const FormatException('StarDict 原文件必须在 512 MiB 以内');
    }
    result.add({
      'suffix': suffix,
      'size': stat.size,
      'modified': stat.modified.microsecondsSinceEpoch,
    });
  }
  return result;
}

Future<Uint8List> _readBounded(File file, int maximum, String label) async {
  final size = await file.length();
  if (size < 0 || size > maximum) throw FormatException('$label超过支持的大小');
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in file.openRead()) {
    total += chunk.length;
    if (total > maximum) throw FormatException('$label超过支持的大小');
    builder.add(chunk);
  }
  if (total != size) throw FormatException('$label在读取时发生变化');
  return builder.takeBytes();
}

Future<Uint8List> _readIndexBytes(String path) async {
  if (!path.endsWith('.gz')) {
    return _readBounded(File(path), _maxIndexBytes, '词条索引');
  }
  final input = InputFileStream(path);
  final output = OutputMemoryStream();
  try {
    final complete = const GZipDecoder().decodeStream(
      input,
      output,
      maxOutputSize: _maxIndexBytes,
    );
    if (!complete) throw const FormatException('StarDict 压缩索引不完整或已损坏');
    return output.getBytes();
  } on ArchiveException {
    throw const FormatException('StarDict 索引展开后超过 64 MiB 或压缩格式有误');
  } finally {
    await input.close();
    await output.close();
  }
}

Future<int> _expandDictionary(File source, File part) async {
  final input = InputFileStream(source.path);
  final output = OutputFileStream(part.path);
  try {
    final complete = const GZipDecoder().decodeStream(
      input,
      output,
      maxOutputSize: _maxDictionaryBytes,
    );
    if (!complete) throw const FormatException('StarDict 压缩正文不完整或已损坏');
    output.flush();
    return output.length;
  } on ArchiveException {
    throw const FormatException('StarDict 正文展开后超过 2 GiB 或压缩格式有误');
  } finally {
    await input.close();
    await output.close();
  }
}

List<_IndexEntry> _parseIndex(Uint8List bytes, _Info info) {
  final result = <_IndexEntry>[];
  final view = ByteData.sublistView(bytes);
  var cursor = 0;
  while (cursor < bytes.length) {
    final end = bytes.indexOf(0, cursor);
    if (end <= cursor ||
        end - cursor >= 256 ||
        end + 1 + info.offsetWidth + 4 > bytes.length) {
      throw const FormatException('StarDict 索引词条不完整或过长');
    }
    final word = _utf8(Uint8List.sublistView(bytes, cursor, end), '索引词条');
    final offset = info.offsetWidth == 8
        ? view.getUint64(end + 1)
        : view.getUint32(end + 1);
    final length = view.getUint32(end + 1 + info.offsetWidth);
    if (offset < 0 || length > _maxDefinitionBytes) {
      throw const FormatException('StarDict 词条偏移无效或正文超过 2 MiB');
    }
    result.add(_IndexEntry(word, offset, length));
    if (result.length > info.words) {
      throw const FormatException('StarDict 词条数量与 IFO 不一致');
    }
    cursor = end + 1 + info.offsetWidth + 4;
  }
  if (result.length != info.words) {
    throw const FormatException('StarDict 词条数量与 IFO 不一致');
  }
  return result;
}

void _appendSynonyms(
  Uint8List bytes,
  List<_IndexEntry> source,
  List<_IndexEntry> output,
  int expected,
) {
  final view = ByteData.sublistView(bytes);
  var cursor = 0, count = 0;
  while (cursor < bytes.length) {
    final end = bytes.indexOf(0, cursor);
    if (end <= cursor || end - cursor >= 256 || end + 5 > bytes.length) {
      throw const FormatException('StarDict 同义词索引不完整或过长');
    }
    final word = _utf8(Uint8List.sublistView(bytes, cursor, end), '同义词');
    final target = view.getUint32(end + 1);
    if (target >= source.length) {
      throw const FormatException('StarDict 同义词指向不存在的原词条');
    }
    final original = source[target];
    output.add(_IndexEntry(word, original.offset, original.length));
    count++;
    if (count > expected) {
      throw const FormatException('StarDict 同义词数量与 IFO 不一致');
    }
    cursor = end + 5;
  }
  if (count != expected) {
    throw const FormatException('StarDict 同义词数量与 IFO 不一致');
  }
}

Uint8List _encodeIndex(List<_IndexEntry> entries, List<int> metadata) {
  final body = BytesBuilder(copy: false);
  final table = ByteData(entries.length * 4);
  var offset = 0;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final word = utf8.encode(entry.word);
    table.setUint32(i * 4, offset);
    final record = Uint8List(word.length + 13);
    record.setRange(0, word.length, word);
    final view = ByteData.sublistView(record);
    view.setUint64(word.length + 1, entry.offset);
    view.setUint32(word.length + 9, entry.length);
    body.add(record);
    offset += record.length;
    if (16 + metadata.length + table.lengthInBytes + offset > _maxIndexBytes) {
      throw const FormatException('StarDict 离线索引超过 64 MiB');
    }
  }
  final header = ByteData(12)..setUint32(8, metadata.length);
  header.buffer.asUint8List().setRange(0, 8, _magic);
  final count = ByteData(4)..setUint32(0, entries.length);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(metadata)
        ..add(count.buffer.asUint8List())
        ..add(table.buffer.asUint8List())
        ..add(body.takeBytes()))
      .takeBytes();
}

void _checkRange(int offset, int length, int dataLength) {
  if (offset < 0 ||
      length < 0 ||
      length > _maxDefinitionBytes ||
      length > dataLength ||
      offset > dataLength - length) {
    throw const FormatException('StarDict 词条偏移超出正文范围');
  }
}

String _decodeDefinition(Uint8List bytes, String? sameType) {
  if (bytes.isEmpty) return '';
  final fields = <String>[];
  var cursor = 0;
  final sequence = sameType?.split('');
  var field = 0;
  while (cursor < bytes.length ||
      (sequence != null && field < sequence.length)) {
    final type = sequence == null
        ? String.fromCharCode(bytes[cursor++])
        : sequence[field];
    _checkTypes(type);
    final last = sequence != null && field == sequence.length - 1;
    final end = last ? bytes.length : bytes.indexOf(0, cursor);
    if (end < cursor) throw const FormatException('StarDict 词条字段缺少结束符');
    var content = _utf8(Uint8List.sublistView(bytes, cursor, end), '词条释义');
    if (last) content = content.replaceFirst(RegExp(r'\x00+$'), '');
    fields.add(
      const {'h', 'g', 'x', 'k'}.contains(type)
          ? content
          : const HtmlEscape(HtmlEscapeMode.element).convert(content),
    );
    cursor = last ? end : end + 1;
    field++;
  }
  if (sequence != null && field != sequence.length) {
    throw const FormatException('StarDict 词条字段数量不匹配');
  }
  return fields.join('<br>');
}

void _checkTypes(String types) {
  if (types.isEmpty || types.length > 32) {
    throw const FormatException('StarDict 词条类型序列无效');
  }
  for (final type in types.split('')) {
    if (!RegExp(r'^[a-zA-Z]$').hasMatch(type)) {
      throw const FormatException('StarDict 词条类型标记无效');
    }
    if (type == 'l') {
      throw UnsupportedError('暂不支持使用系统区域编码的 StarDict l 字段，请使用 UTF-8 词典');
    }
    if (!const {'m', 'h', 'g', 't', 'x', 'y', 'k', 'w', 'n'}.contains(type)) {
      throw UnsupportedError('暂不支持 StarDict $type 字段（资源或二进制内容）');
    }
  }
}

String _asciiFold(String value) => String.fromCharCodes(
  value.codeUnits.map((unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit),
);

String _utf8(List<int> bytes, String label) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw FormatException('StarDict $label不是有效的 UTF-8 文本');
  }
}

bool _sameBytes(List<int> value, int offset, List<int> expected) {
  if (offset + expected.length > value.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (value[offset + i] != expected[i]) return false;
  }
  return true;
}
