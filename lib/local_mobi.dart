import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;

import 'chapter_splitter.dart';

class MobiBookData {
  const MobiBookData({
    required this.title,
    required this.author,
    required this.description,
    required this.text,
    required this.chapters,
  });

  final String title;
  final String author;
  final String description;
  final String text;
  final List<LocalChapterIndex> chapters;
}

bool isMobiFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.mobi') ||
      lower.endsWith('.azw3') ||
      lower.endsWith('.azw') ||
      lower.endsWith('.prc');
}

/// Decompresses a single PalmDOC LZ77 compressed record.
Uint8List decompressPalmDocLz77(Uint8List input) {
  final out = BytesBuilder(copy: false);
  final buffer = <int>[];
  var i = 0;
  final len = input.length;
  while (i < len) {
    final b = input[i++];
    if (b == 0x00) {
      buffer.add(0x00);
    } else if (b >= 0x01 && b <= 0x08) {
      final end = math.min(len, i + b);
      while (i < end) {
        buffer.add(input[i++]);
      }
    } else if (b >= 0x09 && b <= 0x7F) {
      buffer.add(b);
    } else if (b >= 0x80 && b <= 0xBF) {
      if (i >= len) break;
      final next = input[i++];
      final pair = ((b << 8) | next) & 0x3FFF;
      final distance = pair >> 3;
      final length = (pair & 0x07) + 3;
      if (distance <= 0 || distance > buffer.length) continue;
      final start = buffer.length - distance;
      for (var k = 0; k < length; k++) {
        buffer.add(buffer[start + k]);
      }
    } else {
      // 0xC0..0xFF: space (0x20) followed by (b ^ 0x80).
      buffer.add(0x20);
      buffer.add(b ^ 0x80);
    }
  }
  out.add(buffer);
  return out.takeBytes();
}

int _readUint16BE(Uint8List bytes, int offset) {
  if (offset + 2 > bytes.length) return 0;
  return (bytes[offset] << 8) | bytes[offset + 1];
}

