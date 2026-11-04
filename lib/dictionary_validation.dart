import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blockchain_utils/crypto/crypto/hash/hash.dart';

const _maxFileBytes = 512 * 1024 * 1024;
const _maxHeaderBytes = 1024 * 1024;
const _maxBlockBytes = 16 * 1024 * 1024;
const _maxCompressedBlockBytes = _maxBlockBytes + 64 * 1024;
const _maxKeysBytes = 64 * 1024 * 1024;
const _maxRecordsBytes = 2 * 1024 * 1024 * 1024;
const _maxEntries = 1000000;

/// Validates the supported MDict envelope before the parser allocates its index.
///
/// Call this during import in a background isolate. Record blocks are expanded
/// into a counting sink, so validation does not retain a dictionary's content.
/// Key-info encryption (flag 2) is supported; encrypted records are not.
Future<void> validateMdictFile(String path) async {
  final file = File(path);
  final length = await file.length();
  if (length < 32 || length > _maxFileBytes) {
    throw const FormatException('词典文件需要在 512 MiB 以内，且内容完整');
  }
  final handle = await file.open();
  try {
    final input = _MdictInput(handle, length);
    final headerLength = await input.number(4);
    if (headerLength < 2 || headerLength > _maxHeaderBytes) {
      throw const FormatException('词典文件头大小无效');
    }
    final header = _readHeader(await input.read(headerLength));
    await input.read(4); // The format reserves a header checksum here.
    final version = double.tryParse(header['GeneratedByEngineVersion'] ?? '');
    if (version == null || version < 1 || version >= 3) {
      throw UnsupportedError('目前支持 MDX/MDD 1.x、2.x，暂不支持 3.x 格式');
    }
    final encryptionText = header['Encrypted'] ?? 'No';
    final encryption = switch (encryptionText) {
      'No' => 0,
      'Yes' => 1,
      _ => int.tryParse(encryptionText),
    };
    if (encryption == null || encryption < 0 || encryption & ~3 != 0) {
      throw const FormatException('词典加密标记无效');
    }
    if (encryption & 1 != 0) {
      throw UnsupportedError('暂不支持正文加密的词典，请选择未加密的 MDX/MDD');
    }
    if (version < 2 && encryption != 0) {
      throw UnsupportedError('暂不支持此旧版词典的加密格式');
    }

    final width = version >= 2 ? 8 : 4;
    final isMdd = path.toLowerCase().endsWith('.mdd');
    final declaredEncoding = header['Encoding'];
    final encoding =
        (declaredEncoding == null || declaredEncoding.isEmpty
                ? (isMdd ? 'UTF-16' : 'UTF-8')
                : declaredEncoding)
            .toUpperCase();
    final utf16 =
        encoding == 'UTF-16' ||
        encoding == 'UTF-16LE' ||
        encoding == 'UTF-16BE';
    final keyBlocks = await input.number(width);
    final entries = await input.number(width);
    _checkCount(entries, '词条');
    if (keyBlocks < 1 || keyBlocks > entries) {
      throw const FormatException('词典索引块数量无效');
    }
    final declaredInfoLength = version >= 2 ? await input.number(width) : null;
    if (declaredInfoLength != null &&
        (declaredInfoLength < 1 || declaredInfoLength > _maxBlockBytes)) {
      throw const FormatException('词典索引说明展开后过大');
    }
    final infoLength = await input.number(width);
    final keysLength = await input.number(width);
    if (infoLength < 1 ||
        infoLength > _maxCompressedBlockBytes ||
        keysLength < 8 ||
        keysLength > _maxKeysBytes) {
      throw const FormatException('词典索引大小无效或过大');
    }
    if (version >= 2) await input.read(4);
    var keyInfo = await input.read(infoLength);
    if (version >= 2) {
      if (encryption & 2 != 0) keyInfo = _decryptKeyInfo(keyInfo);
      if (keyInfo.length < 8 ||
          ByteData.sublistView(keyInfo).getUint32(0, Endian.little) != 2) {
        throw UnsupportedError('暂不支持此词典的索引压缩方式');
      }
      keyInfo = _expandBlock(keyInfo, declaredInfoLength!);
    }
    final metadata = _keyMetadata(keyInfo, version, width, utf16);
    if (metadata.length != keyBlocks ||
        metadata.fold<int>(0, (sum, block) => sum + block.entries) != entries ||
        metadata.fold<int>(0, (sum, block) => sum + block.compressed) !=
            keysLength) {
      throw const FormatException('词典索引数量与文件声明不一致');
    }

    var expandedKeys = 0;
    var actualEntries = 0;
    var previousRecord = -1;
    for (final block in metadata) {
      expandedKeys += block.expanded;
      if (expandedKeys > _maxKeysBytes) {
        throw const FormatException('词典索引展开后超过 64 MiB');
      }
      final keys = _expandBlock(
        await input.read(block.compressed),
        block.expanded,
      );
      final offsets = _keyOffsets(keys, width, utf16);
      if (offsets.length != block.entries) {
        throw const FormatException('词典索引块的词条数量不一致');
      }
      for (final offset in offsets) {
        if (offset < previousRecord || offset > _maxRecordsBytes) {
          throw const FormatException('词典词条位置无效');
        }
        previousRecord = offset;
      }
      actualEntries += offsets.length;
    }
    if (actualEntries != entries) {
      throw const FormatException('词典词条数量不一致');
    }

    final recordBlocks = await input.number(width);
    final recordEntries = await input.number(width);
    final recordInfoLength = await input.number(width);
    final recordsLength = await input.number(width);
    if (recordBlocks < 1 ||
        recordBlocks > _maxEntries ||
        recordEntries != entries ||
        recordInfoLength != recordBlocks * width * 2 ||
        recordInfoLength > _maxBlockBytes ||
        recordsLength < 8 ||
        recordsLength > _maxFileBytes) {
      throw const FormatException('词典正文目录与索引不一致');
    }
    final recordInfo = _Bytes(await input.read(recordInfoLength));
    final recordMetadata = <(int, int)>[];
    var compressedRecords = 0;
    var expandedRecords = 0;
    for (var i = 0; i < recordBlocks; i++) {
      final compressed = recordInfo.number(width);
      final expanded = recordInfo.number(width);
      _checkBlockSizes(compressed, expanded);
      compressedRecords += compressed;
      expandedRecords += expanded;
      if (compressedRecords > recordsLength ||
          expandedRecords > _maxRecordsBytes) {
        throw const FormatException('词典正文展开后过大或文件已损坏');
      }
      recordMetadata.add((compressed, expanded));
    }
    if (compressedRecords != recordsLength ||
        previousRecord > expandedRecords) {
      throw const FormatException('词典正文位置与索引不一致');
    }
    for (final (compressed, expanded) in recordMetadata) {
      _expandBlock(await input.read(compressed), expanded, retain: false);
    }
  } finally {
    await handle.close();
  }
}

