import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

/// Decode once at import time. Reading and shelf animations only use the
/// bounded, application-owned still image, never the picker URI or original.
Future<Uint8List> preparePersonalImage(
  String path, {
  bool cover = false,
}) async {
  final file = File(path);
  final bytes = await file.length();
  if (bytes == 0 || bytes > 20 * 1024 * 1024) {
    throw const FormatException('请选择 20 MiB 以内的图片');
  }
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  return _prepareImageBuffer(buffer, cover: cover);
}

Future<Uint8List> preparePersonalImageBytes(
  Uint8List bytes, {
  bool cover = false,
}) async {
  if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('请选择 20 MiB 以内的图片');
  }
  return _prepareImageBuffer(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    cover: cover,
  );
}

Future<Uint8List> _prepareImageBuffer(
  ui.ImmutableBuffer buffer, {
  required bool cover,
}) async {
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width, height = descriptor.height;
    if (width <= 0 || height <= 0 || width * height > 80000000) {
      throw const FormatException('图片尺寸过大，请先缩小图片');
    }
    final limit = cover ? 1440 : 2048;
    final scale = (limit / (width > height ? width : height)).clamp(0.0, 1.0);
    codec = await descriptor.instantiateCodec(
      targetWidth: (width * scale).round().clamp(1, limit),
      targetHeight: (height * scale).round().clamp(1, limit),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > 16 * 1024 * 1024) {
      throw const FormatException('图片处理未完成，请选择较小的图片');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('无法读取这张图片，请选择 PNG、JPEG 或 WebP 图片');
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

bool validBackgroundId(Object? id) =>
    id is String && RegExp(r'^paper_[0-9]+\.png$').hasMatch(id);

class ReaderBackgroundStore {
  ReaderBackgroundStore({Directory? directory}) : _directory = directory;
  Directory? _directory;
  final _resolvedFiles = <String, File>{};
  File? resolvedFile(String? id) => _resolvedFiles[id];
  Future<Directory> get directory async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/reader-backgrounds',
  );
  Future<File?> file(String? id) async {
    if (!validBackgroundId(id)) return null;
    final value = File('${(await directory).path}/$id');
    if (await value.exists()) return _resolvedFiles[id!] = value;
    _resolvedFiles.remove(id);
    return null;
  }

  Future<List<String>> list() async {
    final root = await directory;
    if (!await root.exists()) return [];
    final ids = <String>[];
    await for (final entry in root.list()) {
      final id = entry.uri.pathSegments.last;
      if (entry is File && validBackgroundId(id)) ids.add(id);
    }
    return ids..sort((a, b) => b.compareTo(a));
  }

  Future<String> import(String path) async {
    if ((await list()).length >= 12) {
      throw const FormatException('最多保留 12 张背景，请先删除不用的图片');
    }
    final bytes = await preparePersonalImage(path);
    final root = await directory;
    await root.create(recursive: true);
    final id = 'paper_${DateTime.now().microsecondsSinceEpoch}.png';
    final part = File('${root.path}/$id.part');
    try {
      await part.writeAsBytes(bytes, flush: true);
      _resolvedFiles[id] = await part.rename('${root.path}/$id');
    } finally {
      if (await part.exists()) await part.delete();
    }
    return id;
  }

  Future<void> remove(String id) async {
    final owned = await file(id);
    if (owned != null) await owned.delete();
    _resolvedFiles.remove(id);
  }
}
