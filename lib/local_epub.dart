import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

import 'reader_rich_content.dart'
    show joinBrokenParagraph, shouldMergeBrokenParagraph;

/// 块：文本或图片二选一
class EpubBlock {
  const EpubBlock.text(this.text) : kind = EpubBlockKind.text, entryPath = null;
  const EpubBlock.image(this.entryPath)
    : kind = EpubBlockKind.image,
      text = null;
  final EpubBlockKind kind;
  final String? text;
  final String? entryPath; // 图片在 ZIP 内的规范化路径
}

enum EpubBlockKind { text, image }

/// EPUB 声明的解压总量上限；不代表对伪造元数据的完整 ZIP 炸弹防护。
const epubMaxDecodedBytes = 768 * 1024 * 1024;

void _preflightZip(InputFileStream input) {
  // archive 4.5.2 的 ZipDirectory 只读取元数据和压缩数据视图，不解压。
  // 在 ZipDecoder 提前解压符号链接前拒绝链接及声明总量超限的包。
  // 大小来自 ZIP 自报元数据，不能证明实际展开量，仍存在伪造元数据的风险。
  final directory = ZipDirectory()..read(input);
  var decodedTotal = 0;
  for (final header in directory.fileHeaders) {
    final mode = header.externalFileAttributes >> 16;
    if ((mode & 0xf000) == 0xa000) {
      throw StateError('不支持含符号链接的 EPUB');
    }
    if (header.uncompressedSize < 0 ||
        header.uncompressedSize > epubMaxDecodedBytes - decodedTotal) {
      throw StateError('EPUB 解压后大小超过上限');
    }
    decodedTotal += header.uncompressedSize;
  }
}

final _fontEntryPattern = RegExp(
  r'\.(?:ttf|otf|woff2?|ttc|eot)$',
  caseSensitive: false,
);

final _rasterImageEntryPattern = RegExp(
  r'\.(?:jpe?g|png|gif|webp|bmp)$',
  caseSensitive: false,
);

String? _resolveEntryKey(Map<String, ArchiveFile> entries, String? path) {
  if (path == null || path.isEmpty) return null;
  if (entries.containsKey(path)) return path;
  final normalized = path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'^/+'), '');
  if (entries.containsKey(normalized)) return normalized;
  final encoded = Uri.encodeFull(normalized);
  if (entries.containsKey(encoded)) return encoded;
  final lower = normalized.toLowerCase();
  for (final key in entries.keys) {
    if (key.toLowerCase() == lower) return key;
  }
  return null;
}

void _validateEncryption(
  Map<String, ArchiveFile> entries,
  Iterable<_ManifestItem> manifest,
) {
  final encryptionKey = _resolveEntryKey(entries, 'META-INF/encryption.xml');
  if (encryptionKey == null) return;
  final encryption = entries[encryptionKey]!;

  final doc = _parseXml(_decodeText(_extract(encryption)));
  final resourcePaths = <String>{};
  final contentPaths = <String>{};
  for (final item in manifest) {
    final path = item.path;
    if (path == null || item.mediaType.isEmpty) continue;
    final resolved = _resolveEntryKey(entries, path) ?? path;
    resourcePaths.add(path);
    resourcePaths.add(resolved);
    final mediaType = _baseMediaType(item.mediaType);
    if (mediaType == 'application/xhtml+xml' ||
        mediaType == 'text/html' ||
        mediaType.startsWith('image/')) {
      contentPaths.add(path);
      contentPaths.add(resolved);
    }
  }
  for (final encrypted in _elements(doc, 'encrypteddata')) {
    final references = _elements(encrypted, 'cipherreference').toList();
    // 缺少可解析且能确定资源类型的 CipherReference 目标时，
    // 无法排除正文或图片加密，保守拒绝。
    if (references.isEmpty) {
      throw StateError('不支持加密的 EPUB');
    }
    for (final reference in references) {
      final target = resolveEpubHref('', reference.getAttribute('URI') ?? '');
      if (target == null) {
        throw StateError('不支持加密的 EPUB');
      }
      final resolvedTarget = _resolveEntryKey(entries, target) ?? target;
      if (contentPaths.contains(target) ||
          contentPaths.contains(resolvedTarget)) {
        throw StateError('不支持加密的 EPUB');
      }
      // 多看阅读等排版的 EPUB 常包含字体混淆（META-INF/encryption.xml 指向 .ttf/.otf），
      // 且混淆字体有时未列入 manifest：只要不是正文或图片，允许字体混淆条目通过。
      if (_fontEntryPattern.hasMatch(target)) {
        continue;
      }
      if (!entries.containsKey(resolvedTarget) ||
          (!resourcePaths.contains(target) &&
              !resourcePaths.contains(resolvedTarget))) {
        throw StateError('不支持加密的 EPUB');
      }
    }
  }
}

