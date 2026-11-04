import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

const _maxSourceBytes = 512 * 1024 * 1024;
const _maxIndexBytes = 64 * 1024 * 1024;
const _maxBodyBytes = 64 * 1024 * 1024;
const _maxDefinitionBytes = 2 * 1024 * 1024;
const _maxEntries = 1000000;
const _nativeMagic = 'W8MOBI01';
const _cacheMagic = 'W8MBIDX1';

/// Imports actual MOBI7 ORTH headwords and their original RAWML byte ranges.
/// libmobi performs decompression/index decoding in the caller's worker isolate;
/// ordinary books, DRM and unsupported index variants never become dictionaries.
Future<(int entries, String title)> buildMobiDictionaryIndex(
  String path,
) async {
  final source = File(path);
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file ||
      before.size <= 0 ||
      before.size > _maxSourceBytes) {
    throw const FormatException('MOBI 词典文件需要在 512 MiB 以内且内容完整');
  }
  final directory = await source.parent.createTemp('mobi-index-');
  final part = File('$path.index.part');
  final data = File('$path.data');
  try {
    final status = _MobiNative.extract(path, directory.path);
    if (status != 0) {
      throw FormatException(switch (status) {
        1 => '这部 MOBI 词典受 DRM 保护，请使用无 DRM 的合法原文件',
        3 => 'MOBI 词典正文、词条或索引超过安全大小限制',
        4 => 'MOBI 词典无法写入，请检查剩余空间后重试',
        5 => '这不是带词头索引的 MOBI7 词典；普通 MOBI 小说不能作为词典导入',
        6 => '暂不支持这种 MOBI 编码或无明确释义长度的旧索引，请使用 MDX 或 StarDict 版本',
        _ => 'MOBI 词典或词头索引损坏，请检查原文件',
      });
    }
    final native = File('${directory.path}/dictionary.orth');
    if (!await native.exists() || await native.length() > _maxIndexBytes) {
      throw const FormatException('MOBI 词头索引缺失或超过 64 MiB');
    }
    final input = _Bytes(await native.readAsBytes());
    if (ascii.decode(input.read(8)) != _nativeMagic) {
      throw const FormatException('MOBI 词头索引导出格式有误');
    }
    final bodyEncoding = input.uint32(), keyEncoding = input.uint32();
    _checkEncoding(bodyEncoding);
    _checkEncoding(keyEncoding);
    final bodyLength = input.uint64(), count = input.uint32();
    final titleLength = input.uint32();
    if (bodyLength < 1 ||
        bodyLength > _maxBodyBytes ||
        count < 1 ||
        count > _maxEntries ||
        titleLength > 64 * 1024) {
      throw const FormatException('MOBI 词典正文或词头数量无效');
    }
    final title = utf8.decode(input.read(titleLength)).trim();
    final entries = <_Entry>[];
    for (var index = 0; index < count; index++) {
      final size = input.uint16();
      if (size == 0 || size > 1024) {
        throw const FormatException('MOBI 词头为空或过长');
      }
      final word = _decode(input.read(size), keyEncoding);
      _checkWord(word);
      final entry = _Entry(word, input.uint32(), input.uint32());
      _checkRange(entry.offset, entry.length, bodyLength);
      entries.add(entry);
    }
    if (!input.done) throw const FormatException('MOBI 词头索引包含多余数据');
    final raw = File('${directory.path}/dictionary.raw');
    if (!await raw.exists() || await raw.length() != bodyLength) {
      throw const FormatException('MOBI 释义正文与词头索引不一致');
    }
    final after = await source.stat();
    if (before.size != after.size || before.modified != after.modified) {
      throw const FormatException('MOBI 词典在导入时发生变化，请重新选择');
    }
    entries.sort((a, b) {
      final folded = _fold(a.word).compareTo(_fold(b.word));
      if (folded != 0) return folded;
      final word = a.word.compareTo(b.word);
      return word != 0 ? word : a.offset.compareTo(b.offset);
    });
    final metadata = utf8.encode(
      jsonEncode({
        'sourceBytes': before.size,
        'sourceModified': before.modified.microsecondsSinceEpoch,
        'bodyBytes': bodyLength,
        'bodyEncoding': bodyEncoding,
      }),
    );
    final table = BytesBuilder(copy: false), body = BytesBuilder(copy: false);
    for (final entry in entries) {
      final word = utf8.encode(entry.word);
      table.add(_number(body.length, 4));
      body.add(_number(word.length, 2));
      body.add(word);
      body.add(_number(entry.offset, 4));
      body.add(_number(entry.length, 4));
      if (body.length + table.length + metadata.length + 16 > _maxIndexBytes) {
        throw const FormatException('MOBI 离线索引超过 64 MiB');
      }
    }
    final output = BytesBuilder(copy: false)
      ..add(ascii.encode(_cacheMagic))
      ..add(_number(metadata.length, 4))
      ..add(metadata)
      ..add(_number(entries.length, 4))
      ..add(table.takeBytes())
      ..add(body.takeBytes());
    await part.writeAsBytes(output.takeBytes(), flush: true);
    await raw.rename(data.path);
    await part.rename('$path.index');
    return (count, title);
  } finally {
    if (await directory.exists()) await directory.delete(recursive: true);
    if (await part.exists()) await part.delete();
  }
}

