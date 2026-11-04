import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'app_typography.dart';
import 'font_download.dart';

const followAppFont = 'followApp';
bool validFontChoice(Object? value, {bool follow = false}) =>
    value is String &&
    (AppTypeface.values.any((font) => font.name == value) ||
        (follow && value == followAppFont) ||
        RegExp(r'^font_[a-z0-9-]{1,64}$').hasMatch(value));

class UserFont {
  const UserFont(this.id, this.name, this.extension);
  final String id, name, extension;
  String get family => 'WenkuUser_$id';
  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'extension': extension,
  };
}

/// Files stay in private storage. The engine loads a face once, on selection,
/// not on every rebuild or for every entry in the font catalogue.
class UserFontStore extends ChangeNotifier {
  UserFontStore({
    Directory? directory,
    this.loader,
    FontDownloadClient? downloads,
  }) : _directory = directory,
       _downloads = downloads ?? FontDownloadClient();
  static const maxBytes = 32 * 1024 * 1024;
  final Future<void> Function(String family, File file)? loader;
  Directory? _directory;
  final _fonts = <UserFont>[];
  final Map<String, Future<void>> _loads = {};
  final _loadedFaces = <String>{};
  bool isLoaded(String id) =>
      id == AppTypeface.system.name || _loadedFaces.contains(id);
  final FontDownloadClient _downloads;
  final _availableDownloads = <String>{};
  Future<void>? _download;
  String? downloadingFontId;
  FontDownloadCancellation? _cancellation;
  final downloadChanges = ValueNotifier<FontDownloadProgress?>(null);
  FontDownloadProgress? get downloadProgress => downloadChanges.value;
  final _downloadErrors = <String, String>{};
  String? downloadError(String id) => _downloadErrors[id];
  bool get downloading => _download != null;
  bool _loaded = false;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  List<UserFont> get fonts => List.unmodifiable(_fonts);
  UserFont? find(String id) =>
      _fonts.where((font) => font.id == id).firstOrNull;
  bool available(String id) =>
      id == AppTypeface.system.name ||
      _availableDownloads.contains(id) ||
      find(id) != null;
  String label(String id) => id == followAppFont
      ? '跟随 App'
      : find(id)?.name ?? AppTypeface.fromRecord(id).label;
  String? family(String id) => available(id)
      ? find(id)?.family ?? AppTypeface.fromRecord(id).family
      : null;
  Future<Directory> _root() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/user-fonts',
  );
  File _file(Directory root, UserFont font) =>
      File('${root.path}/${font.id}.${font.extension}');
  Future<void> load() async {
    if (_loaded) return;
    final root = await _root();
    for (final font in downloadableFonts) {
      final downloaded = File('${root.path}/${font.fileName}');
      if (await downloaded.exists() &&
          await downloaded.length() == font.bytes) {
        _availableDownloads.add(font.id);
      }
    }
    final index = File('${root.path}/fonts.json');
    if (await index.exists()) {
      if (await index.length() > 128 * 1024) {
        throw const FormatException('字体记录过大');
      }
      final raw = jsonDecode(await index.readAsString());
      if (raw is! List || raw.length > 20) {
        throw const FormatException('字体记录格式有误');
      }
      for (final value in raw) {
        if (value is! Map ||
            !validFontChoice(value['id']) ||
            !(value['id'] as String).startsWith('font_') ||
            value['name'] is! String ||
            value['name'].length > 160 ||
            !['ttf', 'otf'].contains(value['extension'])) {
          throw const FormatException('字体记录格式有误');
        }
        final font = UserFont(value['id'], value['name'], value['extension']);
        if (await _file(root, font).exists() && find(font.id) == null) {
          _fonts.add(font);
        }
      }
    }
    _loaded = true;
  }

  Future<void> ensureLoaded(String id) async {
    final font = find(id);
    if (!available(id) || id == AppTypeface.system.name) return;
    final loading = _loads.putIfAbsent(id, () async {
      final root = await _root();
      final file = font == null
          ? File('${root.path}/${downloadableFont(id)!.fileName}')
          : _file(root, font);
      final family = font?.family ?? AppTypeface.fromRecord(id).family!;
      if (loader != null) return loader!(family, file);
      final face = FontLoader(family)
        ..addFont(file.readAsBytes().then(ByteData.sublistView));
      await face.load();
    });
    try {
      await loading;
      _loadedFaces.add(id);
    } catch (_) {
      _loads.remove(id);
      _loadedFaces.remove(id);
      rethrow;
    }
  }

  Future<void> downloadSourceHanSerif() => downloadFont(sourceHanFontId);

  Future<void> downloadFont(String id) async {
    await load();
    final spec = downloadableFont(id);
    if (spec == null) throw const FormatException('这款字体不在下载目录中');
    if (_availableDownloads.contains(id)) return;
    if (_download case final current?) {
      if (downloadingFontId == id) return current;
      throw const FormatException('请先完成或取消当前字体下载');
    }
    final cancellation = FontDownloadCancellation();
    _cancellation = cancellation;
    downloadingFontId = id;
    _downloadErrors.remove(id);
    final operation = () async {
      final root = await _root();
      await root.create(recursive: true);
      final part = File('${root.path}/${spec.fileName}.part');
      final transfer = spec.archiveEntry == null
          ? part
          : File('${part.path}.zip');
      try {
        await _downloads.download(
          transfer,
          cancellation: cancellation,
          expectedBytes: spec.transferBytes,
          from: spec.sourceUrls.map(Uri.parse).toList(),
          onProgress: (value) {
            if (!_disposed) downloadChanges.value = value;
          },
        );
        if (!_disposed) {
          downloadChanges.value = FontDownloadProgress(
            spec.transferBytes,
            spec.transferBytes,
            validating: true,
          );
        }
        await compute(_prepareDownloadedFont, (
          transfer.path,
          part.path,
          spec.archiveEntry,
          spec.bytes,
        ));
        cancellation.check();
        await part.rename('${root.path}/${spec.fileName}');
        _availableDownloads.add(id);
      } finally {
        if (await part.exists()) await part.delete();
        if (transfer.path != part.path && await transfer.exists()) {
          await transfer.delete();
        }
      }
    }();
    _download = operation;
    _changed();
    try {
      await operation;
    } on FontDownloadCancelled {
      rethrow;
    } catch (_) {
      _downloadErrors[id] = '下载未完成，点击重试';
      rethrow;
    } finally {
      _download = null;
      downloadingFontId = null;
      _cancellation = null;
      if (!_disposed) downloadChanges.value = null;
      _changed();
    }
  }

  void cancelDownload() => _cancellation?.cancel();

  Future<void> _save() async {
    final root = await _root();
    await root.create(recursive: true);
    final temp = File('${root.path}/fonts.json.part');
    await temp.writeAsString(
      jsonEncode(_fonts.map((font) => font.toJson()).toList()),
      flush: true,
    );
    await temp.rename('${root.path}/fonts.json');
  }

  Future<UserFont> importFile(String name, String path) async {
    await load();
    if (_fonts.length >= 20) {
      throw const FormatException('最多保留 20 款导入字体，请先移除不用的字体');
    }
    final extension = name.split('.').last.toLowerCase();
    if (!['ttf', 'otf'].contains(extension)) {
      throw const FormatException('请选择 TTF 或 OTF 字体');
    }
    final source = File(path);
    final size = await source.length();
    if (size <= 0 || size > maxBytes) {
      throw const FormatException('字体文件需要在 32 MiB 以内');
    }
    // Validate SFNT tables before handing an untrusted file to the engine.
    await compute(_validateSfnt, path);
    final id =
        'font_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x100000000).toRadixString(36)}';
    final clean = name
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '')
        .trim();
    final font = UserFont(
      id,
      String.fromCharCodes((clean.isEmpty ? '导入字体' : clean).runes.take(80)),
      extension,
    );
    final root = await _root();
    await root.create(recursive: true);
    final destination = _file(root, font);
    try {
      await source.copy(destination.path);
      _fonts.add(font);
      await ensureLoaded(id);
      await _save();
    } catch (_) {
      _fonts.remove(font);
      _loads.remove(id);
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
    _changed();
    return font;
  }

  Future<void> remove(String id) async {
    if (downloadableFont(id) case final spec?) {
      if (downloadingFontId == id) {
        throw const FormatException('请先取消这款字体的下载');
      }
      final file = File('${(await _root()).path}/${spec.fileName}');
      if (await file.exists()) await file.delete();
      _availableDownloads.remove(id);
      _loads.remove(id);
      _loadedFaces.remove(id);
      _changed();
      return;
    }
    final font = find(id);
    if (font == null) return;
    final index = _fonts.indexOf(font);
    _fonts.removeAt(index);
    try {
      await _save();
    } catch (_) {
      _fonts.insert(index, font);
      rethrow;
    }
    final file = _file(await _root(), font);
    if (await file.exists()) await file.delete();
    _loads.remove(id);
    _loadedFaces.remove(id);
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    cancelDownload();
    downloadChanges.dispose();
    super.dispose();
  }
}