class EpubChapter {
  const EpubChapter({required this.title, required this.href});
  final String title;
  final String href; // 已相对 OPF 解析并 URL 解码的 ZIP 内路径
}

class EpubPackage {
  EpubPackage._({
    required InputFileStream input,
    required Map<String, ArchiveFile> entries,
    required String title,
    required String? author,
    required String? coverEntry,
    required List<EpubChapter> chapters,
  }) : _input = input,
       _entries = entries,
       _title = title,
       _author = author,
       _coverEntry = coverEntry,
       _chapters = List.unmodifiable(chapters);

  final InputFileStream _input;
  final Map<String, ArchiveFile> _entries;
  final String _title;
  final String? _author;
  final String? _coverEntry;
  final List<EpubChapter> _chapters;
  bool _closed = false;

  String get title => _title;
  String? get author => _author;
  String? get coverEntry => _coverEntry;
  List<EpubChapter> get chapters => _chapters;

  static Future<EpubPackage> open(String path) async {
    _EpubFileHandle? file;
    try {
      file = _EpubFileHandle(File(path).openSync());
      final input = InputFileStream.withFileHandle(file);
      _preflightZip(input);
      input.reset();
      final archive = ZipDecoder().decodeStream(input);
      var decodedTotal = 0;
      for (final f in archive.files) {
        if (f.isSymbolicLink) {
          throw StateError('不支持含符号链接的 EPUB');
        }
        if (!f.isFile) continue;
        decodedTotal += f.size;
        if (decodedTotal > epubMaxDecodedBytes) {
          throw StateError('EPUB 解压后大小超过上限');
        }
      }
      final entries = <String, ArchiveFile>{};
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final normalized = f.name
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        entries[normalized] = f;
        entries.putIfAbsent(f.name, () => f);
      }
      return _parse(input, entries);
    } catch (e) {
      final failure = e is StateError
          ? e
          : StateError('无法打开 EPUB: ${e.runtimeType}');
      if (file != null) {
        try {
          await file.close();
        } on Object {
          throw failure;
        }
      }
      throw failure;
    }
  }

  static EpubPackage _parse(
    InputFileStream input,
    Map<String, ArchiveFile> entries,
  ) {
    String readText(String entry) {
      final key = _resolveEntryKey(entries, entry);
      final f = key == null ? null : entries[key];
      if (f == null) throw StateError('EPUB 条目不存在: $entry');
      return _decodeText(_extract(f));
    }

    // 1. container.xml -> OPF 路径
    final containerKey = _resolveEntryKey(entries, 'META-INF/container.xml');
    if (containerKey == null) {
      throw StateError('无效的 EPUB：缺少 META-INF/container.xml');
    }
    final container = _parseXml(readText(containerKey));
    String? opfPath;
    for (final e in _elements(container, 'rootfile')) {
      final fullPath = e.getAttribute('full-path');
      if (fullPath == null || fullPath.trim().isEmpty) continue;
      final candidate = resolveEpubHref('', fullPath);
      final resolved = _resolveEntryKey(entries, candidate);
      if (resolved != null) {
        opfPath = resolved;
        break;
      }
    }
    if (opfPath == null) {
      throw StateError('无效的 EPUB：找不到 OPF 文件');
    }
    final opfDir = _dirOf(opfPath);
    final opf = _parseXml(readText(opfPath));

    // 元数据
    final metadata = _firstElement(opf, 'metadata') ?? opf.rootElement;
    final title = _firstText(metadata, 'title') ?? '';
    final author = _firstText(metadata, 'creator');

    // manifest
    final manifest = <String, _ManifestItem>{};
    final manifestOrder = <_ManifestItem>[];
    for (final e in _elements(opf, 'item')) {
      final id = e.getAttribute('id');
      final href = e.getAttribute('href');
      if (id == null) continue;
      final rawPath = href == null ? null : resolveEpubHref(opfDir, href);
      final item = _ManifestItem(
        path: _resolveEntryKey(entries, rawPath) ?? rawPath,
        mediaType: _baseMediaType(e.getAttribute('media-type') ?? ''),
        fallbackId: e.getAttribute('fallback')?.trim(),
        properties: (e.getAttribute('properties') ?? '')
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toSet(),
      );
      manifest[id] = item;
      manifestOrder.add(item);
    }
    _validateEncryption(entries, manifestOrder);

    // spine：按 itemref 顺序解析可读章节（支持 XHTML/HTML/XML 及插画页），也跟随 fallback 链。
    final spine = _firstElement(opf, 'spine');
    final spineHrefs = <String>[];
    final nonLinearSpineHrefs = <String>[];
    if (spine != null) {
      for (final ref in spine.childElements) {
        if (ref.name.local.toLowerCase() != 'itemref') continue;
        final isNonLinear =
            (ref.getAttribute('linear') ?? '').trim().toLowerCase() == 'no';
        final item = manifest[ref.getAttribute('idref') ?? ''];
        final href = _readableSpineHref(item, manifest, entries);
        if (isNonLinear) {
          if (href != null) nonLinearSpineHrefs.add(href);
          continue;
        }
        if (href == null) {
          throw StateError('无效的 EPUB：spine 条目无可读 XHTML');
        }
        spineHrefs.add(href);
      }
    }
    if (spineHrefs.isEmpty && nonLinearSpineHrefs.isNotEmpty) {
      spineHrefs.addAll(nonLinearSpineHrefs);
    }
    if (spineHrefs.isEmpty) {
      throw StateError('无效的 EPUB：没有可读章节');
    }

    // NCX 标题
    String? ncxPath;
    final tocId = spine?.getAttribute('toc');
    if (tocId != null) ncxPath = manifest[tocId]?.path;
    ncxPath ??= manifestOrder
        .where((i) => i.mediaType == 'application/x-dtbncx+xml')
        .map((i) => i.path)
        .firstWhere((p) => p != null, orElse: () => null);
    ncxPath = _resolveEntryKey(entries, ncxPath);
    final navTitles = <String, String>{};
    if (ncxPath != null) {
      try {
        navTitles.addAll(
          _parseNcx(readText(ncxPath), _dirOf(ncxPath), opfDir, {
            ...spineHrefs,
          }, entries),
        );
      } on Object {
        // NCX 损坏时走回退链
      }
    }

    // EPUB3 nav 回退：NCX 缺失的章节标题由 nav.xhtml 的 toc 补齐，
    // NCX 已有标题不被覆盖；nav 缺失或损坏时静默忽略，走后续回退链。
    if (spineHrefs.any((h) => (navTitles[h] ?? '').trim().isEmpty)) {
      try {
        final navItem = manifestOrder.firstWhere(
          (i) =>
              i.properties.contains('nav') &&
              (i.mediaType == 'application/xhtml+xml' ||
                  i.mediaType == 'text/html') &&
              _resolveEntryKey(entries, i.path) != null,
          orElse: () => const _ManifestItem(
            path: null,
            mediaType: '',
            fallbackId: null,
            properties: <String>{},
          ),
        );
        final navPath = _resolveEntryKey(entries, navItem.path);
        if (navPath != null) {
          final navDoc = _parseXml(readText(navPath));
          final navs = _elements(navDoc, 'nav').toList();
          if (navs.isNotEmpty) {
            final toc = navs.firstWhere(
              (n) => n.attributes.any(
                (a) =>
                    a.name.local.toLowerCase() == 'type' &&
                    a.value
                        .trim()
                        .toLowerCase()
                        .split(RegExp(r'\s+'))
                        .contains('toc'),
              ),
              orElse: () => navs.first,
            );
            final navDir = _dirOf(navPath);
            for (final a in _elements(toc, 'a')) {
              final href = _hrefAttribute(a);
              if (href == null) continue;
              final title = a.innerText.replaceAll(_whitespace, ' ').trim();
              if (title.isEmpty) continue;
              var target = _resolveEntryKey(
                entries,
                resolveEpubHref(navDir, href),
              );
              if (target == null || !spineHrefs.contains(target)) {
                target = _resolveEntryKey(
                  entries,
                  resolveEpubHref(opfDir, href),
                );
              }
              if (target != null && spineHrefs.contains(target)) {
                navTitles.putIfAbsent(target, () => title);
              }
            }
          }
        }
      } on Object {
        // nav 损坏时走回退链
      }
    }

    // 章节标题回退：NCX -> nav -> <title> -> 首个 <h1> -> 第 N 章
    // N 为输出章节序号（与 chapterBlocks 的 index + 1 一致）。
    final chapters = <EpubChapter>[];
    for (var i = 0; i < spineHrefs.length; i++) {
      final href = spineHrefs[i];
      var chapterTitle = navTitles[href];
      if (chapterTitle == null && !_rasterImageEntryPattern.hasMatch(href)) {
        try {
          chapterTitle = _fallbackTitle(readText(href));
        } on Object {
          chapterTitle = null;
        }
      }
      chapters.add(
        EpubChapter(title: chapterTitle ?? '第 ${i + 1} 章', href: href),
      );
    }

    // 封面
    String? cover;
    bool usableImage(_ManifestItem? item) =>
        item != null &&
        item.path != null &&
        item.mediaType.startsWith('image/') &&
        _resolveEntryKey(entries, item.path) != null;
    for (final meta in _elements(metadata, 'meta')) {
      if ((meta.getAttribute('name') ?? '').trim().toLowerCase() != 'cover') {
        continue;
      }
      final item = manifest[(meta.getAttribute('content') ?? '').trim()];
      if (usableImage(item)) {
        cover = _resolveEntryKey(entries, item!.path);
        break;
      }
    }
    cover ??= manifestOrder
        .where((i) => i.properties.contains('cover-image') && usableImage(i))
        .map((i) => _resolveEntryKey(entries, i.path))
        .firstWhere((_) => true, orElse: () => null);
    cover ??= manifestOrder
        .where((i) => usableImage(i) && i.path!.toLowerCase().contains('cover'))
        .map((i) => _resolveEntryKey(entries, i.path))
        .firstWhere((_) => true, orElse: () => null);

    return EpubPackage._(
      input: input,
      entries: entries,
      title: title,
      author: author,
      coverEntry: cover,
      chapters: chapters,
    );
  }

  Future<List<EpubBlock>> chapterBlocks(int index) async {
    _ensureOpen();
    if (index < 0 || index >= _chapters.length) {
      throw RangeError.index(index, _chapters, 'index');
    }
    final href = _chapters[index].href;
    if (_rasterImageEntryPattern.hasMatch(href)) {
      final resolved = _resolveEntryKey(_entries, href);
      return resolved == null ? const [] : [EpubBlock.image(resolved)];
    }
    final source = _decodeText(_readEntrySync(href));
    final dir = _dirOf(href);

    String? resolveImage(String? src) {
      if (src == null) return null;
      final path = resolveEpubHref(dir, src);
      return _resolveEntryKey(_entries, path);
    }

    try {
      final doc = _parseXml(source);
      final collector = _BlockCollector();
      final root = _firstElement(doc, 'body') ?? doc.rootElement;
      _walk(root, collector, resolveImage);
      collector.flush();
      return collector.blocks;
    } on XmlException {
      return _blocksFromRegex(source, resolveImage);
    }
  }

  Future<Uint8List> readEntry(String entryPath) async {
    _ensureOpen();
    return _readEntrySync(entryPath);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _input.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('EpubPackage 已关闭');
  }

  /// Uncompressed XHTML size of each spine chapter. Read from the ZIP
  /// directory only (no extraction), used to weight displayed progress.
  List<int> chapterSizes() {
    _ensureOpen();
    return [
      for (final chapter in _chapters)
        math.max(
          1,
          _entries[_resolveEntryKey(_entries, chapter.href) ?? chapter.href]
                  ?.size ??
              1,
        ),
    ];
  }

  Uint8List _readEntrySync(String entryPath) {
    final key = _resolveEntryKey(_entries, entryPath);
    final f = key == null ? null : _entries[key];
    if (f == null) throw StateError('EPUB 条目不存在: $entryPath');
    return _extract(f);
  }
}