Map<String, String> _readHeader(Uint8List bytes) {
  String text;
  if (bytes.length >= 2 &&
      bytes[bytes.length - 1] == 0 &&
      bytes[bytes.length - 2] == 0 &&
      bytes.length.isEven) {
    final data = ByteData.sublistView(bytes);
    text = String.fromCharCodes([
      for (var i = 0; i < bytes.length - 2; i += 2)
        data.getUint16(i, Endian.little),
    ]);
  } else {
    if (bytes.last != 0) throw const FormatException('词典文件头不完整');
    text = utf8.decode(Uint8List.sublistView(bytes, 0, bytes.length - 1));
  }
  return {
    for (final match in RegExp(r'(\w+)="(.*?)"', dotAll: true).allMatches(text))
      match[1]!: match[2]!,
  };
}

void _checkCount(int count, String label) {
  if (count < 1 || count > _maxEntries) {
    throw FormatException('词典$label数量无效或超过 100 万');
  }
}

void _checkBlockSizes(int compressed, int expanded) {
  if (compressed < 8 ||
      compressed > _maxCompressedBlockBytes ||
      expanded < 0 ||
      expanded > _maxBlockBytes) {
    throw const FormatException('词典单个数据块无效或展开后超过 16 MiB');
  }
}

class _KeyMetadata {
  const _KeyMetadata(this.entries, this.compressed, this.expanded);
  final int entries, compressed, expanded;
}

List<_KeyMetadata> _keyMetadata(
  Uint8List bytes,
  double version,
  int width,
  bool utf16,
) {
  final input = _Bytes(bytes);
  final out = <_KeyMetadata>[];
  while (!input.done) {
    final count = input.number(width);
    _checkCount(count, '索引块词条');
    for (var end = 0; end < 2; end++) {
      final characters = input.number(version >= 2 ? 2 : 1);
      final term = version >= 2 ? 1 : 0;
      final text = input.read((characters + term) * (utf16 ? 2 : 1));
      if (term != 0 &&
          (text.last != 0 || (utf16 && text[text.length - 2] != 0))) {
        throw const FormatException('词典索引边界词条不完整');
      }
    }
    final compressed = input.number(width), expanded = input.number(width);
    _checkBlockSizes(compressed, expanded);
    out.add(_KeyMetadata(count, compressed, expanded));
    if (out.length > _maxEntries) {
      throw const FormatException('词典索引块过多');
    }
  }
  return out;
}

