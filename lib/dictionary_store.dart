import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'book_documents.dart';
import 'dictionary_engine.dart';
import 'dictionary_models.dart';
import 'dictionary_mobi.dart';
import 'dictionary_stardict.dart';

export 'dictionary_models.dart';

/// A local-only library. Successful imports own their private copies; no later
/// lookup depends on a temporary document grant or an Internet connection.
class DictionaryStore extends ChangeNotifier {
  DictionaryStore({Directory? directory}) : _directory = directory;
  static final shared = DictionaryStore();
  Directory? _directory;
  Future<void>? _loading;
  Future<void> _mutations = Future.value();
  final _engine = DictionaryEngine();
  List<UserDictionary> _dictionaries = const [];
  bool _disposed = false;
  List<UserDictionary> get dictionaries => List.unmodifiable(_dictionaries);

  int createLookupSession() => _engine.createSession();
  Future<void> cancelLookupSession(int session) =>
      _engine.cancelSession(session);
  @visibleForTesting
  int get debugLookupSessionCount => _engine.activeSessionCount;

  Future<Directory> _root() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/reader-dictionaries',
  );

  /// Reads only the small registry; dictionary indexes are loaded lazily.
  Future<void> load() => _loading ??=
      () async {
        final file = File('${(await _root()).path}/dictionaries.json');
        if (!await file.exists()) return;
        if (await file.length() > 512 * 1024) {
          throw const FormatException('词典目录记录过大');
        }
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map ||
            raw['schema'] != 1 ||
            raw['dictionaries'] is! List ||
            (raw['dictionaries'] as List).length > 64) {
          throw const FormatException('词典目录记录有误，请保留文件并重试');
        }
        final values = (raw['dictionaries'] as List)
            .map((item) {
              if (item is! Map) throw const FormatException('词典目录记录有误');
              return UserDictionary.fromJson(Map<String, dynamic>.from(item));
            })
            .toList(growable: false);
        if (values.map((item) => item.id).toSet().length != values.length) {
          throw const FormatException('词典目录包含重复记录');
        }
        _dictionaries = values;
      }().catchError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final operation = _mutations.then((_) => action());
    _mutations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _save(List<UserDictionary> values) async {
    for (final item in values) {
      UserDictionary.fromJson(item.toJson());
    }
    final encoded = jsonEncode({
      'schema': 1,
      'dictionaries': values.map((item) => item.toJson()).toList(),
    });
    if (utf8.encode(encoded).length > 512 * 1024) {
      throw const FormatException('词典目录记录过大，请先移除不用的词典');
    }
    final root = await _root();
    await root.create(recursive: true);
    final part = File('${root.path}/dictionaries.json.part');
    await part.writeAsString(encoded, flush: true);
    await part.rename('${root.path}/dictionaries.json');
    _dictionaries = List.unmodifiable(values);
    if (!_disposed) notifyListeners();
  }

  /// Accepts MDX/MDD, MOBI dictionaries or complete StarDict file sets/ZIP bundles.
  /// Each dictionary commits independently; malformed groups never replace an
  /// already imported dictionary or remove the user's original files.
  Future<DictionaryImportReport> importFiles(
    List<BookDocumentSelection> selected,
  ) => _exclusive(() async {
    await load();
    final root = await _root();
    await root.create(recursive: true);
    final token =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x100000000).toRadixString(36)}';
    final staging = Directory('${root.path}/staging-$token');
    final imported = <UserDictionary>[], errors = <String>[];
    try {
      final inputs = <(String, String)>[];
      for (final file in selected) {
        if (file.path == null) {
          errors.add('${file.name}：${file.error ?? '文件不可读'}');
        } else {
          inputs.add((file.name, file.path!));
        }
      }
      final files = await compute(_prepareSelectionJob, (inputs, staging.path));
      final used = <String>{};
      final primaries = files.where(
        (file) =>
            file.$1.toLowerCase().endsWith('.mdx') ||
            file.$1.toLowerCase().endsWith('.ifo') ||
            file.$1.toLowerCase().endsWith('.mobi'),
      );
      var ordinal = 0;
      for (final primary in primaries) {
        if (_dictionaries.length >= 64) {
          errors.add('最多保留 64 部词典，请先移除不用的词典');
          break;
        }
        final id = 'dict-$token-${ordinal++}';
        final directory = Directory('${root.path}/$id');
        final format = primary.$1.toLowerCase().endsWith('.mdx')
            ? 'mdict'
            : primary.$1.toLowerCase().endsWith('.mobi')
            ? 'mobi'
            : 'stardict';
        final stem = primary.$1.substring(0, primary.$1.lastIndexOf('.'));
        final group = files
            .where(
              (file) => format == 'mobi'
                  ? file == primary
                  : format == 'mdict'
                  ? file == primary || _mddMatches(stem, file.$1)
                  : file.$1.toLowerCase().startsWith(
                          '${stem.toLowerCase()}.',
                        ) &&
                        const [
                          'ifo',
                          'idx',
                          'idx.gz',
                          'dict',
                          'dict.dz',
                          'syn',
                        ].contains(
                          file.$1.substring(stem.length + 1).toLowerCase(),
                        ),
            )
            .toList();
        for (final file in group) {
          used.add(file.$2);
        }
        try {
          final dictionary = await compute(_importGroupJob, (
            id,
            directory.path,
            primary,
            group,
            format,
          ));
          await _save([..._dictionaries, dictionary]);
          imported.add(dictionary);
        } catch (error) {
          if (await directory.exists()) await directory.delete(recursive: true);
          errors.add('${_leaf(primary.$1)}：${_errorText(error)}');
        }
      }
      // Resource-only import is convenient after an MDX was imported earlier.
      for (final file in files.where((file) => !used.contains(file.$2))) {
        if (!file.$1.toLowerCase().endsWith('.mdd')) {
          errors.add('${_leaf(file.$1)}：请选择完整的 MDX、StarDict 或 MOBI 词典');
          continue;
        }
        final matching = _dictionaries
            .where(
              (dictionary) =>
                  dictionary.format == 'mdict' &&
                  _mddMatches(
                    dictionary.source.sourceName.replaceFirst(
                      RegExp(r'\.mdx$', caseSensitive: false),
                      '',
                    ),
                    _leaf(file.$1),
                  ),
            )
            .toList();
        if (matching.length != 1) {
          errors.add('${_leaf(file.$1)}：未找到唯一同名 MDX，请将它们一起选择导入');
          continue;
        }
        final current = matching.single;
        if (current.resources.any(
          (asset) =>
              asset.sourceName.toLowerCase() == _leaf(file.$1).toLowerCase(),
        )) {
          errors.add('${_leaf(file.$1)}：这个资源包已导入；更换时请将 MDX 和新 MDD 一起重新导入');
          continue;
        }
        if (current.resources.length >= 63) {
          errors.add('这部词典的资源文件已达上限');
          continue;
        }
        final filename = 'resource-$token-${ordinal++}.mdd';
        final path = '${root.path}/${current.id}/$filename';
        try {
          final updated = await compute(_attachResourceJob, (
            current,
            file,
            path,
            filename,
            '${root.path}/${current.id}',
          ));
          await _save(
            _dictionaries
                .map((item) => item.id == current.id ? updated : item)
                .toList(),
          );
          imported.add(updated);
        } catch (error) {
          for (final target in [File(path), File('$path.index')]) {
            if (await target.exists()) await target.delete();
          }
          errors.add('${_leaf(file.$1)}：${_errorText(error)}');
        }
      }
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    return DictionaryImportReport(
      List.unmodifiable(imported),
      List.unmodifiable(errors),
    );
  });

  Future<void> setEnabled(String id, bool enabled) => _exclusive(() async {
    await load();
    await _save(
      _dictionaries
          .map((item) => item.id == id ? item.copyWith(enabled: enabled) : item)
          .toList(),
    );
  });

  Future<void> rename(String id, String name) => _exclusive(() async {
    await load();
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 160) {
      throw const FormatException('词典名称需要在 1–160 字以内');
    }
    await _save(
      _dictionaries
          .map((item) => item.id == id ? item.copyWith(name: clean) : item)
          .toList(),
    );
  });

  Future<void> reorder(int from, int to) => _exclusive(() async {
    await load();
    if (from < 0 ||
        from >= _dictionaries.length ||
        to < 0 ||
        to > _dictionaries.length) {
      return;
    }
    final values = [..._dictionaries];
    final item = values.removeAt(from);
    values.insert(to > from ? to - 1 : to, item);
    await _save(values);
  });

  Future<void> remove(String id) => _exclusive(() async {
    await load();
    final dictionary = _dictionaries.where((item) => item.id == id).firstOrNull;
    if (dictionary == null) return;
    final root = await _root();
    await _save(_dictionaries.where((item) => item.id != id).toList());
    await _engine.drop(
      [
        dictionary.source,
        ...dictionary.resources,
      ].map((asset) => '${root.path}/$id/${asset.file}').toList(),
    );
    final directory = Directory('${root.path}/$id');
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// Keeps one failure local to its dictionary and retains the user's priority.
  Future<List<DictionaryLookupGroup>> lookup(
    String text, {
    int? session,
    int generation = 0,
  }) async {
    await load();
    final query = text.trim();
    if (query.isEmpty) return const [];
    if (query.runes.length > 128) {
      throw const FormatException('请选择一个词语或较短的句子查询');
    }
    final root = await _root();
    return Future.wait(
      _dictionaries.where((item) => item.enabled).map((dictionary) async {
        try {
          final definitions = await _engine.lookup(
            query,
            {
              'path': '${root.path}/${dictionary.id}/${dictionary.source.file}',
              'format': dictionary.format,
              'resources': dictionary.resources
                  .map((asset) => '${root.path}/${dictionary.id}/${asset.file}')
                  .toList(),
            },
            session: session,
            generation: generation,
          );
          return DictionaryLookupGroup(dictionary, definitions: definitions);
        } catch (error) {
          return DictionaryLookupGroup(dictionary, error: _errorText(error));
        }
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _engine.dispose();
    super.dispose();
  }
}

String _leaf(String value) => value.replaceAll('\\', '/').split('/').last;
String _errorText(Object error) => error is FormatException
    ? error.message
    : error is UnsupportedError
    ? error.message ?? '暂不支持这种词典格式'
    : '词典操作未完成，请重试';
bool _mddMatches(String stem, String name) => RegExp(
  '^${RegExp.escape(stem)}(?:\\.\\d+)?\\.mdd\$',
  caseSensitive: false,
).hasMatch(name);

Future<int> _directoryBytes(Directory directory) async {
  var total = 0;
  await for (final item in directory.list()) {
    if (item is File) total += await item.length();
  }
  return total;
}

Future<List<(String, String)>> _prepareSelectionJob(
  (List<(String, String)>, String) job,
) => _prepareSelection(job.$1, job.$2);

Future<UserDictionary> _importGroupJob(
  (String, String, (String, String), List<(String, String)>, String) job,
) => _importGroup(job.$1, job.$2, job.$3, job.$4, job.$5);

Future<UserDictionary> _attachResourceJob(
  (UserDictionary, (String, String), String, String, String) job,
) async {
  final (current, source, path, filename, directory) = job;
  await _copyBounded(source.$2, path);
  final info = await buildDictionaryIndex(path);
  return current.copyWith(
    resources: [
      ...current.resources,
      DictionaryAsset(
        file: filename,
        sourceName: _leaf(source.$1),
        entries: info.$1,
        bytes: await File(path).length(),
      ),
    ],
    storedBytes: await _directoryBytes(Directory(directory)),
  );
}

Future<UserDictionary> _importGroup(
  String id,
  String destination,
  (String, String) primary,
  List<(String, String)> group,
  String format,
) async {
  final directory = await Directory(destination).create(recursive: true);
  final sourceName = switch (format) {
    'mdict' => 'source.mdx',
    'stardict' => 'source.ifo',
    _ => 'source.mobi',
  };
  final path = '${directory.path}/$sourceName';
  await _copyBounded(primary.$2, path);
  final resources = <DictionaryAsset>[];
  if (format == 'mdict') {
    var ordinal = 0;
    for (final file in group.where((file) => file != primary)) {
      final filename = 'resource-${ordinal++}.mdd';
      final resourcePath = '${directory.path}/$filename';
      await _copyBounded(file.$2, resourcePath);
      final index = await buildDictionaryIndex(resourcePath);
      resources.add(
        DictionaryAsset(
          file: filename,
          sourceName: _leaf(file.$1),
          entries: index.$1,
          bytes: await File(resourcePath).length(),
        ),
      );
    }
  } else if (format == 'stardict') {
    final stem = primary.$1.substring(0, primary.$1.length - 4);
    for (final file in group.where((file) => file != primary)) {
      final suffix = file.$1.substring(stem.length).toLowerCase();
      await _copyBounded(file.$2, '${directory.path}/source$suffix');
    }
  }
  final index = switch (format) {
    'mdict' => await buildDictionaryIndex(path),
    'stardict' => await buildStarDictIndex(path),
    _ => await buildMobiDictionaryIndex(path),
  };
  final fallback = _leaf(
    primary.$1,
  ).replaceFirst(RegExp(r'\.(mdx|ifo|mobi)$', caseSensitive: false), '');
  final title = (index.$2.isEmpty ? fallback : index.$2).trim();
  return UserDictionary(
    id: id,
    name: title.isEmpty ? '导入词典' : String.fromCharCodes(title.runes.take(80)),
    format: format,
    source: DictionaryAsset(
      file: sourceName,
      sourceName: _leaf(primary.$1),
      entries: index.$1,
      bytes: await File(path).length(),
    ),
    resources: List.unmodifiable(resources),
    storedBytes: await _directoryBytes(directory),
  );
}

Future<void> _copyBounded(String source, String destination) async {
  final before = await File(source).stat();
  if (before.size <= 0 || before.size > 512 * 1024 * 1024) {
    throw const FormatException('单个词典文件需要在 512 MiB 以内');
  }
  final sink = await File(destination).open(mode: FileMode.write);
  var count = 0;
  try {
    await for (final chunk in File(source).openRead()) {
      count += chunk.length;
      if (count > before.size) throw const FormatException('词典文件在导入时发生了变化');
      await sink.writeFrom(chunk);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  final after = await File(source).stat();
  if (count != before.size ||
      after.size != before.size ||
      after.modified != before.modified) {
    throw const FormatException('词典文件在导入时发生了变化，请重试');
  }
}

Future<List<(String, String)>> _prepareSelection(
  List<(String, String)> inputs,
  String staging,
) async {
  if (inputs.length > 64) throw const FormatException('每次最多选择 64 个词典文件');
  await Directory(staging).create(recursive: true);
  final result = <(String, String)>[];
  final names = <String>{};
  var total = 0, ordinal = 0;
  for (final input in inputs) {
    final name = _leaf(input.$1);
    final size = await File(input.$2).length();
    if (size <= 0 || size > 512 * 1024 * 1024) {
      throw const FormatException('单个词典文件需要在 512 MiB 以内');
    }
    if (!name.toLowerCase().endsWith('.zip')) {
      if (!names.add(name.toLowerCase())) {
        throw const FormatException('选择了重名文件，请分开导入');
      }
      total += size;
      result.add((name, input.$2));
    } else {
      await _validateZipDirectory(input.$2);
      final stream = InputFileStream(input.$2);
      try {
        final archive = ZipDirectory()..read(stream);
        if (archive.fileHeaders.length > 4096) {
          throw const FormatException('词典包包含过多文件');
        }
        for (final header in archive.fileHeaders) {
          final entry = header.file!;
          final path = entry.filename.replaceAll('\\', '/');
          if (path.startsWith('/') ||
              RegExp(r'^[a-zA-Z]:').hasMatch(path) ||
              path.split('/').any((part) => part == '..' || part == '.') ||
              (header.externalFileAttributes >> 16 & 0xf000) == 0xa000) {
            throw const FormatException('词典包含有不安全的文件路径');
          }
          if (!RegExp(
            r'\.(mdx|mdd|ifo|idx(?:\.gz)?|dict(?:\.dz)?|syn|mobi)$',
            caseSensitive: false,
          ).hasMatch(path)) {
            continue;
          }
          if (!names.add(path.toLowerCase())) {
            throw const FormatException('词典包含有重复文件');
          }
          if (entry.uncompressedSize <= 0 ||
              entry.uncompressedSize > 512 * 1024 * 1024) {
            throw const FormatException('词典包中单个文件超过 512 MiB');
          }
          total += entry.uncompressedSize;
          if (total > 1024 * 1024 * 1024 || result.length >= 64) {
            throw const FormatException('一次导入的词典文件超过 1 GiB 或 64 个文件');
          }
          final target = '$staging/file-${ordinal++}';
          final output = _BoundedZipOutput(target, entry.uncompressedSize);
          try {
            entry.decompress(output);
            if (output.length != entry.uncompressedSize) {
              throw const FormatException('词典包文件长度不匹配');
            }
          } finally {
            output.closeSync();
          }
          result.add((path, target));
        }
      } finally {
        stream.closeSync();
      }
    }
    if (total > 1024 * 1024 * 1024) {
      throw const FormatException('一次导入的词典文件不能超过 1 GiB');
    }
  }
  if (result.isEmpty) {
    throw const FormatException('没有找到 MDX/MDD、StarDict 或 MOBI 词典文件');
  }
  return result;
}

class _BoundedZipOutput extends OutputStream {
  _BoundedZipOutput(String path, this.maximum)
    : output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);
  final OutputFileStream output;
  final int maximum;
  @override
  int get length => output.length;
  void _check(int count) {
    if (count < 0 || length + count > maximum) {
      throw const FormatException('词典包展开后超过声明大小');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    output.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final bytes = stream.readBytes(65536).toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => output.subset(start, end);
  @override
  void clear() => throw UnsupportedError('词典输出不可重用');
  @override
  void flush() => output.flush();
  @override
  void closeSync() => output.closeSync();
}

Future<void> _validateZipDirectory(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    if (length < 22) throw const FormatException('词典 ZIP 不完整');
    final tailSize = length < 65557 ? length : 65557;
    await file.setPosition(length - tailSize);
    final bytes = await file.read(tailSize);
    final data = ByteData.sublistView(bytes);
    for (var offset = bytes.length - 22; offset >= 0; offset--) {
      if (data.getUint32(offset, Endian.little) != 0x06054b50 ||
          offset + 22 + data.getUint16(offset + 20, Endian.little) !=
              bytes.length) {
        continue;
      }
      final disk = data.getUint16(offset + 4, Endian.little);
      final centralDisk = data.getUint16(offset + 6, Endian.little);
      final entries = data.getUint16(offset + 10, Endian.little);
      final centralBytes = data.getUint32(offset + 12, Endian.little);
      final centralOffset = data.getUint32(offset + 16, Endian.little);
      if (disk != 0 ||
          centralDisk != 0 ||
          entries == 0xffff ||
          centralBytes == 0xffffffff ||
          centralOffset == 0xffffffff) {
        throw const FormatException('请先解压分卷或 ZIP64 词典包，再选择完整文件组导入');
      }
      if (entries > 4096 ||
          centralBytes > 8 * 1024 * 1024 ||
          centralOffset + centralBytes > length - tailSize + offset) {
        throw const FormatException('词典包目录过大或文件长度有误');
      }
      return;
    }
    throw const FormatException('词典 ZIP 不完整');
  } finally {
    await file.close();
  }
}