/// 把 EPUB 内的引用 [href] 相对 [baseDir]（ZIP 内目录，不含结尾 /，根目录为 ''）
/// 解析为 ZIP 条目名。去掉查询串和片段，逐段 URL 解码，单 / 开头视为 ZIP 根相对。
/// 外部链接（含 scheme）、空引用、越过根目录的 .. 返回 null。
String? resolveEpubHref(String baseDir, String href) {
  var ref = href.trim().replaceAll(r'\', '/');
  ref = ref.split(RegExp(r'[?#]')).first;
  if (ref.isEmpty) return null;
  if (ref.startsWith('//')) return null;
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(ref)) return null;

  final segments = <String>[];
  bool push(String seg) {
    if (seg.isEmpty || seg == '.') return true;
    if (seg == '..') {
      if (segments.isEmpty) return false;
      segments.removeLast();
      return true;
    }
    segments.add(seg);
    return true;
  }

  if (!ref.startsWith('/')) {
    for (final seg in baseDir.replaceAll(r'\', '/').split('/')) {
      if (!push(seg)) return null;
    }
  }
  for (final raw in ref.split('/')) {
    final decoded = _decodeHrefSegment(raw);
    if (decoded == null) return null;
    for (final segment in decoded.replaceAll(r'\', '/').split('/')) {
      if (!push(segment)) return null;
    }
  }
  if (segments.isEmpty) return null;
  return segments.join('/');
}

String? _decodeHrefSegment(String raw) {
  try {
    return Uri.decodeComponent(
      raw.replaceAllMapped(
        RegExp(r'[^\x00-\x7f]+'),
        (match) => Uri.encodeComponent(match.group(0)!),
      ),
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 内部实现

class _EpubFileHandle extends AbstractFileHandle {
  _EpubFileHandle(this._file);

  final RandomAccessFile _file;
  bool _closed = false;

  @override
  bool get isOpen => !_closed;

  @override
  int get length => _file.lengthSync();

  @override
  int get position => _file.positionSync();

  @override
  set position(int value) => _file.setPositionSync(value);

  @override
  int readInto(Uint8List buffer, [int? length]) =>
      _file.readIntoSync(buffer, 0, length);

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      _file.writeFromSync(buffer, start, end);

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _file.close();
      _closed = true;
    } catch (error) {
      try {
        closeSync();
      } catch (closeError) {
        throw StateError('无法关闭 EPUB: ${closeError.runtimeType}');
      }
      throw StateError('无法关闭 EPUB: ${error.runtimeType}');
    }
  }

  @override
  void closeSync() {
    if (_closed) return;
    _file.closeSync();
    _closed = true;
  }
}

class _ManifestItem {
  const _ManifestItem({
    required this.path,
    required this.mediaType,
    required this.fallbackId,
    required this.properties,
  });
  final String? path;
  final String mediaType;
  final String? fallbackId;
  final Set<String> properties;
}

String _baseMediaType(String raw) =>
    raw.split(';').first.trim().toLowerCase();

final _readableMarkupExtension = RegExp(
  r'\.(?:x?html?|xml|svg)$',
  caseSensitive: false,
);

bool _isReadableSpineMediaType(String mediaType, String path) {
  if (mediaType == 'application/xhtml+xml' ||
      mediaType == 'text/html' ||
      mediaType == 'application/xml' ||
      mediaType == 'text/xml' ||
      mediaType == 'application/x-dtbook+xml' ||
      mediaType.startsWith('image/')) {
    return true;
  }
  if (mediaType.isEmpty && _readableMarkupExtension.hasMatch(path)) {
    return true;
  }
  return false;
}

String? _readableSpineHref(
  _ManifestItem? item,
  Map<String, _ManifestItem> manifest,
  Map<String, ArchiveFile> entries,
) {
  final visitedFallbacks = <String>{};
  var current = item;
  while (current != null) {
    final resolvedPath = _resolveEntryKey(entries, current.path);
    if (resolvedPath != null &&
        _isReadableSpineMediaType(current.mediaType, resolvedPath)) {
      return resolvedPath;
    }
    final fallbackId = current.fallbackId;
    if (fallbackId == null || !visitedFallbacks.add(fallbackId)) return null;
    current = manifest[fallbackId];
  }
  return null;
}

class _BlockCollector {
  final blocks = <EpubBlock>[];
  final _buf = StringBuffer();

  void addText(String text) => _buf.write(text);

  void flush() {
    final text = _buf
        .toString()
        .replaceAll(_cjkLineBreak, '')
        .replaceAll(_whitespace, ' ')
        .trim();
    _buf.clear();
    if (text.isEmpty) return;
    if (blocks.isNotEmpty &&
        blocks.last.text != null &&
        shouldMergeBrokenParagraph(blocks.last.text!, text)) {
      blocks[blocks.length - 1] = EpubBlock.text(
        joinBrokenParagraph(blocks.last.text!, text),
      );
    } else {
      blocks.add(EpubBlock.text(text));
    }
  }

  void addImage(String? entryPath) {
    if (entryPath == null) return;
    flush();
    blocks.add(EpubBlock.image(entryPath));
  }
}

final _cjkLineBreak = RegExp(
  r'(?<=[\u3000-\u303f\u3400-\u9fff\uff00-\uffef])[ \t]*[\r\n]+[ \t]*(?=[\u3000-\u303f\u3400-\u9fff\uff00-\uffef])',
);
final _whitespace = RegExp(r'\s+');
const _blockTags = {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li'};
const _skipTags = {'head', 'script', 'style'};
const _xmlEntities = {'amp', 'lt', 'gt', 'quot', 'apos'};

/// 只解压单个条目，写入临时内存流后释放 ArchiveFile 内部缓存。
Uint8List _extract(ArchiveFile file) {
  final out = OutputMemoryStream();
  file.writeContent(out, freeMemory: true);
  return out.getBytes();
}

String _decodeText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return _decodeUtf16(bytes, bigEndian: false);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    return _decodeUtf16(bytes, bigEndian: true);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}

String _decodeUtf16(Uint8List bytes, {required bool bigEndian}) {
  final codeUnits = <int>[];
  final end = bytes.length - bytes.length % 2;
  for (var offset = 2; offset < end; offset += 2) {
    codeUnits.add(
      bigEndian
          ? (bytes[offset] << 8) | bytes[offset + 1]
          : bytes[offset] | (bytes[offset + 1] << 8),
    );
  }
  return String.fromCharCodes(codeUnits);
}

final _illegalXmlControlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');
final _leadingXmlDeclWhitespace = RegExp(
  r'^\s+(?=<\?xml\b)',
  caseSensitive: false,
);
final _bareAmpersand = RegExp(
  r'&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9a-fA-F]+);)',
);

/// &nbsp; 与其他未知命名实体转为空格；数字实体与 5 个 XML 预定义实体保留。
String _preprocessEntities(String source) {
  final cleaned = source
      .replaceFirst(_leadingXmlDeclWhitespace, '')
      .replaceAll(_illegalXmlControlChars, '');
  final out = StringBuffer();
  var position = 0;
  while (position < cleaned.length) {
    final start = cleaned.indexOf('<![CDATA[', position);
    if (start < 0) {
      out.write(_replaceEntities(cleaned.substring(position)));
      break;
    }
    out.write(_replaceEntities(cleaned.substring(position, start)));
    final end = cleaned.indexOf(']]>', start + 9);
    if (end < 0) {
      out.write(cleaned.substring(start));
      break;
    }
    out.write(cleaned.substring(start, end + 3));
    position = end + 3;
  }
  return out.toString();
}

String _replaceEntities(String source) => source
    .replaceAllMapped(
      RegExp(r'&([A-Za-z][A-Za-z0-9]*);'),
      (m) => _xmlEntities.contains(m.group(1)) ? m.group(0)! : ' ',
    )
    .replaceAll(_bareAmpersand, '&amp;');

XmlDocument _parseXml(String source) =>
    XmlDocument.parse(_preprocessEntities(source));

/// 正则降级与标题回退用的实体解码。
String _decodeEntities(String text) => text.replaceAllMapped(
  RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);'),
  (m) {
    final name = m.group(1)!;
    if (name.startsWith('#')) {
      final hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X');
      final code = int.tryParse(
        hex ? name.substring(2) : name.substring(1),
        radix: hex ? 16 : 10,
      );
      if (code == null || code <= 0 || code > 0x10FFFF) return ' ';
      if (code >= 0xD800 && code <= 0xDFFF) return ' ';
      return String.fromCharCode(code);
    }
    switch (name) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      default:
        return ' ';
    }
  },
);

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

Iterable<XmlElement> _elements(XmlNode root, String localName) => root
    .descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local.toLowerCase() == localName);