List<int> _keyOffsets(Uint8List bytes, int width, bool utf16) {
  final input = _Bytes(bytes);
  final offsets = <int>[];
  while (!input.done) {
    offsets.add(input.number(width));
    var terminated = false;
    while (!input.done) {
      final first = input.number(1);
      final second = utf16 ? input.number(1) : 0;
      if (first == 0 && second == 0) {
        terminated = true;
        break;
      }
    }
    if (!terminated) throw const FormatException('词典词条名称未结束');
    if (offsets.length > _maxEntries) {
      throw const FormatException('词典词条过多');
    }
  }
  return offsets;
}

Uint8List _decryptKeyInfo(Uint8List bytes) {
  if (bytes.length < 8) throw const FormatException('词典加密索引不完整');
  final result = Uint8List.fromList(bytes);
  final key = RIPEMD128.hash([...bytes.sublist(4, 8), 149, 54, 0, 0]);
  var previous = 0x36;
  for (var i = 8; i < result.length; i++) {
    final encrypted = result[i];
    result[i] =
        (((encrypted >> 4) | (encrypted << 4)) & 255) ^
        previous ^
        ((i - 8) & 255) ^
        key[(i - 8) % key.length];
    previous = encrypted;
  }
  return result;
}

Uint8List _expandBlock(Uint8List bytes, int expected, {bool retain = true}) {
  if (bytes.length < 8) throw const FormatException('词典数据块不完整');
  final compression = ByteData.sublistView(bytes).getUint32(0, Endian.little);
  if (compression == 1) {
    throw UnsupportedError('暂不支持 LZO 压缩词典，请选择 zlib 或未压缩版本');
  }
  if (compression != 0 && compression != 2) {
    throw UnsupportedError('暂不支持此词典的数据压缩方式');
  }
  if (compression == 0) {
    final data = Uint8List.sublistView(bytes, 8);
    if (data.length != expected || data.length > _maxBlockBytes) {
      throw const FormatException('词典数据块长度与声明不一致');
    }
    return retain ? data : Uint8List(0);
  }
  final sink = _BoundedSink(expected, retain);
  try {
    final decoder = ZLibDecoder().startChunkedConversion(sink);
    for (var offset = 8; offset < bytes.length; offset += 65536) {
      final end = offset + 65536 < bytes.length ? offset + 65536 : bytes.length;
      decoder.add(Uint8List.sublistView(bytes, offset, end));
    }
    decoder.close();
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('词典压缩数据损坏');
  }
  if (sink.length != expected) {
    throw const FormatException('词典数据块展开长度与声明不一致');
  }
  return sink.bytes?.takeBytes() ?? Uint8List(0);
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.expected, bool retain)
    : bytes = retain ? BytesBuilder(copy: false) : null;
  final int expected;
  final BytesBuilder? bytes;
  int length = 0;
  @override
  void add(List<int> data) {
    length += data.length;
    if (length > expected || length > _maxBlockBytes) {
      throw const FormatException('词典压缩数据展开超过声明大小');
    }
    bytes?.add(data);
  }

  @override
  void close() {}
}

class _Bytes {
  _Bytes(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  bool get done => offset == bytes.length;
  Uint8List read(int count) {
    if (count < 0 || offset + count > bytes.length) {
      throw const FormatException('词典数据不完整或位置越界');
    }
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  int number(int width) {
    final data = ByteData.sublistView(read(width));
    final value = switch (width) {
      1 => data.getUint8(0),
      2 => data.getUint16(0, Endian.big),
      4 => data.getUint32(0, Endian.big),
      8 => data.getUint64(0, Endian.big),
      _ => throw const FormatException('词典数字宽度无效'),
    };
    if (value < 0) throw const FormatException('词典数据位置过大');
    return value;
  }
}

class _MdictInput {
  _MdictInput(this.file, this.length);
  final RandomAccessFile file;
  final int length;
  int offset = 0;
  Future<Uint8List> read(int count) async {
    if (count < 0 || offset + count > length) {
      throw const FormatException('词典文件不完整或数据越界');
    }
    final bytes = await file.read(count);
    if (bytes.length != count) throw const FormatException('词典读取不完整');
    offset += count;
    return bytes;
  }

  Future<int> number(int width) async =>
      _Bytes(await read(width)).number(width);
}