void _prepareDownloadedFont((String, String, String?, int) input) {
  final (source, target, entry, expectedBytes) = input;
  if (entry != null) {
    final archive = ZipDecoder().decodeBytes(File(source).readAsBytesSync());
    final font = archive.findFile(entry);
    if (font == null || !font.isFile || font.size != expectedBytes) {
      throw const FormatException('字体压缩包内容不完整，请重试');
    }
    // Extract exactly the catalogue entry into a fixed private path. Never
    // unpack archive paths or run font conversion on the UI isolate.
    File(target).writeAsBytesSync(font.content, flush: true);
  }
  if (File(target).lengthSync() != expectedBytes) {
    throw const FormatException('字体文件不完整，请重试');
  }
  _validateSfnt(target);
}

void _validateSfnt(String path) {
  final file = File(path).openSync();
  try {
    final size = file.lengthSync();
    final bytes = file.readSync(12);
    if (bytes.length < 12) throw const FormatException('字体文件不完整');
    final header = ByteData.sublistView(bytes);
    final magic = header.getUint32(0);
    final count = header.getUint16(4);
    if (![0x00010000, 0x4f54544f, 0x74727565].contains(magic) ||
        count < 1 ||
        count > 4096 ||
        12 + count * 16 > size) {
      throw const FormatException('不是有效的 TTF / OTF 字体，不支持字体合集');
    }
    final tables = ByteData.sublistView(file.readSync(count * 16));
    final tags = <int>{};
    for (var i = 0; i < count; i++) {
      final offset = tables.getUint32(i * 16 + 8),
          length = tables.getUint32(i * 16 + 12);
      if (offset < 12 + count * 16 || offset + length > size) {
        throw const FormatException('字体文件损坏，字形数据不完整');
      }
      tags.add(tables.getUint32(i * 16));
    }
    if (!tags.containsAll([0x68656164, 0x636d6170, 0x6d617870]) ||
        !tags.any([0x676c7966, 0x43464620, 0x43464632].contains)) {
      throw const FormatException('字体缺少必要的字形表');
    }
  } finally {
    file.closeSync();
  }
}
