import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog.dart';
import 'ui_notifiers.dart';

List<int> _encodeBody(String text) => utf8.encode(text);
List<int> _encodeMetadata(Map<String, Object?> data) =>
    utf8.encode(jsonEncode(data));
Object? _decodeMetadata(String text) => jsonDecode(text);

typedef CacheEpoch = ({int all, int book});

class OfflineBook {
  OfflineBook({required this.novel, required this.chapterBytes})
    : chapterIds = Set.unmodifiable(
        novel.chapters.map((chapter) => chapter.id),
      ),
      cachedCount = novel.chapters
          .where((chapter) => chapterBytes.containsKey(chapter.id))
          .length,
      bytes = chapterBytes.values.fold(0, (a, b) => a + b);

  OfflineBook._({
    required this.novel,
    required this.chapterBytes,
    required this.chapterIds,
    required this.cachedCount,
    required this.bytes,
  });
  final Novel novel;
  final Map<int, int> chapterBytes;
  final Set<int> chapterIds;
  final int cachedCount;
  final int bytes;

  OfflineBook _withChapter(int id, int size) => OfflineBook._(
    novel: novel,
    chapterBytes: Map.unmodifiable({...chapterBytes, id: size}),
    chapterIds: chapterIds,
    cachedCount: cachedCount + (chapterBytes.containsKey(id) ? 0 : 1),
    bytes: bytes - (chapterBytes[id] ?? 0) + size,
  );
}

/// Body files are separate from the small metadata/directory snapshot. Writes
/// and deletion share one queue; generations reject late network completions.
class OfflineCacheStore extends ChangeNotifier {
  OfflineCacheStore(this.directory);
  final Directory directory;
  static const maxBodyBytes = 8 * 1024 * 1024;
  final Map<int, OfflineBook> _books = {};
  final Map<int, int> _bookEpochs = {};
  final Map<int, FrameChangeNotifier> _bookChanges = {};
  int _allEpoch = 0;
  Future<void> _writes = Future.value();
  Future<void>? _loading;
  bool _disposed = false;

  static Future<OfflineCacheStore> forApp() async {
    final support = await getApplicationSupportDirectory();
    return OfflineCacheStore(Directory('${support.path}/wenku8-offline-v1'));
  }

  List<OfflineBook> get books => List.unmodifiable(_books.values);
  OfflineBook? book(int id) => _books[id];
  Listenable bookChanges(int id) =>
      _bookChanges.putIfAbsent(id, FrameChangeNotifier.new);
  int get bytes => _books.values.fold(0, (total, book) => total + book.bytes);

  CacheEpoch epochFor(int id) => (all: _allEpoch, book: _bookEpochs[id] ?? 0);
  bool isCurrent(int id, CacheEpoch epoch) => epochFor(id) == epoch;

  Directory _folder(int id) {
    if (id <= 0) throw ArgumentError.value(id, 'novelId');
    return Directory('${directory.path}/b$id');
  }