/// Opens an already-imported MOBI index. Lookups binary-search headwords and
/// read only corresponding bounded definitions, never reparse/decompress MOBI.
class MobiDictionaryReader {
  MobiDictionaryReader._(
    this._cache,
    this._table,
    this._bodyStart,
    this._bodyLength,
    this._encoding,
    this._data,
  );
  final Uint8List _cache;
  final Uint32List _table;
  final int _bodyStart, _bodyLength, _encoding;
  final RandomAccessFile _data;
  Future<void> _operations = Future.value();
  bool _closed = false;

  static Future<MobiDictionaryReader> open(String path) async {
    final index = File('$path.index');
    if (!await index.exists() || await index.length() > _maxIndexBytes) {
      throw const FormatException('MOBI 离线索引缺失或过大，请重新导入');
    }
    final cache = await index.readAsBytes();
    final input = _Bytes(cache);
    if (ascii.decode(input.read(8)) != _cacheMagic) {
      throw const FormatException('MOBI 离线索引格式有误，请重新导入');
    }
    final metadataLength = input.uint32();
    if (metadataLength < 1 || metadataLength > 1024) {
      throw const FormatException('MOBI 离线索引头有误');
    }
    final metadata = jsonDecode(utf8.decode(input.read(metadataLength)));
    if (metadata is! Map ||
        metadata['sourceBytes'] is! int ||
        metadata['sourceModified'] is! int ||
        metadata['bodyBytes'] is! int ||
        metadata['bodyEncoding'] is! int) {
      throw const FormatException('MOBI 离线索引记录有误');
    }
    final bodyLength = metadata['bodyBytes'] as int;
    final encoding = metadata['bodyEncoding'] as int;
    _checkEncoding(encoding);
    if (bodyLength < 1 || bodyLength > _maxBodyBytes) {
      throw const FormatException('MOBI 正文大小记录有误');
    }
    final source = await File(path).stat();
    if (source.type != FileSystemEntityType.file ||
        source.size != metadata['sourceBytes'] ||
        source.modified.microsecondsSinceEpoch != metadata['sourceModified']) {
      throw const FormatException('MOBI 私有源文件已变化，请重新导入');
    }
    final count = input.uint32();
    if (count < 1 || count > _maxEntries || count * 4 > input.remaining) {
      throw const FormatException('MOBI 离线词条表无效');
    }
    final table = Uint32List(count);
    for (var index = 0; index < count; index++) {
      table[index] = input.uint32();
      if ((index == 0 && table[index] != 0) ||
          (index > 0 && table[index] <= table[index - 1])) {
        throw const FormatException('MOBI 离线词条位置有误');
      }
    }
    final bodyStart = input.offset;
    final dataFile = File('$path.data');
    if (!await dataFile.exists() || await dataFile.length() != bodyLength) {
      throw const FormatException('MOBI 释义缓存缺失或损坏，请重新导入');
    }
    final file = await dataFile.open();
    final reader = MobiDictionaryReader._(
      cache,
      table,
      bodyStart,
      bodyLength,
      encoding,
      file,
    );
    try {
      String? previous;
      for (var index = 0; index < count; index++) {
        final word = _fold(reader._entry(index).word);
        if (previous != null && previous.compareTo(word) > 0) {
          throw const FormatException('MOBI 离线词条排序有误');
        }
        previous = word;
      }
      return reader;
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  /// Returns each matching homograph once; no fuzzy paragraph search is used.
  Future<List<(String word, String definition)>> lookup(String query) {
    if (_closed) return Future.error(StateError('词典已关闭'));
    final operation = _operations.then((_) => _lookup(query));
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<List<(String, String)>> _lookup(String query) async {
    final target = _fold(query.trim());
    if (target.isEmpty) return const [];
    var low = 0, high = _table.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_fold(_entry(middle).word).compareTo(target) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final result = <(String, String)>[];
    final seen = <(int, int)>{};
    var total = 0;
    for (var index = low; index < _table.length; index++) {
      final entry = _entry(index);
      if (_fold(entry.word) != target) break;
      if (!seen.add((entry.offset, entry.length))) continue;
      total += entry.length;
      if (total > _maxDefinitionBytes || result.length >= 64) {
        throw const FormatException('MOBI 该词同名释义过多或总内容超过 2 MiB');
      }
      await _data.setPosition(entry.offset);
      final bytes = await _data.read(entry.length);
      if (bytes.length != entry.length) {
        throw const FormatException('MOBI 释义读取不完整，请重新导入');
      }
      result.add((entry.word, _decode(bytes, _encoding)));
    }
    return result;
  }

  _Entry _entry(int index) {
    final start = _bodyStart + _table[index];
    final end = index + 1 < _table.length
        ? _bodyStart + _table[index + 1]
        : _cache.length;
    if (start < _bodyStart || end > _cache.length || end - start < 11) {
      throw const FormatException('MOBI 离线词条范围有误');
    }
    final input = _Bytes(Uint8List.sublistView(_cache, start, end));
    final size = input.uint16();
    if (size < 1 || size > 1024 || size != input.remaining - 8) {
      throw const FormatException('MOBI 离线词头长度有误');
    }
    final word = utf8.decode(input.read(size));
    _checkWord(word);
    final entry = _Entry(word, input.uint32(), input.uint32());
    _checkRange(entry.offset, entry.length, _bodyLength);
    return entry;
  }

  /// Releases the body handle after already-submitted lookups finish.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operations;
    await _data.close();
  }
}

class _Entry {
  const _Entry(this.word, this.offset, this.length);
  final String word;
  final int offset, length;
}

String _fold(String value) => value.toLowerCase();
void _checkWord(String word) {
  if (word.trim().isEmpty ||
      utf8.encode(word).length > 1024 ||
      word.runes.any((rune) => rune < 32 || rune == 127)) {
    throw const FormatException('MOBI 词头无效或超过 1024 字节');
  }
}

void _checkRange(int offset, int length, int total) {
  if (offset < 0 || length < 1 || offset + length > total) {
    throw const FormatException('MOBI 词条的释义范围越界');
  }
  if (length > _maxDefinitionBytes) {
    throw const FormatException('MOBI 单个词条超过 2 MiB');
  }
}

void _checkEncoding(int encoding) {
  if (encoding != 65001 && encoding != 1252) {
    throw const FormatException('暂不支持此 MOBI 词典编码，仅支持 UTF-8 和 Windows-1252');
  }
}

String _decode(Uint8List bytes, int encoding) => encoding == 65001
    ? utf8.decode(bytes)
    : String.fromCharCodes(
        bytes.map(
          (byte) =>
              byte >= 0x80 && byte < 0xa0 ? _windows1252[byte - 0x80] : byte,
        ),
      );
const _windows1252 = [
  0x20ac,
  0x81,
  0x201a,
  0x192,
  0x201e,
  0x2026,
  0x2020,
  0x2021,
  0x2c6,
  0x2030,
  0x160,
  0x2039,
  0x152,
  0x8d,
  0x17d,
  0x8f,
  0x90,
  0x2018,
  0x2019,
  0x201c,
  0x201d,
  0x2022,
  0x2013,
  0x2014,
  0x2dc,
  0x2122,
  0x161,
  0x203a,
  0x153,
  0x9d,
  0x17e,
  0x178,
];

Uint8List _number(int value, int width) {
  final data = ByteData(width);
  if (width == 2) {
    data.setUint16(0, value);
  } else {
    data.setUint32(0, value);
  }
  return data.buffer.asUint8List();
}

class _Bytes {
  _Bytes(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  int get remaining => bytes.length - offset;
  bool get done => remaining == 0;
  Uint8List read(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('MOBI 词头索引不完整');
    }
    final value = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return value;
  }

  int uint16() => ByteData.sublistView(read(2)).getUint16(0);
  int uint32() => ByteData.sublistView(read(4)).getUint32(0);
  int uint64() => ByteData.sublistView(read(8)).getUint64(0);
}

typedef _ExtractNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _Extract = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _AllocateNative = Pointer<Void> Function(UintPtr);
typedef _Allocate = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

class _MobiNative {
  static final _libc = DynamicLibrary.process();
  static final _allocate = _libc.lookupFunction<_AllocateNative, _Allocate>(
    'malloc',
  );
  static final _free = _libc.lookupFunction<_FreeNative, _Free>('free');
  static _Extract? _extract;

  static int extract(String source, String destination) {
    _Extract function;
    try {
      function = _extract ??= _library()
          .lookupFunction<_ExtractNative, _Extract>(
            'wenku_export_mobi_dictionary',
          );
    } catch (_) {
      throw const FormatException('此构建缺少 MOBI 词典引擎，请更新应用后重试');
    }
    final input = _string(source);
    try {
      final output = _string(destination);
      try {
        return function(input, output);
      } finally {
        _free(output.cast<Void>());
      }
    } finally {
      _free(input.cast<Void>());
    }
  }

  static DynamicLibrary _library() {
    const fixture = String.fromEnvironment('MOBI_DICTIONARY_LIBRARY');
    if (fixture.isNotEmpty) return DynamicLibrary.open(fixture);
    if (Platform.isIOS) return DynamicLibrary.process();
    return DynamicLibrary.open(
      Platform.isAndroid ? 'libwenku_mobi.so' : 'libwenku_book_engine.so',
    );
  }

  static Pointer<Uint8> _string(String value) {
    final bytes = utf8.encode(value);
    if (bytes.contains(0)) throw const FormatException('MOBI 词典路径无效');
    final pointer = _allocate(bytes.length + 1).cast<Uint8>();
    if (pointer.address == 0) throw OutOfMemoryError();
    final data = pointer.asTypedList(bytes.length + 1);
    data.setRange(0, bytes.length, bytes);
    data[bytes.length] = 0;
    return pointer;
  }
}
