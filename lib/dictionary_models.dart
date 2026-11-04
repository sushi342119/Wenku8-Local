import 'dart:typed_data';

/// One app-owned source file and its reusable offline lookup index.
class DictionaryAsset {
  const DictionaryAsset({
    required this.file,
    required this.sourceName,
    required this.entries,
    required this.bytes,
  });
  final String file, sourceName;
  final int entries, bytes;
  String get indexFile => '$file.index';
  Map<String, Object> toJson() => {
    'file': file,
    'sourceName': sourceName,
    'entries': entries,
    'bytes': bytes,
  };
  factory DictionaryAsset.fromJson(Map<String, dynamic> value) {
    final file = value['file'], name = value['sourceName'];
    final entries = value['entries'], bytes = value['bytes'];
    if (file is! String ||
        !RegExp(r'^[a-z0-9-]+\.(mdx|mdd|ifo|mobi)$').hasMatch(file) ||
        name is! String ||
        name.length > 1024 ||
        entries is! int ||
        entries < 0 ||
        entries > 1000000 ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > 512 * 1024 * 1024) {
      throw const FormatException('词典文件记录有误');
    }
    return DictionaryAsset(
      file: file,
      sourceName: name,
      entries: entries,
      bytes: bytes,
    );
  }
}

/// Priority is the position in the persisted library, not an unstable filename.
class UserDictionary {
  const UserDictionary({
    required this.id,
    required this.name,
    required this.source,
    this.resources = const [],
    this.enabled = true,
    this.format = 'mdict',
    this.storedBytes = 0,
  });
  final String id, name, format;
  final DictionaryAsset source;
  final List<DictionaryAsset> resources;
  final bool enabled;
  final int storedBytes;
  int get bytes => storedBytes > 0
      ? storedBytes
      : source.bytes + resources.fold(0, (sum, file) => sum + file.bytes);
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'source': source.toJson(),
    'resources': resources.map((asset) => asset.toJson()).toList(),
    'enabled': enabled,
    'format': format,
    'storedBytes': storedBytes,
  };
  factory UserDictionary.fromJson(Map<String, dynamic> value) {
    final id = value['id'],
        name = value['name'],
        resources = value['resources'];
    if (id is! String ||
        !RegExp(r'^dict-[a-z0-9-]{1,72}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 160 ||
        value['source'] is! Map ||
        resources is! List ||
        resources.length > 63 ||
        value['enabled'] is! bool ||
        !const [
          'mdict',
          'stardict',
          'mobi',
        ].contains(value['format'] ?? 'mdict') ||
        value['storedBytes'] is! int ||
        (value['storedBytes'] as int) < 0 ||
        (value['storedBytes'] as int) > 8 * 1024 * 1024 * 1024) {
      throw const FormatException('词典目录记录有误');
    }
    final source = DictionaryAsset.fromJson(
      Map<String, dynamic>.from(value['source']),
    );
    final format = (value['format'] ?? 'mdict') as String;
    final extension = switch (format) {
      'mdict' => '.mdx',
      'stardict' => '.ifo',
      _ => '.mobi',
    };
    if (!source.file.endsWith(extension) ||
        (format == 'mobi' && resources.isNotEmpty)) {
      throw const FormatException('词典正文记录有误');
    }
    final files = resources
        .map((item) {
          if (item is! Map) throw const FormatException('词典资源记录有误');
          final asset = DictionaryAsset.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (!asset.file.endsWith('.mdd')) {
            throw const FormatException('词典资源记录有误');
          }
          return asset;
        })
        .toList(growable: false);
    if ({source.file, ...files.map((asset) => asset.file)}.length !=
        files.length + 1) {
      throw const FormatException('词典文件记录重复');
    }
    return UserDictionary(
      id: id,
      name: name,
      source: source,
      resources: List.unmodifiable(files),
      enabled: value['enabled'],
      format: format,
      storedBytes: value['storedBytes'],
    );
  }
  UserDictionary copyWith({
    String? name,
    bool? enabled,
    List<DictionaryAsset>? resources,
    int? storedBytes,
  }) => UserDictionary(
    id: id,
    name: name ?? this.name,
    source: source,
    resources: resources ?? this.resources,
    enabled: enabled ?? this.enabled,
    format: format,
    storedBytes: storedBytes ?? this.storedBytes,
  );
}

/// Safe, native-rendered dictionary content; HTML scripts and network URLs never run.
class DictionaryDefinition {
  const DictionaryDefinition(
    this.word,
    this.text, {
    this.images = const [],
    this.related = const [],
    this.resourceWarning = false,
  });
  final String word, text;
  final List<Uint8List> images;
  final List<String> related;
  final bool resourceWarning;
}

/// Each dictionary retains its own empty/error state within aggregate lookup.
class DictionaryLookupGroup {
  const DictionaryLookupGroup(
    this.dictionary, {
    this.definitions = const [],
    this.error,
  });
  final UserDictionary dictionary;
  final List<DictionaryDefinition> definitions;
  final String? error;
}

class DictionaryImportReport {
  const DictionaryImportReport(this.imported, this.errors);
  final List<UserDictionary> imported;
  final List<String> errors;
}