  File _body(int id, int chapter) {
    if (chapter <= 0) throw ArgumentError.value(chapter, 'chapterId');
    return File('${_folder(id).path}/c$chapter.txt');
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _changed([int? id]) {
    if (_disposed) return;
    if (id == null) {
      for (final observer in _bookChanges.values) {
        observer.notifyListeners();
      }
    } else {
      _bookChanges[id]?.notifyListeners();
    }
    notifyListeners();
  }

  Future<void> load() {
    if (_loading != null) return _loading!;
    final pending = _serialize(_scan);
    _loading = pending;
    return pending.catchError((Object error, StackTrace stack) {
      _loading = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _scan() async {
    await directory.create(recursive: true);
    final found = <int, OfflineBook>{};
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final match = RegExp(r'^b([1-9][0-9]*)$').firstMatch(name);
      if (match == null) continue;
      final id = int.tryParse(match.group(1)!);
      if (id == null) continue;
      final novel = await readBook(id);
      if (novel == null) continue;
      final sizes = <int, int>{};
      await for (final body in entry.list(followLinks: false)) {
        if (body is! File) continue;
        final filename = body.uri.pathSegments.last;
        final chapter = RegExp(r'^c([1-9][0-9]*)\.txt$').firstMatch(filename);
        if (chapter == null) continue;
        final cid = int.tryParse(chapter.group(1)!);
        if (cid == null) continue;
        final size = await body.length();
        if (size > 0 && size <= maxBodyBytes) sizes[cid] = size;
      }
      found[id] = OfflineBook(
        novel: novel,
        chapterBytes: Map.unmodifiable(sizes),
      );
    }
    _books
      ..clear()
      ..addAll(found);
    _changed();
  }

  Future<Novel?> readBook(int id) async {
    if (id <= 0) return null;
    final file = File('${_folder(id).path}/book.json');
    try {
      if (!await file.exists() || await file.length() > 4 * 1024 * 1024) {
        return null;
      }
      final source = await file.readAsString();
      final decoded = source.length > 64 * 1024
          ? await compute(_decodeMetadata, source)
          : _decodeMetadata(source);
      if (decoded is! Map<String, dynamic>) return null;
      final data = decoded;
      if (data['version'] != 1) return null;
      if (data['novel'] is! Map<String, dynamic> || data['chapters'] is! List) {
        return null;
      }
      final meta = Novel.fromSnapshot(data['novel'] as Map<String, dynamic>);
      if (meta.id != id) return null;
      final chapters = <NovelChapter>[];
      final ids = <int>{};
      for (final value in data['chapters'] as List) {
        if (value is! Map<String, dynamic>) return null;
        final cid = value['id'];
        final title = value['title'];
        if (cid is! int || cid <= 0 || title is! String || !ids.add(cid)) {
          return null;
        }
        chapters.add(NovelChapter(title, '', id: cid));
      }
      return meta.withChapters(List.unmodifiable(chapters));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<String?> readChapter(int id, int cid) async {
    if (id <= 0 || cid <= 0) return null;
    final file = _body(id, cid);
    try {
      if (!await file.exists()) return null;
      final size = await file.length();
      if (size == 0 || size > maxBodyBytes) return null;
      final text = await file.readAsString();
      return text.trim().isEmpty ? null : text;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _atomicWrite(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.part');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> saveBook(Novel novel, {required CacheEpoch epoch}) async {
    await load();
    return _serialize(() async {
      if (!isCurrent(novel.id, epoch)) return false;
      final previous = _books[novel.id];
      // A metadata-only response must not erase an already usable directory.
      final stored = novel.chapters.isEmpty && previous != null
          ? novel.withChapters(previous.novel.chapters)
          : novel;
      final ids = <int>{};
      if (stored.chapters.any((c) => c.id <= 0 || !ids.add(c.id))) {
        throw const FormatException('目录缺少唯一的稳定章节标识');
      }
      final document = <String, Object?>{
        'version': 1,
        'novel': stored.toSnapshot(),
        'chapters': [
          for (final chapter in stored.chapters)
            {'id': chapter.id, 'title': chapter.title},
        ],
      };
      final encoded = stored.chapters.length > 300
          ? await compute(_encodeMetadata, document)
          : _encodeMetadata(document);
      if (encoded.length > 4 * 1024 * 1024) {
        throw const FormatException('目录超过本地缓存大小限制');
      }
      await _atomicWrite(File('${_folder(novel.id).path}/book.json'), encoded);
      _books[novel.id] = OfflineBook(
        novel: stored,
        chapterBytes: previous?.chapterBytes ?? const {},
      );
      _changed(novel.id);
      return true;
    });
  }

  Future<bool> saveChapter(
    int id,
    int cid,
    String text, {
    required CacheEpoch epoch,
  }) async {
    if (text.trim().isEmpty) throw const FormatException('章节正文为空');
    final encoded = text.length > 20 * 1024
        ? await compute(_encodeBody, text)
        : _encodeBody(text);
    if (encoded.length > maxBodyBytes) {
      throw const FormatException('章节超过本地缓存大小限制');
    }
    await load();
    return _serialize(() async {
      if (!isCurrent(id, epoch)) return false;
      final previous = _books[id];
      // No orphan body: the saved directory is required for offline navigation.
      if (previous == null || !previous.chapterIds.contains(cid)) {
        return false;
      }
      await _atomicWrite(_body(id, cid), encoded);
      _books[id] = previous._withChapter(cid, encoded.length);
      _changed(id);
      return true;
    });
  }

  Future<void> removeBook(int id) {
    // Invalidate immediately, even when a write is already queued.
    _bookEpochs[id] = (_bookEpochs[id] ?? 0) + 1;
    return _serialize(() async {
      final folder = _folder(id);
      if (await folder.exists()) await folder.delete(recursive: true);
      _books.remove(id);
      _changed(id);
    });
  }

  Future<void> clear() {
    _allEpoch++;
    return _serialize(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
      _books.clear();
      _changed();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final observer in _bookChanges.values) {
      observer.dispose();
    }
    super.dispose();
  }
}

String formatCacheBytes(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
    : bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).ceil()} KB';