int _readUint32BE(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return ((bytes[offset] << 24) >>> 0) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

Uint8List _trimRecordTrailingBytes(Uint8List record, int extraDataFlags) {
  if (extraDataFlags == 0 || record.isEmpty) return record;
  var end = record.length;
  // Bits 1..15: variable-length backward-encoded size at end of record.
  for (var bit = 15; bit >= 1; bit--) {
    if ((extraDataFlags & (1 << bit)) == 0) continue;
    var size = 0;
    var shift = 0;
    var pos = end - 1;
    while (pos >= 0 && shift < 28) {
      final b = record[pos--];
      size |= (b & 0x7F) << shift;
      shift += 7;
      if ((b & 0x80) != 0) break;
    }
    if (size > 0 && size <= end) {
      end -= size;
    }
  }
  // Bit 0: multibyte character overlap count in low 2 bits of final byte.
  if ((extraDataFlags & 1) != 0 && end > 0) {
    final overlap = (record[end - 1] & 0x03) + 1;
    if (overlap <= end) {
      end -= overlap;
    }
  }
  return end == record.length ? record : Uint8List.sublistView(record, 0, end);
}

String _decodeMobiBytes(Uint8List bytes, int textEncoding) {
  if (textEncoding == 1252) {
    return latin1.decode(bytes, allowInvalid: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Converts MOBI / KF8 HTML markup into clean plain text with preserved
/// headings and paragraph breaks suitable for [splitLocalChapters].
String _mobiHtmlToText(String rawMarkup) {
  if (!rawMarkup.contains('<') && !rawMarkup.contains('&')) {
    return rawMarkup.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  }
  final normalized = rawMarkup
      .replaceAll(
        RegExp(r'<mbp:pagebreak\s*/?>', caseSensitive: false),
        '\n\n',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</(p|div|h[1-6]|li|tr|blockquote|section|article)>',
            caseSensitive: false),
        '\n\n',
      );
  final doc = html_parser.parse(normalized);
  for (final noisy in doc.querySelectorAll('script, style, head')) {
    noisy.remove();
  }
  final bodyText = doc.body?.text ?? doc.text ?? '';
  final lines = bodyText
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final cleaned = <String>[];
  var blankCount = 0;
  for (final rawLine in lines) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) {
      blankCount++;
      if (blankCount <= 1 && cleaned.isNotEmpty) {
        cleaned.add('');
      }
    } else {
      blankCount = 0;
      cleaned.add(line.trimLeft());
    }
  }
  return cleaned.join('\n').trim();
}

/// Parses a `.mobi`, `.azw3`, `.azw`, or `.prc` file in pure Dart.
MobiBookData extractMobiBook(
  Uint8List bytes, {
  String fallbackTitle = '未命名书籍',
}) {
  if (bytes.length < 78) {
    throw const FormatException('MOBI/AZW3 文件头过短或已损坏');
  }
  final magic = ascii.decode(
    Uint8List.sublistView(bytes, 60, 68),
    allowInvalid: true,
  );
  if (magic != 'BOOKMOBI' && magic != 'TEXtREAd') {
    throw const FormatException('不是有效的 MOBI / AZW3 电子书文件');
  }

  final recordCount = _readUint16BE(bytes, 76);
  if (recordCount < 2 || 78 + recordCount * 8 > bytes.length) {
    throw const FormatException('MOBI/AZW3 记录索引损坏');
  }

  final offsets = <int>[];
  for (var i = 0; i < recordCount; i++) {
    offsets.add(_readUint32BE(bytes, 78 + i * 8));
  }

  Uint8List recordAt(int index) {
    final start = offsets[index];
    final end = index + 1 < offsets.length ? offsets[index + 1] : bytes.length;
    if (start < 0 || start >= bytes.length || end <= start) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(bytes, start, math.min(end, bytes.length));
  }

  final pdbTitleBytes = Uint8List.sublistView(bytes, 0, 32);
  final zeroIdx = pdbTitleBytes.indexOf(0);
  final pdbTitle = utf8
      .decode(
        zeroIdx >= 0
            ? Uint8List.sublistView(pdbTitleBytes, 0, zeroIdx)
            : pdbTitleBytes,
        allowMalformed: true,
      )
      .trim();

  String ExtractHeaderAndText(int headerRecordIndex) {
    final rec0 = recordAt(headerRecordIndex);
    if (rec0.length < 16) return '';
    final compression = _readUint16BE(rec0, 0);
    final textRecordCount = _readUint16BE(rec0, 8);
    if (compression != 1 && compression != 2) {
      throw const FormatException('暂不支持 Huff/CDIC 或受 DRM 加密的 MOBI/AZW3 文件');
    }
    var textEncoding = 65001;
    var extraDataFlags = 0;
    if (rec0.length >= 32) {
      final mobiMagic = ascii.decode(
        Uint8List.sublistView(rec0, 16, 20),
        allowInvalid: true,
      );
      if (mobiMagic == 'MOBI') {
        final headerLen = _readUint32BE(rec0, 20);
        textEncoding = _readUint32BE(rec0, 28);
        if (headerLen >= 0xE4 && rec0.length >= 16 + 0xF4) {
          extraDataFlags = _readUint16BE(rec0, 16 + 0xF2);
        }
      }
    }
    final textBytes = BytesBuilder(copy: false);
    final maxRec = math.min(recordCount - 1, headerRecordIndex + textRecordCount);
    for (var r = headerRecordIndex + 1; r <= maxRec; r++) {
      final rawRec = recordAt(r);
      if (rawRec.isEmpty) continue;
      final trimmed = _trimRecordTrailingBytes(rawRec, extraDataFlags);
      if (compression == 2) {
        textBytes.add(decompressPalmDocLz77(trimmed));
      } else {
        textBytes.add(trimmed);
      }
    }
    final decoded = _decodeMobiBytes(textBytes.takeBytes(), textEncoding);
    return _mobiHtmlToText(decoded);
  }

  final rec0 = recordAt(0);
  var textEncoding = 65001;
  var title = '';
  var author = '';
  var description = '';

  if (rec0.length >= 32) {
    final mobiMagic = ascii.decode(
      Uint8List.sublistView(rec0, 16, 20),
      allowInvalid: true,
    );
    if (mobiMagic == 'MOBI') {
      final headerLen = _readUint32BE(rec0, 20);
      textEncoding = _readUint32BE(rec0, 28);
      final fullNameOffset = _readUint32BE(rec0, 84);
      final fullNameLength = _readUint32BE(rec0, 88);
      if (fullNameOffset > 0 &&
          fullNameLength > 0 &&
          fullNameOffset + fullNameLength <= rec0.length) {
        title = _decodeMobiBytes(
          Uint8List.sublistView(
            rec0,
            fullNameOffset,
            fullNameOffset + fullNameLength,
          ),
          textEncoding,
        ).trim();
      }
      final exthFlags = rec0.length >= 132 ? _readUint32BE(rec0, 128) : 0;
      final exthStart = 16 + headerLen;
      if ((exthFlags & 0x40) != 0 && exthStart + 12 <= rec0.length) {
        final exthMagic = ascii.decode(
          Uint8List.sublistView(rec0, exthStart, exthStart + 4),
          allowInvalid: true,
        );
        if (exthMagic == 'EXTH') {
          final exthCount = _readUint32BE(rec0, exthStart + 8);
          var pos = exthStart + 12;
          for (var i = 0; i < exthCount && pos + 8 <= rec0.length; i++) {
            final recType = _readUint32BE(rec0, pos);
            final recLen = _readUint32BE(rec0, pos + 4);
            if (recLen < 8 || pos + recLen > rec0.length) break;
            final payload = Uint8List.sublistView(
              rec0,
              pos + 8,
              pos + recLen,
            );
            final value = _decodeMobiBytes(payload, textEncoding).trim();
            if (value.isNotEmpty) {
              if (recType == 100 && author.isEmpty) {
                author = value;
              } else if (recType == 503) {
                title = value;
              } else if (recType == 103 && description.isEmpty) {
                description = _mobiHtmlToText(value);
              }
            }
            pos += recLen;
          }
        }
      }
    }
  }

  var text = ExtractHeaderAndText(0);
  // Check for hybrid KF8/AZW3 BOUNDARY record if primary text is empty.
  if (text.isEmpty) {
    for (var i = 1; i < recordCount - 1; i++) {
      final rec = recordAt(i);
      if (rec.length == 8 &&
          ascii.decode(rec, allowInvalid: true) == 'BOUNDARY') {
        text = ExtractHeaderAndText(i + 1);
        if (text.isNotEmpty) break;
      }
    }
  }
  if (text.isEmpty) {
    throw const FormatException('MOBI/AZW3 正文内容为空');
  }

  final effectiveTitle = title.isNotEmpty
      ? title
      : pdbTitle.isNotEmpty
      ? pdbTitle
      : fallbackTitle;
  final chapters = splitLocalChapters(text);

  return MobiBookData(
    title: effectiveTitle,
    author: author,
    description: description,
    text: text,
    chapters: chapters,
  );
}
