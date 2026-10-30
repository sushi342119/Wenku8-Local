import 'dart:convert';

/// Filename suffix tags and the original name with only those tags removed.
class ParsedFilenameTags {
  const ParsedFilenameTags({required this.baseFilename, required this.tags});

  /// Includes the original extension, with its original case.
  final String baseFilename;
  final List<String> tags;
}

bool isValidFilenameTag(String tag) =>
    tag.isNotEmpty &&
    !tag.contains('✦') &&
    tag != '.' &&
    tag != '..' &&
    utf8.encode(tag).length <= 64 &&
    !tag.runes.any(
      (rune) =>
          (rune >= 0x0009 && rune <= 0x000D) ||
          rune == 0x0020 ||
          rune == 0x0085 ||
          rune == 0x00A0 ||
          rune == 0x1680 ||
          (rune >= 0x2000 && rune <= 0x200A) ||
          rune == 0x2028 ||
          rune == 0x2029 ||
          rune == 0x202F ||
          rune == 0x205F ||
          rune == 0x3000 ||
          rune == 0xFEFF,
    ) &&
    !RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]').hasMatch(tag);

({String stem, String extension}) _splitExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0) return (stem: filename, extension: '');
  return (stem: filename.substring(0, dot), extension: filename.substring(dot));
}

/// Reads the maximal consecutive valid ` ✦tag` suffix before the extension.
/// An empty/whitespace-containing segment stops parsing; ordinary title text,
/// including earlier invalid segments and download markers, remains untouched.
ParsedFilenameTags parseFilenameTags(String filename) {
  final split = _splitExtension(filename);
  var stem = split.stem;
  final reversed = <String>[];
  while (true) {
    final marker = stem.lastIndexOf(' ✦');
    if (marker < 0) break;
    final tag = stem.substring(marker + 2);
    if (!isValidFilenameTag(tag)) break;
    reversed.add(tag);
    stem = stem.substring(0, marker);
  }
  return ParsedFilenameTags(
    baseFilename: reversed.isEmpty ? filename : '$stem${split.extension}',
    tags: List.unmodifiable(reversed.reversed),
  );
}

String stripFilenameTags(String filename) =>
    parseFilenameTags(filename).baseFilename;

/// Appends distinct tags before the extension, retaining existing suffix tags.
/// With no incoming tags the filename is returned byte-for-byte unchanged.
/// To replace/clear tags, pass [stripFilenameTags]'s result as the filename.
String appendFilenameTags(String filename, Iterable<String> tags) {
  final incoming = tags.toList();
  for (final tag in incoming) {
    if (!isValidFilenameTag(tag)) {
      throw ArgumentError('标签名包含文件名不允许的字符或过长');
    }
  }
  if (incoming.isEmpty) return filename;
  final parsed = parseFilenameTags(filename);
  final all = {...parsed.tags, ...incoming};
  final split = _splitExtension(parsed.baseFilename);
  final result =
      '${split.stem}${all.map((tag) => ' ✦$tag').join()}${split.extension}';
  if (utf8.encode(result).length > 255) {
    throw ArgumentError('标签拼接后的文件名过长');
  }
  return result;
}