XmlElement? _firstElement(XmlNode root, String localName) {
  for (final e in _elements(root, localName)) {
    return e;
  }
  return null;
}

String? _firstText(XmlNode root, String localName) {
  for (final e in _elements(root, localName)) {
    final text = e.innerText.replaceAll(_whitespace, ' ').trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

String? _hrefAttribute(XmlElement e) {
  String? prefixed;
  for (final a in e.attributes) {
    if (a.name.local.toLowerCase() != 'href') continue;
    if (a.name.prefix == null || a.name.prefix!.isEmpty) return a.value;
    prefixed ??= a.value;
  }
  return prefixed;
}

/// 返回 spine 路径 -> navLabel 文本。按 playOrder 排序，同一路径取第一个。
/// src 先相对 NCX 所在目录解析，匹配不到 spine 时再相对 OPF 目录解析。
Map<String, String> _parseNcx(
  String source,
  String ncxDir,
  String opfDir,
  Set<String> spineHrefs,
  Map<String, ArchiveFile> entries,
) {
  final doc = _parseXml(source);
  final points = _elements(doc, 'navpoint').toList();
  final order = <XmlElement, int>{};
  for (var i = 0; i < points.length; i++) {
    order[points[i]] = i;
  }
  int playOrder(XmlElement e) =>
      int.tryParse((e.getAttribute('playOrder') ?? '').trim()) ?? 1 << 30;
  points.sort((a, b) {
    final c = playOrder(a).compareTo(playOrder(b));
    return c != 0 ? c : order[a]!.compareTo(order[b]!);
  });

  final result = <String, String>{};
  for (final point in points) {
    XmlElement? label;
    XmlElement? content;
    for (final child in point.childElements) {
      final name = child.name.local.toLowerCase();
      if (name == 'navlabel') label ??= child;
      if (name == 'content') content ??= child;
    }
    final src = content?.getAttribute('src');
    if (label == null || src == null) continue;
    final text = (_firstText(label, 'text') ?? '').trim();
    if (text.isEmpty) continue;

    var path = _resolveEntryKey(entries, resolveEpubHref(ncxDir, src));
    if (path == null || !spineHrefs.contains(path)) {
      path = _resolveEntryKey(entries, resolveEpubHref(opfDir, src));
    }
    if (path == null || !spineHrefs.contains(path)) continue;
    result.putIfAbsent(path, () => text);
  }
  return result;
}

/// 标题回退：<title> 文本，再回退首个 <h1>，保留 CDATA 字面文本。
String? _fallbackTitle(String source) {
  final text = _withoutComments(source);
  final buffer = StringBuffer();
  String? activeTitle;
  String? heading;
  var previousEnd = 0;
  for (final token in _markupTokens.allMatches(text)) {
    if (activeTitle != null) {
      buffer.write(_decodeEntities(text.substring(previousEnd, token.start)));
    }
    previousEnd = token.end;
    final tag = token.group(0)!;
    if (tag.startsWith('<![CDATA[')) {
      if (activeTitle != null) buffer.write(tag.substring(9, tag.length - 3));
      continue;
    }
    final name = _tagLocalName(tag);
    if (activeTitle == null &&
        !_isClosingTag(tag) &&
        !_isSelfClosingTag(tag) &&
        (name == 'title' || name == 'h1')) {
      activeTitle = name;
      buffer.clear();
    } else if (activeTitle != null &&
        _isClosingTag(tag) &&
        name == activeTitle) {
      final title = buffer.toString().replaceAll(_whitespace, ' ').trim();
      if (title.isNotEmpty) {
        if (name == 'title') return title;
        heading ??= title;
      }
      activeTitle = null;
    }
  }
  return heading;
}

void _walk(
  XmlNode node,
  _BlockCollector c,
  String? Function(String?) resolveImage,
) {
  for (final child in node.children) {
    if (child is XmlText) {
      c.addText(child.value);
      continue;
    }
    if (child is XmlCDATA) {
      c.addText(child.value);
      continue;
    }
    if (child is! XmlElement) continue;
    final name = child.name.local.toLowerCase();
    if (_skipTags.contains(name)) continue;
    if (name == 'img') {
      c.addImage(resolveImage(child.getAttribute('src')));
    } else if (name == 'br') {
      c.flush();
    } else if (name == 'svg') {
      c.flush();
      for (final image in _elements(child, 'image')) {
        c.addImage(resolveImage(_hrefAttribute(image)));
      }
    } else if (_blockTags.contains(name)) {
      c.flush();
      _walk(child, c, resolveImage);
      c.flush();
    } else {
      _walk(child, c, resolveImage);
    }
  }
}

final _markupTokens = RegExp(
  r'''<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<(?:[^>"']|"[^"]*"|'[^']*')*>''',
);
final _tagName = RegExp(
  r'^<\s*/?\s*(?:[\w.\-]+:)?([A-Za-z][\w.\-]*)(?=[\s/>])',
);
final _attribute = RegExp(
  r'''\s+([\w.:\-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?''',
);

String _withoutComments(String source) => source.replaceAllMapped(
  _markupTokens,
  (match) => match.group(0)!.startsWith('<!--') ? '' : match.group(0)!,
);

String? _tagAttribute(String tag, String name, {bool anyPrefix = false}) {
  final element = _tagName.firstMatch(tag);
  if (element == null) return null;
  var position = element.end;
  String? prefixed;
  while (position < tag.length) {
    final attribute = _attribute.matchAsPrefix(tag, position);
    if (attribute == null) break;
    position = attribute.end;
    final attributeName = attribute.group(1)!.toLowerCase();
    final value =
        attribute.group(2) ?? attribute.group(3) ?? attribute.group(4);
    if (value == null) continue;
    if (attributeName == name) return _decodeEntities(value);
    if (anyPrefix && attributeName.endsWith(':$name')) {
      prefixed ??= _decodeEntities(value);
    }
  }
  return prefixed;
}

String? _tagLocalName(String tag) =>
    _tagName.firstMatch(tag)?.group(1)?.toLowerCase();

bool _isClosingTag(String tag) => RegExp(r'^<\s*/').hasMatch(tag);

bool _isSelfClosingTag(String tag) => RegExp(r'/\s*>$').hasMatch(tag);

/// XML 解析失败时的降级：按标签出现顺序抽取文本与图片。
List<EpubBlock> _blocksFromRegex(
  String source,
  String? Function(String?) resolveImage,
) {
  var text = _withoutComments(source);
  int? bodyStart;
  int? bodyEnd;
  for (final token in _markupTokens.allMatches(text)) {
    final tag = token.group(0)!;
    if (_tagLocalName(tag) != 'body') continue;
    if (_isClosingTag(tag)) {
      bodyEnd = token.start;
      break;
    }
    bodyStart ??= token.end;
  }
  text = text.substring(bodyStart ?? 0, bodyEnd ?? text.length);

  final collector = _BlockCollector();
  final skipped = <String>[];
  var previousEnd = 0;
  var svgDepth = 0;
  for (final token in _markupTokens.allMatches(text)) {
    if (svgDepth == 0 && skipped.isEmpty) {
      collector.addText(
        _decodeEntities(text.substring(previousEnd, token.start)),
      );
    }
    previousEnd = token.end;
    final tag = token.group(0)!;
    if (tag.startsWith('<![CDATA[')) {
      if (svgDepth == 0 && skipped.isEmpty) {
        collector.addText(tag.substring(9, tag.length - 3));
      }
      continue;
    }
    final name = _tagLocalName(tag);
    if (name == null) continue;
    final closing = _isClosingTag(tag);
    if (_skipTags.contains(name)) {
      if (closing) {
        if (skipped.isNotEmpty && skipped.last == name) skipped.removeLast();
      } else if (!_isSelfClosingTag(tag)) {
        skipped.add(name);
      }
      continue;
    }
    if (skipped.isNotEmpty) continue;
    if (name == 'svg') {
      collector.flush();
      if (closing) {
        if (svgDepth > 0) svgDepth--;
      } else if (!_isSelfClosingTag(tag)) {
        svgDepth++;
      }
    } else if (name == 'image' && svgDepth > 0 && !closing) {
      collector.addImage(
        resolveImage(_tagAttribute(tag, 'href', anyPrefix: true)),
      );
    } else if (svgDepth > 0) {
      continue;
    } else if (name == 'img' && !closing) {
      collector.addImage(resolveImage(_tagAttribute(tag, 'src')));
    } else if (name == 'br' || _blockTags.contains(name)) {
      collector.flush();
    }
  }
  if (svgDepth == 0 && skipped.isEmpty) {
    collector.addText(_decodeEntities(text.substring(previousEnd)));
  }
  collector.flush();
  return collector.blocks;
}
