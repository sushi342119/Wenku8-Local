import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'chapter_splitter.dart';
export 'chapter_splitter.dart' show LocalChapterIndex;
import 'local_platform.dart';
import 'book_tags.dart';
import 'local_record_removal.dart';
import 'local_source_identity.dart';

part 'local_text_worker.dart';

/// 本地图书 ID 段：避开文库在线 aid（通常远小于此），落在 int32 范围内，
/// 因此书架、历史、进度等既有 `id > 0` 逻辑无需改动。
const localNovelIdBase = 0x40000000;

bool isLocalNovelId(int id) =>
    id >= localNovelIdBase && id <= 0x7fffffff;

/// 扫描不完整时抛出的异常：entries 不可信，不能用于更新书库。
/// [reason] 为原生返回的原因：permission / enumeration_failed /
/// depth_limit / limit / null_result / unknown。
class IncompleteScanException implements Exception {
  const IncompleteScanException(this.reason);
  final String reason;

  /// 给用户看的提示文案。
  String get message => switch (reason) {
        'permission' => '无法访问该文件夹，请重新选择文件夹以授予访问权限',
        'enumeration_failed' => '无法完整读取该文件夹，请检查文件夹是否仍可访问后重试',
        'depth_limit' => '子文件夹层级太深，本次扫描未完成',
        'limit' => '文件数量超出扫描上限，本次扫描未完成',
        'null_result' => '未收到有效的扫描结果，请重试',
        _ => '扫描未完成，请重试',
      };
}

enum LocalBookKind { txt, pdf }

final _bookRevisionCache = Expando<String>();

/// 是否为 Unicode 空白字符。
bool _isUnicodeWhitespace(int rune) {
  return (rune >= 0x0009 && rune <= 0x000D) ||
      rune == 0x0020 ||
      rune == 0x0085 ||
      rune == 0x00A0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;
}

/// 统计文本的非空白 Unicode 字符数（含标点）。
int _countWords(String text) {
  var count = 0;
  for (final rune in text.runes) {
    if (!_isUnicodeWhitespace(rune)) {
      count++;
    }
  }
  return count;
}

/// 格式化字数：小于1万显示"1234 字"，大于等于1万显示"12.3 万字"。
String _formatWordCount(int count) {
  if (count < 10000) return '$count 字';
  return '${(count / 10000).toStringAsFixed(1)} 万字';
}

class LocalBook {
  const LocalBook({
    required this.id,
    required this.title,
    required this.author,
    required this.fileUri,
    required this.fileName,
    required this.kind,
    required this.size,
    required this.modified,
    required this.chapters,
    required this.pageCount,
    this.wordCount,
    this.customTitle,
    this.customAuthor,
    // 导入来源标识：'saf:<treeUri>' 或 'appFolder:novels'，用于按来源隔离清理。
    // 旧数据缺失时为 ''，不参与自动清理。
    this.sourceId = '',
    // 来源内稳定的文件身份：SAF 用 documentUri，应用文件夹用规范化绝对路径。
    this.sourceKey = '',
    this.chapterSplitVersion = 0,
    this.textFingerprint = '',
  });

  final int id;
  final String title;
  final String author;
  final String fileUri;
  final String fileName;
  final LocalBookKind kind;
  final int size;
  final int modified;
  final List<LocalChapterIndex> chapters;
  final int pageCount;

  /// 正文非空白 Unicode 字符数（含标点）；null 表示未统计。
  final int? wordCount;

  final String sourceId;
  final String sourceKey;

  /// 该书最近一次成功应用的章节切分规则版本。
  final int chapterSplitVersion;
  final String textFingerprint;
  String get revision => _bookRevisionCache[this] ??= sha256
      .convert(
        utf8.encode(
          jsonEncode([
            textFingerprint,
            chapterSplitVersion,
            chapters.map((c) => c.toJson()).toList(),
          ]),
        ),
      )
      .toString();

  /// 用户手动覆盖的书名/作者，为空时用文件名解析结果。
  final String? customTitle;
  final String? customAuthor;

  /// 展示用书名/作者（优先用户覆盖）。
  String get displayTitle =>
      (customTitle ?? '').trim().isEmpty ? title : customTitle!.trim();
  String get displayAuthor =>
      (customAuthor ?? '').trim().isEmpty ? author : customAuthor!.trim();

  /// 注意：customTitle/customAuthor 传 null 表示清空（恢复文件名解析）；
  /// wordCount 传 null 则表示保留原值（用于字数补算）。
  LocalBook copyWith({
    String? title,
    String? author,
    String? fileUri,
    String? fileName,
    String? sourceKey,
    String? customTitle,
    String? customAuthor,
    int? wordCount,
    List<LocalChapterIndex>? chapters,
    String? sourceId,
    int? chapterSplitVersion,
    String? textFingerprint,
  }) => LocalBook(
    id: id,
    title: title ?? this.title,
    author: author ?? this.author,
    fileUri: fileUri ?? this.fileUri,
    fileName: fileName ?? this.fileName,
    kind: kind,
    size: size,
    modified: modified,
    chapters: chapters ?? this.chapters,
    pageCount: pageCount,
    wordCount: wordCount ?? this.wordCount,
    customTitle: customTitle,
    customAuthor: customAuthor,
    sourceId: sourceId ?? this.sourceId,
    sourceKey: sourceKey ?? this.sourceKey,
    chapterSplitVersion: chapterSplitVersion ?? this.chapterSplitVersion,
    textFingerprint: textFingerprint ?? this.textFingerprint,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'uri': fileUri,
    'name': fileName,
    'kind': kind.name,
    'size': size,
    'modified': modified,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'pages': pageCount,
    'wordCount': wordCount,
    if (customTitle != null) 'customTitle': customTitle,
    if (customAuthor != null) 'customAuthor': customAuthor,
    if (sourceId.isNotEmpty) 'sourceId': sourceId,
    if (sourceKey.isNotEmpty) 'sourceKey': sourceKey,
    'chapterSplitVersion': chapterSplitVersion,
    'textFingerprint': textFingerprint,
  };

  factory LocalBook.fromJson(Map<String, Object?> json) {
    final chapters = json['chapters'];
    return LocalBook(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String? ?? '未知标题',
      author: json['author'] as String? ?? '',
      fileUri: json['uri'] as String? ?? '',
      fileName: json['name'] as String? ?? '',
      kind: json['kind'] == 'pdf' ? LocalBookKind.pdf : LocalBookKind.txt,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: (json['modified'] as num?)?.toInt() ?? 0,
      chapters: chapters is List
          ? chapters
              .whereType<Map<String, Object?>>()
              .map(LocalChapterIndex.fromJson)
              .toList()
          : const [],
      pageCount: (json['pages'] as num?)?.toInt() ?? 0,
      wordCount: (json['wordCount'] as num?)?.toInt(),
      customTitle: json['customTitle'] as String?,
      customAuthor: json['customAuthor'] as String?,
      sourceId: json['sourceId'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      chapterSplitVersion: (json['chapterSplitVersion'] as num?)?.toInt() ?? 0,
      textFingerprint: json['textFingerprint'] as String? ?? '',
    );
  }
}

/// 章节重切后待迁移的阅读进度任务（可恢复、幂等）。
/// 任务先于包含新章节表的 index.json 写入，调用方在
/// [LibraryState.remapChapterProgress] 成功写回进度后，才用
/// [LocalLibraryStore.confirmChapterRemap] 确认删除。
/// 失败时由 [LocalLibraryStore.markChapterRemapFailed] 保留失败信息，
/// 下次扫描仍会返回该任务，不依赖本轮扫描再次发现章节变化。
const _pendingChapterRemapsKey =
    'local_library_pending_chapter_remaps_v1';

String _chapterRemapMigrationId({
  required int bookId,
  required List<({int offset, int length})> oldChapters,
  required List<({int offset, int length})> newChapters,
}) {
  final source = jsonEncode({
    'bookId': bookId,
    'old': [
      for (final chapter in oldChapters)
        {'offset': chapter.offset, 'length': chapter.length},
    ],
    'new': [
      for (final chapter in newChapters)
        {'offset': chapter.offset, 'length': chapter.length},
    ],
  });
  var hash = 0x811c9dc5;
  for (final codeUnit in source.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return 'chremap-v1-$bookId-${hash.toRadixString(16)}';
}

List<({int offset, int length})> _decodeChapterRanges(Object? value) {
  if (value is! List) {
    throw const FormatException('chapter ranges must be a list');
  }
  final result = <({int offset, int length})>[];
  for (final item in value) {
    if (item is! Map) {
      throw const FormatException('chapter range must be an object');
    }
    final map = Map<String, dynamic>.from(item);
    final offset = map['offset'];
    final length = map['length'];
    // 损坏的持久化数据不能直接参与进度迁移：小数、负数一律拒绝，
    // 不能用 toInt() 静默截断。
    if (offset is! int || length is! int || offset < 0 || length < 0) {
      throw const FormatException('chapter range offset/length is invalid');
    }
    result.add((offset: offset, length: length));
  }
  return result;
}

class LocalChapterRemap {
  const LocalChapterRemap({
    required this.migrationId,
    required this.bookId,
    required this.oldChapters,
    required this.newChapters,
    this.oldRevision = '',
    this.newRevision = '',
    this.oldTextPath = '',
    this.newTextPath = '',
    this.newTitles = const [],
    this.status = 'pending',
    this.attempts = 0,
    this.lastError,
    this.lastFailedAt,
  });

  factory LocalChapterRemap.create({
    String oldRevision = '',
    String newRevision = '',
    String oldTextPath = '',
    String newTextPath = '',
    List<String> newTitles = const [],
    required int bookId,
    required List<({int offset, int length})> oldChapters,
    required List<({int offset, int length})> newChapters,
  }) {
    return LocalChapterRemap(
      oldRevision: oldRevision,
      newRevision: newRevision,
      oldTextPath: oldTextPath,
      newTextPath: newTextPath,
      newTitles: newTitles,
      migrationId:
          '${oldRevision.isEmpty ? '' : '$oldRevision-$newRevision-'}${_chapterRemapMigrationId(bookId: bookId, oldChapters: oldChapters, newChapters: newChapters)}',
      bookId: bookId,
      oldChapters: List.unmodifiable(oldChapters),
      newChapters: List.unmodifiable(newChapters),
    );
  }

  factory LocalChapterRemap.fromJson(Object value) {
    if (value is! Map) {
      throw const FormatException('chapter remap must be an object');
    }
    final map = Map<String, dynamic>.from(value);
    final migrationId = map['migrationId'];
    final rawBookId = map['bookId'];
    final rawStatus = map['status'];
    final rawAttempts = map['attempts'];
    final rawLastError = map['lastError'];
    final rawLastFailedAt = map['lastFailedAt'];
    if (migrationId is! String || migrationId.isEmpty) {
      throw const FormatException('chapter remap migrationId is invalid');
    }
    // 与章节区间一样的严格规则：小数、负数一律拒绝，不能用 toInt() 静默截断。
    if (rawBookId is! int || rawBookId <= 0) {
      throw const FormatException('chapter remap bookId is invalid');
    }
    if (rawStatus != null &&
        rawStatus != 'pending' &&
        rawStatus != 'failed') {
      throw const FormatException('chapter remap status is invalid');
    }
    if (rawAttempts != null &&
        (rawAttempts is! int || rawAttempts < 0)) {
      throw const FormatException('chapter remap attempts is invalid');
    }
    if (rawLastError != null && rawLastError is! String) {
      throw const FormatException('chapter remap lastError is invalid');
    }
    if (rawLastFailedAt != null &&
        (rawLastFailedAt is! int || rawLastFailedAt < 0)) {
      throw const FormatException('chapter remap lastFailedAt is invalid');
    }
    return LocalChapterRemap(
      migrationId: migrationId,
      bookId: rawBookId,
      oldChapters: List.unmodifiable(_decodeChapterRanges(map['oldChapters'])),
      newChapters: List.unmodifiable(_decodeChapterRanges(map['newChapters'])),
      oldRevision: map['oldRevision'] as String? ?? '',
      newRevision: map['newRevision'] as String? ?? '',
      oldTextPath: map['oldTextPath'] as String? ?? '',
      newTextPath: map['newTextPath'] as String? ?? '',
      newTitles: (map['newTitles'] as List?)?.cast<String>() ?? const [],
      status: rawStatus as String? ?? 'pending',
      attempts: rawAttempts as int? ?? 0,
      lastError: rawLastError as String?,
      lastFailedAt: rawLastFailedAt as int?,
    );
  }

  final String migrationId;
  final int bookId;
  final List<({int offset, int length})> oldChapters;
  final List<({int offset, int length})> newChapters;
  final String oldRevision, newRevision, oldTextPath, newTextPath;
  final List<String> newTitles;
  final String status;
  final int attempts;
  final String? lastError;
  final int? lastFailedAt;

  Map<String, dynamic> toJson() {
    return {
      'migrationId': migrationId,
      'bookId': bookId,
      'oldChapters': [
        for (final chapter in oldChapters)
          {'offset': chapter.offset, 'length': chapter.length},
      ],
      'newChapters': [
        for (final chapter in newChapters)
          {'offset': chapter.offset, 'length': chapter.length},
      ],
      'oldRevision': oldRevision,
      'newRevision': newRevision,
      'oldTextPath': oldTextPath,
      'newTextPath': newTextPath,
      'newTitles': newTitles,
      'status': status,
      'attempts': attempts,
      'lastError': lastError,
      'lastFailedAt': lastFailedAt,
    };
  }

  LocalChapterRemap withFailure(Object error) {
    return LocalChapterRemap(
      migrationId: migrationId,
      bookId: bookId,
      oldChapters: oldChapters,
      newChapters: newChapters,
      oldRevision: oldRevision,
      newRevision: newRevision,
      oldTextPath: oldTextPath,
      newTextPath: newTextPath,
      newTitles: newTitles,
      status: 'failed',
      attempts: attempts + 1,
      lastError: error.toString(),
      lastFailedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class LocalScanResult {
  const LocalScanResult({
    required this.added,
    required this.refreshed,
    required this.removed,
    required this.total,
    required this.skipped,
    this.backfilled = 0,
    this.failures = const {},
    this.switchedRemovedIds = const [],
    this.chapterRemaps = const [],
  });
  final int added;
  final int refreshed;
  final int removed;
  final int total;
  final int skipped;

  /// 静默补算了字数的旧书数量（不计入 added/refreshed，不弹提示）。
  final int backfilled;
  final Map<String, String> failures;

  /// 文件夹切换时被清理的旧来源书籍 ID（调用方据此清理书架/标签/进度）。
  final List<int> switchedRemovedIds;

  /// 章节重切（切分规则升级）导致章节表变化的书：调用方须据此迁移阅读
  /// 进度（旧章节序号在新章节表下指向不同内容）。这里返回的是持久化
  /// 的待迁移任务（见 [LocalChapterRemap]），不只是本轮新发现的变化：
  /// 上轮已落盘新章节表、但进度尚未迁移确认的任务，下次扫描仍会返回。
  final List<LocalChapterRemap> chapterRemaps;
}

/// 章节切分规则版本；与应用版本独立。
const _chapterSplitVersion = 3;

const _shelfPalette = [
  [Color(0xFF5C4A3A), Color(0xFF8A6F55)],
  [Color(0xFF3E5C50), Color(0xFF7A9B8A)],
  [Color(0xFF4A5468), Color(0xFF7B8AA5)],
  [Color(0xFF6B4A5A), Color(0xFF9B7A8A)],
  [Color(0xFF5A5A3E), Color(0xFF8F8F6B)],
  [Color(0xFF3A5C5C), Color(0xFF6E9B9B)],
];

String formatLocalSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 源文件已删除，但书籍记录保存失败（记录已恢复，可重试）。
class BookCleanupFailed implements Exception {
  const BookCleanupFailed(this.message);
  final String message;
}

/// 本地图书仓库：SAF 文件夹扫描、TXT 章节切分、PDF 页数。
/// 实现 [NovelRepository]，本地图书 id 落在 [localNovelIdBase] 段。
class LocalLibraryStore extends NovelRepository with ChangeNotifier {  LocalLibraryStore._(this._prefs, this._supportDir);

  final SharedPreferences _prefs;
  final Directory _supportDir;
  final List<LocalBook> _books = [];
  final Map<int, int> _bookPositions = {};
  final Map<int, LocalBook> _savedBookRefs = {};
  final LinkedHashMap<int, String> _textCache = LinkedHashMap();
  final Map<int, Future<String>> _textReads = {};
  static const _textCacheBudget = 8 * 1024 * 1024;
  var _textCacheBytes = 0;
  int _nextIdCursor = localNovelIdBase;
  int _reservedIdEnd = localNovelIdBase;
  final _textWorker = _LocalTextWorker();
  final Set<int> _dirtyBookIds = {};

  /// 串行化所有变更操作，防止扫描/删除/编辑竞态（修复#4）。
  Future<void> _mutationLock = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final next = _mutationLock.then((_) => action());
    _mutationLock = next.then((_) {}, onError: (_) {});
    return next;
  }

  static Future<LocalLibraryStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final support = await getApplicationSupportDirectory();
    final store = LocalLibraryStore._(prefs, support);
    await store._loadIndex();
    // 索引已加载进 _books 后，先记录已持久化的章节表快照，
    // 再向 UI 发布书库前恢复仅移出待办。
    store._captureSavedRemapRanges();
    await store._recordRemovalJournal.recover();
    return store;
  }

  Directory get _booksDir =>
      Directory('${_supportDir.path}/local_books');

  String? get folderUri => _prefs.getString('local_library_folder');

  List<LocalBook> get books => List.unmodifiable(_books);

  LocalBook? bookFor(int id) {
    final index = _indexForBook(id);
    return index < 0 ? null : _books[index];
  }

  LocalBookKind? kindFor(int id) => bookFor(id)?.kind;

  Future<void> _loadIndex() async {
    final file = File('${_booksDir.path}/index.json');
    _nextIdCursor =
        localNovelIdBase + (_prefs.getInt('local_library_next') ?? 0);
    _reservedIdEnd = _nextIdCursor;
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, Object?> && json['books'] is List) {
        for (final entry in (json['books'] as List).whereType<Map<String, Object?>>()) {
          try {
            final book = LocalBook.fromJson(entry);
            if (isLocalNovelId(book.id)) _books.add(book);
          } catch (_) {}
        }
      }
    } catch (_) {
      // 索引损坏时保留损坏文件，不静默覆盖（修复#5）。
      // 后续保存会创建 .bak，损坏文件保留供手动恢复。
    }
    // 校正 ID 计数器，防止复用（修复#17）。
    var maxId = localNovelIdBase - 1;
    for (final book in _books) {
      if (book.id > maxId) maxId = book.id;
    }
    final saved = _prefs.getInt('local_library_next') ?? 0;
    final need = maxId - localNovelIdBase + 1;
    final next = saved > need ? saved : need;
    _nextIdCursor = localNovelIdBase + next;
    _reservedIdEnd = _nextIdCursor;
    if (need > saved) await _prefs.setInt('local_library_next', need);
    _rebuildBookPositions();
    _savedBookRefs
      ..clear()
      ..addEntries(_books.map((book) => MapEntry(book.id, book)));
  }

  void _rebuildBookPositions() {
    _bookPositions
      ..clear()
      ..addEntries(
        _books.asMap().entries.map(
          (entry) => MapEntry(entry.value.id, entry.key),
        ),
      );
  }

  int _indexForBook(int id) => _bookPositions[id] ?? -1;

  void _replaceBook(int index, LocalBook book) {
    if (_books[index].revision != book.revision) _invalidateTextCache(book.id);
    _books[index] = book;
    _bookPositions[book.id] = index;
    _dirtyBookIds.add(book.id);
  }

  void _addBook(LocalBook book) {
    _bookPositions[book.id] = _books.length;
    _books.add(book);
    _dirtyBookIds.add(book.id);
  }

  void _removeBook(LocalBook book) {
    final index = _indexForBook(book.id);
    if (index < 0) return;
    _dirtyBookIds.add(book.id);
    _books.removeAt(index);
    _rebuildBookPositions();
    _invalidateTextCache(book.id);
  }

  void _removeBooks(Iterable<LocalBook> books) {
    final ids = books.map((book) => book.id).toSet();
    if (ids.isEmpty) return;
    _dirtyBookIds.addAll(ids);
    _books.removeWhere((book) => ids.contains(book.id));
    _rebuildBookPositions();
    for (final id in ids) {
      _invalidateTextCache(id);
    }
  }

  void _invalidateTextCache(int id) {
    final old = _textCache.remove(id);
    if (old != null) _textCacheBytes -= old.length * 2;
    _textReads.remove(id);
  }

  void _cacheText(int id, String text) {
    final size = text.length * 2;
    if (size > _textCacheBudget) return;
    final old = _textCache.remove(id);
    if (old != null) _textCacheBytes -= old.length * 2;
    _textCache[id] = text;
    _textCacheBytes += size;
    while (_textCacheBytes > _textCacheBudget && _textCache.isNotEmpty) {
      final first = _textCache.entries.first;
      _textCache.remove(first.key);
      _textCacheBytes -= first.value.length * 2;
    }
  }

  Future<void> _saveIndex() async {
    if (_dirtyBookIds.isEmpty) return;
    final changedIds = Set<int>.of(_dirtyBookIds);
    final dir = _booksDir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final json = jsonEncode({'books': _books.map((b) => b.toJson()).toList()});
    // 原子写入：先写临时文件再重命名，避免崩溃丢索引（修复#5）。
    final tmp = File('${dir.path}/index.json.tmp');
    final target = File('${dir.path}/index.json');
    await tmp.writeAsString(json, flush: true);
    // 保留上一次的备份。
    if (await target.exists()) {
      try {
        await target.copy('${dir.path}/index.json.bak');
      } catch (_) {}
    }
    await tmp.rename(target.path);
    // 索引成功提交后，只更新实际变化书籍的章节表快照。
    _captureSavedRemapRanges(changedIds);
    for (final id in changedIds) {
      final book = bookFor(id);
      if (book == null) {
        _savedBookRefs.remove(id);
      } else {
        _savedBookRefs[id] = book;
      }
    }
    _dirtyBookIds.clear();
    notifyListeners();
  }

  Future<void> Function(LocalChapterRemap)? migrateProgress;

  bool isMigrationPending(int id) =>
      _dirtyBookIds.contains(id) ||
      _readPendingChapterRemaps().any((r) => r.bookId == id);

  bool acceptsChapter(int id, NovelChapter chapter) =>
      !isMigrationPending(id) && bookFor(id)?.revision == chapter.revision;

  LocalChapterRemap _remapFor(LocalBook old, LocalBook next) =>
      LocalChapterRemap.create(
        bookId: old.id,
        oldRevision: old.revision,
        newRevision: next.revision,
        oldTextPath: textPathFor(old),
        newTextPath: textPathFor(next),
        newTitles: next.chapters.map((c) => c.title).toList(),
        oldChapters: [
          for (final c in old.chapters) (offset: c.offset, length: c.length),
        ],
        newChapters: [
          for (final c in next.chapters) (offset: c.offset, length: c.length),
        ],
      );

  Future<void> ensureReady(int id) => _synchronized(() async {
    // A failed index rename leaves only staged candidates in memory. Commit
    // them before exposing or migrating to that content revision.
    if (_dirtyBookIds.contains(id)) await _saveIndex();
    var book = bookFor(id);
    if (book == null || book.kind != LocalBookKind.txt) return;
    if (book.chapterSplitVersion != _chapterSplitVersion) {
      final remaps = <LocalChapterRemap>[];
      final updates = <int, LocalBook>{};
      final outcome = await _refreshBookIfNeeded(
        book,
        chapterRemaps: remaps,
        chapterUpdates: updates,
        chaptersStale: true,
      );
      if (outcome.failed) throw StateError('章节重建失败：${book.displayTitle}');
      await _stageChapterRemaps(remaps);
      for (final update in updates.values) {
        _replaceBook(_indexForBook(id), update);
      }
      await _saveIndex();
    }
    while (true) {
      final tasks = pendingChapterRemaps.where((r) => r.bookId == id).toList();
      if (tasks.isEmpty) {
        final currentRevision = _savedBookRefs[id]?.revision;
        final queued = _readPendingChapterRemaps();
        final orphan = queued.where((r) => r.bookId == id && r.oldRevision == currentRevision &&
            r.newRevision.isNotEmpty && r.newRevision != currentRevision).toList();
        if (orphan.isNotEmpty) {
          await _writePendingChapterRemaps(queued.where((r) => !orphan.contains(r)));
        }
        break;
      }
      final migrate = migrateProgress;
      if (migrate == null) throw StateError('阅读进度待迁移，请完成书库刷新');
      final task = tasks.first;
      try { await migrate(task); }
      catch (error) {
        await _writePendingChapterRemaps(_readPendingChapterRemaps().map((r) =>
          r.bookId == id && r.migrationId == task.migrationId ? r.withFailure(error) : r));
        rethrow;
      }
      await _writePendingChapterRemaps(
        _readPendingChapterRemaps().where(
          (r) => r.bookId != id || r.migrationId != task.migrationId,
        ),
      );
      notifyListeners();
    }
    if (isMigrationPending(id)) throw StateError('章节更新尚未提交');
  });

  /// ---- 章节迁移任务（可恢复）----
  List<LocalChapterRemap> _readPendingChapterRemaps() {
    final raw = _prefs.getString(_pendingChapterRemapsKey);
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('local chapter remap queue must be a list');
    }
    return [for (final item in decoded) LocalChapterRemap.fromJson(item)];
  }

  Future<void> _writePendingChapterRemaps(
    Iterable<LocalChapterRemap> remaps,
  ) async {
    // 不排序：队列必须保留产生顺序，同一本书 A→B、B→C 的迁移
    // 不能因 migrationId 的哈希字典序被打乱，否则调用方按序执行会串章。
    await _checkedSet(
      () => _prefs.setString(
        _pendingChapterRemapsKey,
        jsonEncode([for (final remap in remaps) remap.toJson()]),
      ),
      _pendingChapterRemapsKey,
    );
  }

  /// 把任务写成 journal。必须在 _saveIndex() 之前调用（扫描函数内部，
  /// 已在 _synchronized 保护内，不要再套一层锁）。
  Future<void> _stageChapterRemaps(Iterable<LocalChapterRemap> remaps) async {
    final incoming = remaps.toList();
    if (incoming.isEmpty) return;
    final merged = <String, LocalChapterRemap>{
      for (final remap in _readPendingChapterRemaps())
        _remapKey(remap.bookId, remap.migrationId): remap,
    };
    for (final remap in incoming) {
      // 已存在的失败记录要保留 lastError 和 attempts。
      merged.putIfAbsent(
        _remapKey(remap.bookId, remap.migrationId),
        () => remap,
      );
    }
    await _writePendingChapterRemaps(merged.values);
  }

  /// 最后一次成功加载／保存的章节表（按书 id）。
  /// 只用它筛选可执行任务：任务可以先于索引落盘写入 journal，
  /// 但只有新章节表已经随索引提交后，任务才能交给调用方迁移，
  /// 否则进度会迁到尚未落盘的表上，造成串章。
  Map<int, List<({int offset, int length})>> _savedRemapRanges = {};

  void _captureSavedRemapRanges([Iterable<int>? changedBookIds]) {
    final ids = changedBookIds?.toSet();
    if (ids == null) {
      _savedRemapRanges = {
        for (final book in _books)
          book.id: [
            for (final c in book.chapters) (offset: c.offset, length: c.length),
          ],
      };
      return;
    }
    for (final id in ids) {
      final book = bookFor(id);
      if (book == null) {
        _savedRemapRanges.remove(id);
      } else if (!identical(_savedBookRefs[id]?.chapters, book.chapters)) {
        _savedRemapRanges[id] = [
          for (final c in book.chapters) (offset: c.offset, length: c.length),
        ];
      }
    }
  }

  bool _sameRemapRanges(
    List<({int offset, int length})> a,
    List<({int offset, int length})> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 当前待处理任务的公开只读视图，供调用点和页面观察。
  /// 仅返回可以迁移到已持久化章节表的任务；尚未提交索引的任务
  /// 继续保留在原始队列中，不交出去。同一本书的迁移链按产生顺序
  /// 返回（从最终已提交的表反向找链，再正序还原）。
  List<LocalChapterRemap> get pendingChapterRemaps {
    // 按小胖补丁：返回终点章节表等于已落盘表的完整连续迁移链，
    // 且按持久化队列原顺序返回，不按书分组重排、不按 migrationId 排序。
    final queued = _readPendingChapterRemaps();
    final byBook = <int, List<LocalChapterRemap>>{};
    for (final remap in queued) {
      (byBook[remap.bookId] ??= <LocalChapterRemap>[]).add(remap);
    }
    final selected = <(int, String)>{};
    for (final entry in byBook.entries) {
      final saved = _savedRemapRanges[entry.key];
      if (saved == null) continue;
      final chain = entry.value;
      var end = -1;
      for (var i = 0; i < chain.length; i++) {
        if (_sameRemapRanges(chain[i].newChapters, saved) &&
            (chain[i].newRevision.isEmpty ||
             chain[i].newRevision == _savedBookRefs[entry.key]?.revision)) {
          end = i;
        }
      }
      if (end < 0) continue;
      var start = end;
      while (start > 0 &&
          _sameRemapRanges(
            chain[start - 1].newChapters,
            chain[start].oldChapters,
          ) && (chain[start - 1].newRevision.isEmpty || chain[start].oldRevision.isEmpty ||
              chain[start - 1].newRevision == chain[start].oldRevision)) {
        start--;
      }
      for (var i = start; i <= end; i++) {
        selected.add((entry.key, chain[i].migrationId));
        // 失败任务之后的同书任务不再暴露：必须等前置任务确认后
        // 才会再次出现，避免下一轮跳过失败项直接迁移后续。
        if (chain[i].status == 'failed') {
          break;
        }
      }
    }
    return List.unmodifiable([
      for (final remap in queued)
        if (selected.contains((remap.bookId, remap.migrationId))) remap,
    ]);
  }

  static String _remapKey(int bookId, String migrationId) =>
      '$bookId\u0000$migrationId';

  /// 一次性提交本轮迁移结果：成功任务删除，失败任务更新错误状态。
  /// 迁移本身仍按书、按队列顺序执行，持久化只读取和写回一次队列。
  Future<void> commitChapterRemapResults({
    required Iterable<({int bookId, String migrationId})> confirmed,
    required Iterable<({LocalChapterRemap remap, Object error})> failures,
  }) {
    return _synchronized(() async {
      final confirmations = confirmed.toList();
      final confirmedKeys = {
        for (final item in confirmations)
          _remapKey(item.bookId, item.migrationId),
      };
      final failedByKey = {
        for (final item in failures)
          _remapKey(item.remap.bookId, item.remap.migrationId): item,
      };
      if (confirmedKeys.isEmpty && failedByKey.isEmpty) return;
      final current = _readPendingChapterRemaps();
      final bookQueues = <int, Queue<String>>{};
      final present = <String>{};
      for (final item in current) {
        final key = _remapKey(item.bookId, item.migrationId);
        (bookQueues[item.bookId] ??= Queue<String>()).add(key);
        present.add(key);
      }
      for (final item in confirmations) {
        final key = _remapKey(item.bookId, item.migrationId);
        if (!present.remove(key)) continue;
        final queue = bookQueues[item.bookId]!;
        if (queue.first != key || failedByKey.containsKey(key)) {
          throw StateError(
            '同一本书必须按迁移任务产生顺序确认：${item.bookId}/${item.migrationId}',
          );
        }
        queue.removeFirst();
      }
      final next = <LocalChapterRemap>[];
      final seenPendingByBook = <int>{};
      final handled = <String>{};
      for (final item in current) {
        final key = _remapKey(item.bookId, item.migrationId);
        final failed = failedByKey[key];
        if (failed != null) {
          next.add(item.withFailure(failed.error));
          seenPendingByBook.add(item.bookId);
          handled.add(key);
        } else if (confirmedKeys.contains(key) &&
            !seenPendingByBook.contains(item.bookId)) {
          handled.add(key);
        } else {
          next.add(item);
          seenPendingByBook.add(item.bookId);
        }
      }
      // 失败可能来自一个刚刚入队但尚未被旧队列读到的任务；保留它。
      for (final entry in failedByKey.entries) {
        if (handled.contains(entry.key)) continue;
        next.add(entry.value.remap.withFailure(entry.value.error));
      }
      if (handled.isEmpty && failedByKey.isEmpty) return;
      if (next.isEmpty) {
        await _checkedSet(
          () => _prefs.remove(_pendingChapterRemapsKey),
          _pendingChapterRemapsKey,
        );
      } else {
        await _writePendingChapterRemaps(next);
      }
      notifyListeners();
    });
  }

  /// state.remapChapterProgress 成功返回后才能调用。
  Future<void> confirmChapterRemap(String migrationId, {required int bookId}) =>
      commitChapterRemapResults(
        confirmed: [(bookId: bookId, migrationId: migrationId)],
        failures: const [],
      );

  /// state 迁移失败后调用。即使任务因某种原因还没有入队，
  /// 这里也会把它重新放回可恢复队列。
  Future<void> markChapterRemapFailed(LocalChapterRemap remap, Object error) =>
      commitChapterRemapResults(
        confirmed: const [],
        failures: [(remap: remap, error: error)],
      );

  Future<void> _reserveIds(int count) async {
    if (count == 0) return;
    final end = (_nextIdCursor + count).clamp(_nextIdCursor, 0x80000000);
    if (end <= _reservedIdEnd) return;
    await _checkedSet(
      () => _prefs.setInt('local_library_next', end - localNovelIdBase),
      'local_library_next',
    );
    _reservedIdEnd = end;
  }

  int _nextId() {
    if (_nextIdCursor >= _reservedIdEnd || _nextIdCursor > 0x7fffffff) {
      throw StateError('本地书籍数量已达上限');
    }
    return _nextIdCursor++;
  }

  /// 打开系统文件夹选择器；用户取消返回 null。
  /// prefs 写入必须检查返回值：SharedPreferences 的 set 方法失败时返回 false
  /// 而非抛异常；关键路径上返回 false 必须视为失败并中断，避免静默丢数据。
  static Future<void> _checkedSet(
    Future<bool> Function() write,
    String what,
  ) async {
    try {
      final ok = await write();
      if (!ok) throw StateError('写入失败: $what');
    } catch (_) {
      await (await SharedPreferences.getInstance()).reload();
      rethrow;
    }
  }

  Future<String?> pickFolder() async {
    // 系统文件夹选择器（用户交互）不能在锁内；但 prefs 的读写要进 _synchronized，
    // 与 scan() 互斥，避免切换与扫描交错导致待清理列表或 folderUri 不一致。
    final uri = await LocalPlatform.pickLocalFolder();
    if (uri != null && uri.isNotEmpty) {
      await _synchronized(() async {
        final oldUri = _prefs.getString('local_library_folder');
        // 文件夹切换：把旧来源记入待清理列表，待新文件夹扫描成功后再清理旧书。
        // 不能在这里直接删——新文件夹可能扫描失败，删了用户就两头空了。
        // 用列表而非单个槽位：连续切换 A→B→C 时，A 和 B 都要保留到清理完成。
        if (oldUri != null && oldUri.isNotEmpty && oldUri != uri) {
          final pending =
              _prefs.getStringList('local_library_pending_cleanups') ?? [];
          if (!pending.contains(oldUri)) {
            pending.add(oldUri);
            await _checkedSet(
              () => _prefs.setStringList(
                'local_library_pending_cleanups',
                pending,
              ),
              'local_library_pending_cleanups',
            );
          }
        }
        await _checkedSet(
          () => _prefs.setString('local_library_folder', uri),
          'local_library_folder',
        );
      });
    }
    return uri;
  }

  /// 查看待清理关联数据（书架/标签/阅读进度）的书籍 ID 队列（不清空）。
  /// scan() 把切换时删除的旧书 ID 记入此队列；调用方逐个做幂等清理，
  /// 成功后用 [confirmAssociatedCleanupIds] 确认删除。
  /// "先读→清理→按成功条目确认" 避免"取出并清空"的中断丢失窗口。
  Future<List<int>> peekAssociatedCleanupIds() async {
    final raw =
        _prefs.getStringList('local_library_associated_cleanup') ?? [];
    final ids = <int>[];
    for (final s in raw) {
      final id = int.tryParse(s);
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// 确认已完成关联清理的 ID，从队列中移除。
  /// 未确认的 ID 保留，下次可重试。
  Future<void> confirmAssociatedCleanupIds(List<int> done) async {
    if (done.isEmpty) return;
    final raw =
        _prefs.getStringList('local_library_associated_cleanup') ?? [];
    if (raw.isEmpty) return;
    final doneSet = done.map((e) => '$e').toSet();
    final remaining = raw.where((s) => !doneSet.contains(s)).toList();
    if (remaining.isEmpty) {
      await _prefs.remove('local_library_associated_cleanup');
    } else {
      await _checkedSet(
        () => _prefs.setStringList(
            'local_library_associated_cleanup', remaining),
        'local_library_associated_cleanup',
      );
    }
  }

  /// ---- 标签暂存（文件夹切换时保留标签）----
  ///
  /// 切走文件夹时，被删书籍的标签按 `jsonEncode([sourceId, fileName])` 暂存；
  /// 切回后扫描成功时，文件名对上就恢复到新 ID 上。
  /// 只处理标签，不动书架和阅读进度。
  static const _tagStashKey = 'local_library_tag_stash';

  /// 暂存 key：用被删书籍自己的 sourceId（不是当前 sourceId）。
  /// jsonEncode 避免分隔符歧义。
  static String _tagStashKeyFor(LocalBook book) =>
      jsonEncode([book.sourceId, book.fileName]);

  Map<String, List<String>> _readTagStash() {
    try {
      final raw = _prefs.getString(_tagStashKey);
      if (raw == null) return {};
      final map = jsonDecode(raw);
      if (map is! Map<String, Object?>) return {};
      final out = <String, List<String>>{};
      map.forEach((k, v) {
        if (v is List) {
          final ids = v.whereType<String>().toList();
          if (ids.isNotEmpty) out[k] = ids;
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeTagStash(Map<String, List<String>> stash) =>
      _checkedSet(
        () => _prefs.setString(_tagStashKey, jsonEncode(stash)),
        _tagStashKey,
      );

  /// 文件夹切换删除书籍前暂存标签（_synchronized 内调用）。
  /// 明确覆盖规则：有标签则覆盖暂存，无标签则删除已有条目，
  /// 避免用户清空标签后旧条目复活。
  /// TagStore 未就绪时跳过（测试环境），不阻塞删除流程。
  Future<void> _stashTagsForRemoved(List<LocalBook> books) async {
    final tagStore = TagStore.maybeShared;
    if (tagStore == null || books.isEmpty) return;
    final stash = _readTagStash();
    var changed = false;
    for (final book in books) {
      final key = _tagStashKeyFor(book);
      final ids =
          tagStore.tagsForBook(book.id).map((t) => t.id).toList();
      if (ids.isEmpty) {
        if (stash.remove(key) != null) changed = true;
      } else {
        stash[key] = ids;
        changed = true;
      }
    }
    if (changed) await _writeTagStash(stash);
  }

  /// 清除指定书籍对应的暂存条目（文件被删 / 用户明确删除书籍时）。
  /// 不创建新暂存，只清理，避免同名新文件误恢复旧标签。
  Future<void> _clearTagStashKeys(Iterable<LocalBook> books) async {
    final stash = _readTagStash();
    if (stash.isEmpty) return;
    var changed = false;
    for (final book in books) {
      if (stash.remove(_tagStashKeyFor(book)) != null) changed = true;
    }
    if (changed) await _writeTagStash(stash);
  }

  /// 扫描成功后恢复暂存标签并清理失效条目（_synchronized 内，_saveIndex 之后）。
  /// - 只恢复给当前无标签的书，避免覆盖用户手动编辑；
  ///   无论是否恢复都消费条目（已恢复 / 用户已改过 / 标签已失效）。
  /// - 恢复前用现存标签定义过滤，过滤后为空也消费条目。
  /// - 完整扫描成功后，清理该来源下已不存在文件对应的条目，
  ///   避免以后新建同名文件时恢复旧标签。
  /// TagStore 未就绪时跳过。
  Future<void> _restoreStashedTags(String sourceId) async {
    final tagStore = TagStore.maybeShared;
    if (tagStore == null) return;
    final stash = _readTagStash();
    if (stash.isEmpty) return;
    // 该来源现存书籍的 key→book。
    final live = <String, LocalBook>{};
    for (final b in _books) {
      if (b.sourceId == sourceId) live[_tagStashKeyFor(b)] = b;
    }
    bool belongsToSource(String key) {
      try {
        final parts = jsonDecode(key);
        return parts is List && parts.length == 2 && parts[0] == sourceId;
      } catch (_) {
        return false;
      }
    }

    var changed = false;
    for (final key in stash.keys.where(belongsToSource).toList()) {
      final stashed = stash[key]!;
      final book = live[key];
      if (book == null) {
        // 文件已不存在（切走期间被删）：清理条目，不恢复。
        stash.remove(key);
        changed = true;
        continue;
      }
      final validIds = stashed
          .where((id) => tagStore.tagById(id) != null)
          .toList();
      if (validIds.isEmpty) {
        // 标签定义已全部失效：消费条目，不恢复。
        stash.remove(key);
        changed = true;
        continue;
      }
      // 只有当前无标签才恢复，避免覆盖用户手动编辑；
      // 有标签则视为用户已处理，直接消费条目。
      // 恢复成功后才删条目：setTagsForBook 抛错时异常向上传播，
      // _writeTagStash 不会执行，prefs 里的条目保留，下次扫描可重试。
      if (tagStore.tagsForBook(book.id).isEmpty) {
        await tagStore.setTagsForBook(book.id, validIds);
      }
      stash.remove(key);
      changed = true;
    }
    if (changed) await _writeTagStash(stash);
  }

  Future<void> forgetFolder() async {
    await _prefs.remove('local_library_folder');
  }

  /// ---- 「仅移出书库」忽略名单 ----
  ///
  /// 源文件删不掉时用户可选择仅移出书库（源文件保留）。被移出文件的
  /// [sourceId, sourceKey] 记入此名单，扫描时跳过，避免下次扫描又导入回来；
  /// 文件后来从磁盘消失（用户手动删除等）时，名单条目在扫描中自动清理。
  static const _ignoredSourcesKey = 'local_library_ignored_sources';

  /// 忽略名单的内存缓存：prefs 读取异常时用上次成功读到的名单兜底，
  /// 避免把「读不到」误判成「名单为空」而重新导入已移出的书。
  Set<String>? _ignoredCache;

  Set<String> _readIgnoredSources() {
    try {
      final set = (_prefs.getStringList(_ignoredSourcesKey) ?? []).toSet();
      _ignoredCache = Set.of(set);
      return set;
    } catch (_) {
      final cache = _ignoredCache;
      return cache == null ? {} : Set.of(cache);
    }
  }

  Future<void> _writeIgnoredSources(Set<String> ignored) async {
    await _checkedSet(
      () => _prefs.setStringList(_ignoredSourcesKey, ignored.toList()),
      _ignoredSourcesKey,
    );
    _ignoredCache = Set.of(ignored);
  }

  /// ---- 仅移出待办（可恢复）----
  static const _pendingRecordRemovalKey =
      'local.pending_record_removal.v1';

  Set<String> _readIgnoredSourcesForRemoval() {
    try {
      final values = _prefs.getStringList(_ignoredSourcesKey);
      final ignored = (values ?? <String>[]).toSet();
      _ignoredCache = Set<String>.of(ignored);
      return ignored;
    } catch (_) {
      final cached = _ignoredCache;
      if (cached != null) return Set<String>.of(cached);
      rethrow;
    }
  }

  RecordRemovalJournal get _recordRemovalJournal => RecordRemovalJournal(
    readIntent: () => _prefs.getString(_pendingRecordRemovalKey),
    writeIntent: (raw) async {
      if (raw == null) {
        await _checkedSet(
          () => _prefs.remove(_pendingRecordRemovalKey),
          _pendingRecordRemovalKey,
        );
      } else {
        await _checkedSet(
          () => _prefs.setString(_pendingRecordRemovalKey, raw),
          _pendingRecordRemovalKey,
        );
      }
    },
    readIgnored: _readIgnoredSourcesForRemoval,
    writeIgnored: _writeIgnoredSources,
    finishRemoval: (id) async {
      final book = bookFor(id);
      if (book != null) {
        // 待办已提交；这些步骤可以在恢复时重复执行。
        await _clearTagStashKeys([book]);
        // 在索引仍保留完整 LocalBook 时清理副本。
        // 崩溃后不用引入另一套 LocalBook 序列化协议。
        // 副本删不干净时抛错、保留已提交待办，不能先移出
        // 索引再清待办，否则残留副本没有恢复机会。
        final deleted = await _deleteBookData(book);
        if (!deleted) {
          throw StateError('内部副本删除失败，保留仅移出待办');
        }
        _removeBook(book);
      }
      // 保存失败会保留 dirty ID；已从内存移除的记录仍会在这里重试。
      // 已成功落盘的重复恢复无需再写索引。
      await _saveIndex();
    },
  );

  /// 书籍的有效忽略 key：统一走 [LocalSourceIdentity]，与两处扫描
  /// 的键生成规则一致。旧 appFolder 记录即使当前选中 SAF 文件夹，
  /// 仍属于 appFolder:novels，不会被当前文件夹覆盖。
  String _effectiveIgnoredKeyFor(LocalBook book) {
    return LocalSourceIdentity.forBook(
      sourceId: book.sourceId,
      sourceKey: book.sourceKey,
      fileUri: book.fileUri,
      folderUri: folderUri,
    ).ignoredKey;
  }

  /// 扫描已选文件夹：新增导入、内容变化的重新导入、源文件已删的移除。
  Future<LocalScanResult> scan({bool force = false}) => _synchronized(() async {
    // 扫描入口必须先恢复，尤其不能先扫描导入、最后才恢复。
    await _recordRemovalJournal.recover();
    final treeUri = folderUri;
    if (treeUri == null) throw StateError('请先选择小说文件夹');
    final sourceId = 'saf:$treeUri';
    final scanResult = await LocalPlatform.scanLocalFolder(treeUri);
    // 扫描不完整时 entries 不可信：直接抛错，不更新书库，
    // 也不清理旧书（调用方据此提示用户，而非显示"书库无变化"）。
    if (!scanResult.complete) {
      throw IncompleteScanException(scanResult.reason ?? 'unknown');
    }
    final entries = scanResult.entries;
    final failures = <String, String>{};
    final chapterRemaps = <LocalChapterRemap>[];
    final chapterUpdates = <int, LocalBook>{};
    // 忽略名单对账移除的书：先只移除记录，其内部副本等索引落盘后再删。
    final reconciledData = <LocalBook>[];
    // 按 sourceKey 索引当前来源的书籍，避免误删其他来源（修复#1）。
    final byKey = {
      for (final book in _books)
        if (book.sourceId == sourceId && book.sourceKey.isNotEmpty)
          book.sourceKey: book,
    };
    // 兼容旧数据：没有 sourceId 的书用 fileUri 匹配。
    final byUriLegacy = {
      for (final book in _books)
        if (book.sourceId.isEmpty) book.fileUri: book,
    };
    final seen = <String>{};
    final ignored = _readIgnoredSources();
    var added = 0, refreshed = 0, removed = 0, skipped = 0, backfilled = 0;
    await _reserveIds(
      entries.where((entry) {
        final uri = entry['uri'] as String? ?? '';
        return uri.isNotEmpty &&
            !byKey.containsKey(uri) &&
            !byUriLegacy.containsKey(uri) &&
            !ignored.contains(LocalSourceIdentity.saf(treeUri, uri).ignoredKey);
      }).length,
    );
    for (final entry in entries) {
      final uri = entry['uri'] as String? ?? '';
      final name = entry['name'] as String? ?? '';
      if (uri.isEmpty || name.isEmpty) continue;
      final sourceKey = uri;
      seen.add(sourceKey);
      // 「仅移出书库」的书：源文件还在，但用户已明确移出，跳过导入。
      // 忽略键统一走 LocalSourceIdentity，与 _effectiveIgnoredKeyFor 一致。
      if (ignored.contains(
        LocalSourceIdentity.saf(treeUri, sourceKey).ignoredKey,
      )) {
        skipped++;
        // 对账：记录若仍在库中（移出过程中进程中断、忽略已写但索引未落盘），
        // 在此完成移除，避免「书还在但永远被跳过」的死状态。
        // 内部副本延迟到本轮索引落盘后删除，避免中途抛错时索引与副本不一致。
        final existing = byKey[sourceKey] ?? byUriLegacy[uri];
        if (existing != null) {
          _removeBook(existing);
          reconciledData.add(existing);
          removed++;
        }
        continue;
      }
      final size = (entry['size'] as num?)?.toInt() ?? 0;
      final modified = (entry['modified'] as num?)?.toInt() ?? 0;
      var existing = byKey[sourceKey] ?? byUriLegacy[uri];
      if (existing != null) {
        if (existing.kind == LocalBookKind.pdf && !force &&
            existing.size == size && existing.modified == modified) {
          continue;
        }
        LocalBook? book;
        try {
          await _preserveCachedSnapshot(existing);
          book = await _importEntry(
            uri: uri,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
            existing: existing,
          );
        } catch (error) {
          failures['$name ($sourceKey)'] = error.toString();
          skipped++;
          continue;
        }
        if (book == null) {
          failures['$name ($sourceKey)'] = '文件为空、无法解码或超过导入大小限制';
          skipped++;
          continue;
        }
        if (!force && book.revision == existing.revision &&
            book.size == existing.size &&
            book.modified == existing.modified &&
            book.wordCount == existing.wordCount) {
          continue;
        }
        if (book.kind == LocalBookKind.txt && existing.chapters.isNotEmpty &&
            book.revision != existing.revision) {
          chapterRemaps.add(_remapFor(existing, book));
        }
        if (existing.wordCount == null && book.wordCount != null) backfilled++;
        chapterUpdates[book.id] = book;
        refreshed++;
      } else {
        LocalBook? book;
        try {
          book = await _importEntry(
            uri: uri,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
          );
        } catch (error) {
          failures['$name ($sourceKey)'] = error.toString();
          skipped++;
          continue;
        }
        if (book == null) {
          failures['$name ($sourceKey)'] = '文件为空、无法解码或超过导入大小限制';
          skipped++;
          continue;
        }
        _addBook(book);
        added++;
      }
    }
    // 忽略名单清理：本来源下源文件已不在磁盘上的条目自动移除，
    // 避免名单无限增长，也让同名新文件日后能正常导入。
    final staleIgnored = ignored.where((key) {
      try {
        final parts = jsonDecode(key);
        return parts is List &&
            parts.length == 2 &&
            parts[0] == sourceId &&
            !seen.contains(parts[1]);
      } catch (_) {
        return false;
      }
    }).toList();
    if (staleIgnored.isNotEmpty) {
      ignored.removeAll(staleIgnored);
      // 纯清理性质：写失败不中断正常扫描，下次扫描会再清。
      try {
        await _writeIgnoredSources(ignored);
      } catch (_) {}
    }
    // 只清理当前来源的书籍，不碰其他来源（修复#1）。
    // 能到这里扫描一定是完整的（不完整已在开头抛错）。
    final removedBooks = _books
        .where(
          (b) =>
              b.sourceId == sourceId &&
              b.sourceKey.isNotEmpty &&
              !seen.contains(b.sourceKey),
        )
        .toList();
    // 文件已从磁盘删除：不暂存标签，同时清除可能残留的暂存条目。
    if (removedBooks.isNotEmpty) {
      await _clearTagStashKeys(removedBooks);
    }
    for (final book in removedBooks) {
      await _deleteBookData(book);
      removed++;
    }
    _removeBooks(removedBooks);
    // 文件夹切换：新文件夹扫描成功后，清理待清理列表中的旧来源书籍。
    // 注意：不沿用 sourceKey.isNotEmpty 条件，避免旧来源下缺 sourceKey 的记录残留。
    //
    // 关键顺序（都在 _synchronized 保护内）：
    // 1. 重读当前 folderUri（提交时刻的值，而非扫描开始时捕获的 treeUri）：
    //    scan(B) 进行中用户切回 A 时，A 已是当前目录，不能按 u != treeUri 误删 A。
    // 2. 收集待删除书籍及其 ID（此时不删内存）。
    // 3. 关联清理 ID 先合并入持久化队列，成功后才继续——若入队失败，
    //    书仍在 _books 中，下次可重新收集 ID，不丢失。
    // 4. 删除书籍数据并移除内存记录。
    // 5. _saveIndex() 落盘。
    // 6. 落盘成功后，才从待清理列表中移除已处理的 URI；若 _saveIndex 失败，
    //    待清理记录与关联队列都保留，下次扫描可重试（关联清理操作本身幂等）。
    final pendingCleanups =
        _prefs.getStringList('local_library_pending_cleanups') ?? [];
    final currentUri = folderUri;
    final toClean = pendingCleanups
        .where((u) => u.isNotEmpty && u != currentUri)
        .toList();
    // 先收集，不删除。
    final toDelete = <LocalBook>[];
    for (final oldUri in toClean) {
      final oldSourceId = 'saf:$oldUri';
      toDelete.addAll(_books.where((b) => b.sourceId == oldSourceId));
    }
    final switchedRemovedIds = toDelete.map((b) => b.id).toList();
    // 先暂存被删书籍的标签（供切回时恢复），再入关联清理队列。
    // 顺序：读旧标签→stash 落盘→关联入队→删书，任一步失败都中断，
    // 书仍在 _books 中，下次可重试。
    if (toDelete.isNotEmpty) {
      await _stashTagsForRemoved(toDelete);
    }
    // 关联清理 ID 入队（删除内存记录之前）。
    if (switchedRemovedIds.isNotEmpty) {
      final queued =
          _prefs.getStringList('local_library_associated_cleanup') ?? [];
      final merged = <String>{...queued};
      for (final id in switchedRemovedIds) {
        merged.add('$id');
      }
      await _checkedSet(
        () => _prefs.setStringList(
          'local_library_associated_cleanup',
          merged.toList(),
        ),
        'local_library_associated_cleanup',
      );
    }
    // 入队成功后，才删除数据与内存记录。
    for (final book in toDelete) {
      await _deleteBookData(book);
    }
    _removeBooks(toDelete);
    // 先写迁移 journal，再写包含新章节表的 index。
    // 如果进程在这两步之间退出，下次扫描会根据 journal 重建/确认新表。
    await _stageChapterRemaps(chapterRemaps);
    for (final book in chapterUpdates.values) {
      final index = _indexForBook(book.id);
      if (index >= 0) _replaceBook(index, book);
    }
    await _saveIndex();
    // 索引落盘成功后，才确认消费待清理记录。
    if (toClean.isNotEmpty) {
      final remaining = pendingCleanups.where((u) => !toClean.contains(u)).toList();
      if (remaining.isEmpty) {
        await _prefs.remove('local_library_pending_cleanups');
      } else {
        await _checkedSet(
          () => _prefs.setStringList('local_library_pending_cleanups', remaining),
          'local_library_pending_cleanups',
        );
      }
    }
    // 索引已落盘：现在才删对账移除书籍的内部副本。
    for (final book in reconciledData) {
      await _deleteBookData(book);
    }
    // 完整扫描成功：恢复暂存标签（切回旧文件夹的场景），
    // 并清理该来源下已不存在文件对应的暂存条目。
    await _restoreStashedTags(sourceId);
    return LocalScanResult(
      added: added,
      refreshed: refreshed,
      removed: removed,
      total: _books.length,
      skipped: skipped,
      backfilled: backfilled,
      failures: failures,
      switchedRemovedIds: switchedRemovedIds,
      // 返回持久化队列而非仅本轮新发现的迁移：上轮已落盘新表、
      // 但进度未确认的任务，下次扫描仍要返回。
      chapterRemaps: pendingChapterRemaps,
    );
  });

  /// 备用方案：扫描应用外部文件夹中的 TXT（无需 SAF，直接用 dart:io 读取）。
  /// 用户需手动将小说 TXT 放入 [appFolderPath]/novels/ 目录。
  Future<String> get appFolderPath async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) throw StateError('无法获取应用外部存储目录');
    final novels = Directory('${dir.path}/novels');
    if (!await novels.exists()) await novels.create(recursive: true);
    return novels.path;
  }

  Future<LocalScanResult> scanAppFolder({
    bool force = false,
  }) => _synchronized(() async {
    // 与 scan() 同规则：先恢复仅移出待办，再扫描导入。
    await _recordRemovalJournal.recover();
    final folderPath = await appFolderPath;
    const sourceId = 'appFolder:novels';
    final dir = Directory(folderPath);
    final byKey = {
      for (final book in _books)
        if (book.sourceId == sourceId && book.sourceKey.isNotEmpty)
          book.sourceKey: book,
    };
    final byUriLegacy = {
      for (final book in _books)
        if (book.sourceId.isEmpty && book.fileUri.startsWith('file://'))
          book.fileUri: book,
    };
    final seen = <String>{};
    final ignored = _readIgnoredSources();
    final failures = <String, String>{};
    final chapterRemaps = <LocalChapterRemap>[];
    final chapterUpdates = <int, LocalBook>{};
    final reconciledData = <LocalBook>[];
    var added = 0, refreshed = 0, removed = 0, skipped = 0, backfilled = 0;
    final files = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    await _reserveIds(
      files
          .where(
            (file) =>
                file.path.toLowerCase().endsWith('.txt') &&
                !byKey.containsKey(file.path) &&
                !byUriLegacy.containsKey('file://${file.path}') &&
                !ignored.contains(
                  LocalSourceIdentity.appFolder(file.path).ignoredKey,
                ),
          )
          .length,
    );
    for (final file in files) {
      final name = file.path.split('/').last;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.txt')) continue;
      final uri = 'file://${file.path}';
      final sourceKey = file.path;
      seen.add(sourceKey);
      // 「仅移出书库」的书跳过导入；记录仍在时对账移除（与 scan() 同规则）。
      // 忽略键统一走 LocalSourceIdentity，与 _effectiveIgnoredKeyFor 一致。
      if (ignored.contains(
        LocalSourceIdentity.appFolder(file.path).ignoredKey,
      )) {
        skipped++;
        final existingIgnored = byKey[sourceKey] ?? byUriLegacy[uri];
        if (existingIgnored != null) {
          _removeBook(existingIgnored);
          reconciledData.add(existingIgnored);
          removed++;
        }
        continue;
      }
      final stat = await file.stat();
      final size = stat.size;
      final modified = stat.modified.millisecondsSinceEpoch;
      var existing = byKey[sourceKey] ?? byUriLegacy[uri];
      if (existing != null) {
        LocalBook? book;
        try {
          await _preserveCachedSnapshot(existing);
          book = await _importDirectFile(
            path: file.path,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
            existing: existing,
          );
        } catch (error) {
          failures['$name ($sourceKey)'] = error.toString();
          skipped++;
          continue;
        }
        if (book == null) {
          failures['$name ($sourceKey)'] = '文件为空、无法解码或超过导入大小限制';
          skipped++;
          continue;
        }
        if (!force && book.revision == existing.revision &&
            book.size == existing.size &&
            book.modified == existing.modified &&
            book.wordCount == existing.wordCount) {
          continue;
        }
        if (book.kind == LocalBookKind.txt && existing.chapters.isNotEmpty &&
            book.revision != existing.revision) {
          chapterRemaps.add(_remapFor(existing, book));
        }
        if (existing.wordCount == null && book.wordCount != null) backfilled++;
        chapterUpdates[book.id] = book;
        refreshed++;
      } else {
        LocalBook? book;
        try {
          book = await _importDirectFile(
            path: file.path,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
          );
        } catch (error) {
          failures['$name ($sourceKey)'] = error.toString();
          skipped++;
          continue;
        }
        if (book == null) {
          failures['$name ($sourceKey)'] = '文件为空、无法解码或超过导入大小限制';
          skipped++;
          continue;
        }
        _addBook(book);
        added++;
      }
    }
    // 只清理当前来源的书籍（修复#1）。
    final appRemovedBooks = _books
        .where(
          (b) =>
              b.sourceId == sourceId &&
              b.sourceKey.isNotEmpty &&
              !seen.contains(b.sourceKey),
        )
        .toList();
    // 文件已从磁盘删除：不暂存标签，同时清除可能残留的暂存条目。
    if (appRemovedBooks.isNotEmpty) {
      await _clearTagStashKeys(appRemovedBooks);
    }
    for (final book in appRemovedBooks) {
      await _deleteBookData(book);
      removed++;
    }
    _removeBooks(appRemovedBooks);
    // 忽略名单清理：本来源下源文件已消失的条目自动移除（与 scan() 同规则，
    // 写失败不中断扫描）。
    final staleIgnored = ignored.where((key) {
      try {
        final parts = jsonDecode(key);
        return parts is List &&
            parts.length == 2 &&
            parts[0] == sourceId &&
            !seen.contains(parts[1]);
      } catch (_) {
        return false;
      }
    }).toList();
    if (staleIgnored.isNotEmpty) {
      ignored.removeAll(staleIgnored);
      try {
        await _writeIgnoredSources(ignored);
      } catch (_) {}
    }
    // 先写迁移 journal，再写包含新章节表的 index（与 scan() 同规则）。
    await _stageChapterRemaps(chapterRemaps);
    for (final book in chapterUpdates.values) {
      final index = _indexForBook(book.id);
      if (index >= 0) _replaceBook(index, book);
    }
    await _saveIndex();
    for (final book in reconciledData) {
      await _deleteBookData(book);
    }
    // 完整扫描成功：恢复暂存标签并清理失效条目（与 scan() 同规则）。
    await _restoreStashedTags(sourceId);
    return LocalScanResult(
      added: added,
      refreshed: refreshed,
      removed: removed,
      total: _books.length,
      skipped: skipped,
      backfilled: backfilled,
      failures: failures,
      // 返回持久化队列而非仅本轮新发现的迁移（与 scan() 同规则）。
      chapterRemaps: pendingChapterRemaps,
    );
  });

  /// 直接从文件路径导入 TXT（纯 Dart，无需原生代码）。
  Future<LocalBook?> _importDirectFile({
    required String path,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    LocalBook? existing,
  }) async {
    const maxSize = 16 * 1024 * 1024;
    if (size > maxSize) throw const FormatException('TXT 超过 16 MiB 导入上限');
    final id = existing?.id ?? _nextId();
    final processed = await _importText(path, id, direct: true);
    if (processed.inputLength == 0) return null;
    return LocalBook(
      id: id,
      title: _titleFromName(name),
      author: _authorFromName(name),
      fileUri: 'file://$path',
      fileName: name,
      kind: LocalBookKind.txt,
      size: size,
      modified: modified,
      textFingerprint: processed.fingerprint,
      chapters: processed.chapters,
      pageCount: 0,
      wordCount: processed.wordCount,
      sourceId: sourceId,
      sourceKey: sourceKey,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
      chapterSplitVersion: _chapterSplitVersion,
    );
  }

  Future<void> removeBook(int id) => _synchronized(() async {
    final book = bookFor(id);
    if (book == null) return;
    await _deleteBookData(book);
    _removeBook(book);
    await _saveIndex();
  });

  /// 删除源文件并移除书籍记录（书架/标签/阅读进度由调用方清理）。
  /// 源文件删除失败时抛错且保留记录；记录保存失败时恢复内存记录并抛
  /// [BookCleanupFailed]（重试时文件不存在视为已删，可继续完成清理）。
  Future<void> deleteBookFile(int id) => _synchronized(() async {
    final book = bookFor(id);
    if (book == null) return;
    if (book.sourceId.startsWith('saf:')) {
      await LocalPlatform.deleteLocalDocument(book.fileUri);
    } else {
      final file = File(book.sourceKey);
      if (await file.exists()) await file.delete();
    }
    await _deleteBookData(book);
    final index = _indexForBook(book.id);
    _dirtyBookIds.add(book.id);
    _books.removeAt(index);
    _rebuildBookPositions();
    _invalidateTextCache(book.id);
    // 用户明确删除：不暂存标签，同时清除该书的暂存条目。
    await _clearTagStashKeys([book]);
    try {
      await _saveIndex();
    } catch (e) {
      _books.insert(index, book);
      _rebuildBookPositions();
      throw const BookCleanupFailed('书籍记录保存失败');
    }
  });

  /// 仅移出书库：删除内部副本与书籍记录，源文件保留在手机存储中。
  /// 记录加入忽略名单，后续扫描不会把同一源文件重新导入（扫描侧另有对账，
  /// 见 scan 中 ignored 分支）。
  /// 事务顺序（见 [RecordRemovalJournal]）：先写准备待办，再写忽略名单，
  /// 再写提交待办，最后清理标签/副本并保存索引。提交前失败回滚忽略名单，
  /// 书仍保留在库中；提交后失败抛 [RecordRemovalPending]，下次启动或
  /// 扫描时继续完成移除，不再声称“任何失败都留在库中”。书架/标签/
  /// 阅读进度的清理由调用方负责（与 [deleteBookFile] 相同约定）。
  Future<void> removeBookRecordOnly(int id) => _synchronized(() async {
    // 必须先恢复，不能用新操作覆盖旧待办。
    await _recordRemovalJournal.recover();
    final book = bookFor(id);
    if (book == null) return;
    final hasIgnoreKey = book.sourceKey.isNotEmpty || book.fileUri.isNotEmpty;
    String? ignoreKey;
    if (hasIgnoreKey) {
      try {
        ignoreKey = _effectiveIgnoredKeyFor(book);
      } catch (_) {
        // 来源无法确认时拒绝此次移出，不能先删记录再让下次扫描
        // 重新导入：记录保留，用户先扫描原目录回填来源后再移出。
        throw const BookCleanupFailed('无法确认源文件身份，请先扫描原目录后重试');
      }
    }
    try {
      await _recordRemovalJournal.remove(bookId: id, ignoreKey: ignoreKey);
    } on RecordRemovalPending {
      rethrow;
    } catch (_) {
      // 走到这里表示提交前失败，且回滚已经完成。
      throw const BookCleanupFailed('移除未提交，书籍仍保留在库中');
    }
  });

  /// 从书名派生安全的文件名（保留原扩展名及其大小写）。
  /// 返回 null 表示书名无法派生出合法文件名。
  static String? safeFileNameForTitle(String fileName, String title) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var stem = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    stem = stem.replaceAll(RegExp(r'[. ]+$'), '');
    if (stem.isEmpty || stem == '.' || stem == '..') return null;
    if (RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
      caseSensitive: false,
    ).hasMatch(stem)) {
      stem = '_$stem';
    }
    var name = '$stem$ext';
    if (name.length > 200) {
      final keep = 200 - ext.length;
      if (keep <= 0) return null;
      name = '${stem.substring(0, keep)}$ext';
    }
    return name;
  }

  /// 编辑书名/作者；书名变化时重命名源文件（保留原扩展名），book.id 不变。
  /// 成功返回更新后的 LocalBook；失败时抛错且不改动记录
  /// （重命名成功但索引保存失败时会尝试把文件名改回去）。
  Future<LocalBook> editBookFile(
    int id, {
    required String title,
    required String author,
  }) => _synchronized(() async {
    final index = _indexForBook(id);
    if (index < 0) throw StateError('书籍不存在');
    final book = _books[index];
    final cleanTitle = title.trim();
    final cleanAuthor = author.trim();
    if (cleanTitle.isEmpty) throw ArgumentError('书名不能为空');

    // 只有书名真正变化时才重命名文件（只改作者时不动文件）。
    var updated = book;
    final renamed = cleanTitle != book.displayTitle;
    if (renamed) {
      final targetName = safeFileNameForTitle(book.fileName, cleanTitle);
      if (targetName == null) throw ArgumentError('书名无法用作文件名');
      if (targetName != book.fileName) {
        if (book.sourceId.startsWith('saf:')) {
          final r = await LocalPlatform.renameLocalDocument(
            book.fileUri,
            targetName,
          );
          updated = updated.copyWith(
            title: cleanTitle,
            fileUri: r.fileUri,
            fileName: r.fileName,
            sourceKey: r.sourceKey,
          );
        } else {
          final dir = book.sourceKey.contains('/')
              ? book.sourceKey.substring(0, book.sourceKey.lastIndexOf('/'))
              : '';
          if (dir.isEmpty) throw StateError('文件路径无效');
          final targetPath = '$dir/$targetName';
          if (targetPath != book.sourceKey) {
            if (await File(targetPath).exists()) {
              throw StateError('同名文件已存在');
            }
            final renamedFile = await File(book.sourceKey).rename(targetPath);
            updated = updated.copyWith(
              title: cleanTitle,
              fileUri: Uri.file(renamedFile.path).toString(),
              fileName: targetName,
              sourceKey: renamedFile.path,
            );
          }
        }
      }
    }
    updated = updated.copyWith(
      customTitle: cleanTitle,
      customAuthor: cleanAuthor.isEmpty ? null : cleanAuthor,
    );
    try {
      _replaceBook(index, updated);
      await _saveIndex();
    } catch (e) {
      // 索引保存失败：尝试把文件名改回去。
      // - 回滚失败 → 内存恢复为原记录（磁盘索引未被修改过，与原记录一致）；
      // - 回滚成功 → 内存保留回滚后实际返回的记录，并尽力持久化；
      //   若持久化仍失败，内存为回滚后的真实状态，磁盘索引保持修改前的原记录。
      if (renamed && updated.fileName != book.fileName) {
        try {
          final rolledBack = await _renameBack(book, updated);
          _replaceBook(index, rolledBack);
          try {
            await _saveIndex();
          } catch (_) {
            // 回滚后的持久化仍失败：内存已是回滚后的真实状态，
            // 磁盘索引保持修改前的原记录。
          }
        } catch (_) {
          _replaceBook(index, book);
        }
      } else {
        _replaceBook(index, book);
      }
      rethrow;
    }
    notifyListeners();
    return updated;
  });

  /// 把重命名后的文件改回原名（editBookFile 回滚用）。
  /// 返回回滚后的实际文件信息（SAF 回滚可能产生新 URI）。
  Future<LocalBook> _renameBack(LocalBook original, LocalBook current) async {
    if (current.sourceId.startsWith('saf:')) {
      final r = await LocalPlatform.renameLocalDocument(
        current.fileUri,
        original.fileName,
      );
      return original.copyWith(
        fileUri: r.fileUri,
        fileName: r.fileName,
        sourceKey: r.sourceKey,
      );
    } else {
      final f = await File(current.sourceKey).rename(original.sourceKey);
      return original.copyWith(
        fileUri: Uri.file(f.path).toString(),
        fileName: original.fileName,
        sourceKey: f.path,
      );
    }
  }

  /// 内部副本清理是否完整成功。其他调用方仍按尽力清理处理，
  /// 只有仅移出提交路径（finishRemoval）把失败当成提交失败。
  Future<bool> _deleteBookData(LocalBook book) async {
    _invalidateTextCache(book.id);
    var ok = true;
    try {
      final textFile = File(textPathFor(book));
      if (await textFile.exists()) await textFile.delete();
    } catch (_) {
      ok = false;
    }
    if (book.kind == LocalBookKind.pdf) {
      try {
        await LocalPlatform.clearPdfCache(book.fileUri);
      } catch (_) {
        ok = false;
      }
    }
    return ok;
  }

  Future<LocalBook?> _importEntry({
    required String uri,
    required String name,
    required int size,
    required int modified,
    required String sourceId,
    required String sourceKey,
    LocalBook? existing,
  }) async {
    final lower = name.toLowerCase();
    final kind = lower.endsWith('.pdf') ? LocalBookKind.pdf : LocalBookKind.txt;
    // 刷新时保留原 ID，避免书架/进度失效（修复#3）。
    final id = existing?.id ?? _nextId();
    final title = _titleFromName(name);
    final author = _authorFromName(name);
    if (kind == LocalBookKind.pdf) {
      final pages = await LocalPlatform.pdfPageCount(uri);
      if (pages <= 0) return null;
      return LocalBook(
        id: id,
        title: title,
        author: author,
        fileUri: uri,
        fileName: name,
        kind: kind,
        size: size,
        modified: modified,
        chapters: const [],
        pageCount: pages,
        sourceId: sourceId,
        sourceKey: sourceKey,
        customTitle: existing?.customTitle,
        customAuthor: existing?.customAuthor,
        chapterSplitVersion: _chapterSplitVersion,
      );
    }
    if (size > 16 * 1024 * 1024) return null;
    final processed = await _importText(uri, id);
    if (processed.inputLength == 0) return null;
    return LocalBook(
      id: id,
      title: title,
      author: author,
      fileUri: uri,
      fileName: name,
      kind: kind,
      size: size,
      modified: modified,
      textFingerprint: processed.fingerprint,
      chapters: processed.chapters,
      pageCount: 0,
      wordCount: processed.wordCount,
      sourceId: sourceId,
      sourceKey: sourceKey,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
      chapterSplitVersion: _chapterSplitVersion,
    );
  }

  static String _titleFromName(String name) {
    var title = name;
    final dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    final dash = title.lastIndexOf(' - ');
    if (dash > 0) title = title.substring(0, dash);
    title = title.trim();
    return title.isEmpty ? name : title;
  }

  static String _authorFromName(String name) {
    var base = name;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    final dash = base.lastIndexOf(' - ');
    if (dash > 0) {
      final author = base.substring(dash + 3).trim();
      if (author.isNotEmpty && author.length <= 24) return author;
    }
    return '';
  }

  /// 章节切分：标题行做章节名，正文从标题行下一行开始。
  static List<LocalChapterIndex> _splitChapters(String text) =>
      splitLocalChapters(text);

  @visibleForTesting
  static List<LocalChapterIndex> splitChaptersForTest(String text) =>
      _splitChapters(text);

  @visibleForTesting
  static String titleFromNameForTest(String name) => _titleFromName(name);

  @visibleForTesting
  static String authorFromNameForTest(String name) => _authorFromName(name);

  Future<_TextMetadata> _importText(
    String source,
    int id, {
    bool direct = false,
  }) async {
    String? temporary;
    try {
      final path = direct && !LocalPlatform.android
          ? source
          : temporary = await LocalPlatform.prepareLocalText(
              direct ? Uri.file(source).toString() : source,
            );
      final result = await _textWorker.analyze(
        path,
        outputPath: '${_booksDir.path}/book_$id.staging',
        normalize: true,
        maxBytes: temporary == null ? 16 * 1024 * 1024 : null,
        preserveBom: temporary != null,
      );
      if (result.inputLength > 0) {
        final staged = File('${_booksDir.path}/book_$id.staging');
        final target = '${_booksDir.path}/book_${id}_${result.fingerprint}.txt';
        if (!await File(target).exists()) {
          await staged.rename(target);
        } else {
          await staged.delete();
        }
      }
      return result;
    } finally {
      if (temporary != null) {
        try {
          await File(temporary).delete();
        } catch (_) {
          /* Cache cleanup is best effort. */
        }
      }
    }
  }

  Future<void> _preserveCachedSnapshot(LocalBook book) async {
    final cached = _textCache[book.id];
    if (cached == null) return;
    final file = File(textPathFor(book));
    if (!await file.exists()) await file.writeAsString(cached, flush: true);
  }

  String textPathFor(LocalBook book) => book.textFingerprint.isEmpty
      ? '${_booksDir.path}/book_${book.id}.txt'
      : '${_booksDir.path}/book_${book.id}_${book.textFingerprint}.txt';

  Future<({String path, bool recovered})> _ensureBookTextPath(
    LocalBook book,
  ) async {
    final file = File(textPathFor(book));
    if (await file.exists()) return (path: file.path, recovered: false);
    final result = await _importText(
      book.sourceId == 'appFolder:novels' ? book.sourceKey : book.fileUri,
      book.id,
      direct: book.sourceId == 'appFolder:novels',
    );
    if (book.textFingerprint.isNotEmpty &&
        result.fingerprint != book.textFingerprint) {
      throw StateError('源文件内容已变化，请重新扫描：${book.displayTitle}');
    }
    final path = '${_booksDir.path}/book_${book.id}_${result.fingerprint}.txt';
    if (book.textFingerprint.isEmpty) await File(path).copy(file.path);
    return (path: file.path, recovered: true);
  }

  Future<String> _readBookText(LocalBook book) {
    final cached = _textCache.remove(book.id);
    if (cached != null) {
      _textCache[book.id] = cached;
      return Future.value(cached);
    }
    final pending = _textReads[book.id];
    if (pending != null) return pending;
    late final Future<String> future;
    // The source cannot be refreshed/deleted while this read restores its copy.
    future =
        _synchronized(() async {
          final current = bookFor(book.id);
          if (current == null) return '';
          final source = await _ensureBookTextPath(current);
          final text = await _textWorker.read(source.path, preserveBom: true);
          if (identical(_textReads[book.id], future)) {
            _cacheText(book.id, text);
          }
          return text;
        }).whenComplete(() {
          if (identical(_textReads[book.id], future)) {
            _textReads.remove(book.id);
          }
        });
    _textReads[book.id] = future;
    return future;
  }

  @override
  void dispose() {
    // Finish queued file operations before releasing the worker and cache.
    _mutationLock.then((_) {
      _textWorker.dispose();
      _textCache.clear();
      _textCacheBytes = 0;
    });
    super.dispose();
  }

  final _refreshErrors = <int, String>{};

  /// 章节切分规则升级或旧数据缺字数时，一次读取并处理正文，复用结果。
  Future<({bool wordCountBackfilled, bool chaptersRefreshed, bool failed})>
  _refreshBookIfNeeded(
    LocalBook existing, {
    required List<LocalChapterRemap> chapterRemaps,
    required Map<int, LocalBook> chapterUpdates,
    required bool chaptersStale,
  }) async {
    final needsWordCount =
        existing.kind == LocalBookKind.txt && existing.wordCount == null;
    if (!needsWordCount && !chaptersStale) {
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: false,
      );
    }
    final index = _indexForBook(existing.id);
    if (index < 0) {
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: true,
      );
    }
    if (existing.kind == LocalBookKind.pdf) {
      _replaceBook(
        index,
        existing.copyWith(
          chapterSplitVersion: _chapterSplitVersion,
          customTitle: existing.customTitle,
          customAuthor: existing.customAuthor,
        ),
      );
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: false,
      );
    }
    try {
      final current = _books[index];
      final source = await _ensureBookTextPath(current);
      final processed = await _textWorker.analyze(
        source.path,
        normalize: true,
        outputPath: '${_booksDir.path}/book_${current.id}.upgrading',
      );
      final normalized = File(
        '${_booksDir.path}/book_${current.id}_${processed.fingerprint}.txt',
      );
      await File(
        '${_booksDir.path}/book_${current.id}.upgrading',
      ).rename(normalized.path);
      if (processed.inputLength == 0) {
        return (
          wordCountBackfilled: false,
          chaptersRefreshed: false,
          failed: true,
        );
      }
      final canSplit = chaptersStale && processed.length > 0;
      final old = current.chapters;
      var chaptersChanged = false;
      if (canSplit) {
        if (processed.chapters.length != old.length) {
          chaptersChanged = true;
        } else {
          for (var i = 0; i < old.length; i++) {
            if (processed.chapters[i].title != old[i].title ||
                processed.chapters[i].offset != old[i].offset ||
                processed.chapters[i].length != old[i].length ||
                processed.chapters[i].volume != old[i].volume) {
              chaptersChanged = true;
              break;
            }
          }
        }
      }
      final updated = current.copyWith(
        wordCount: processed.wordCount,
        textFingerprint: processed.fingerprint,
        chapters: chaptersChanged ? processed.chapters : current.chapters,
        chapterSplitVersion: canSplit
            ? _chapterSplitVersion
            : current.chapterSplitVersion,
        customTitle: current.customTitle,
        customAuthor: current.customAuthor,
      );
      if (chaptersChanged || current.revision != updated.revision) {
        chapterRemaps.add(_remapFor(current, updated));
        // Candidate tables stay private until the whole remap journal commits.
        chapterUpdates[current.id] = updated;
      } else {
        _replaceBook(index, updated);
      }
      return (
        wordCountBackfilled: needsWordCount,
        chaptersRefreshed: chaptersChanged,
        failed: false,
      );
    } catch (error) {
      _refreshErrors[existing.id] = error.toString();
      return (
        wordCountBackfilled: false,
        chaptersRefreshed: false,
        failed: true,
      );
    }
  }

  Novel toNovel(LocalBook book) {
    final kindLabel = book.kind == LocalBookKind.pdf ? 'PDF' : 'TXT';
    final countLabel = book.kind == LocalBookKind.pdf
        ? '${book.pageCount} 页'
        : '${book.chapters.length} 章';
    final palette = _shelfPalette[book.id % _shelfPalette.length];
    // 组装简介：本地书籍 · TXT · 123 章 · 45.6 万字 · 2.5 MB
    // 只有 TXT 且已统计字数时才显示字数段
    final parts = <String>[
      '本地书籍',
      kindLabel,
      countLabel,
      if (book.kind == LocalBookKind.txt && book.wordCount != null)
        _formatWordCount(book.wordCount!),
      formatLocalSize(book.size),
    ];
    return Novel(
      id: book.id,
      title: book.displayTitle,
      author: book.displayAuthor,
      genre: '本地',
      summary: parts.join(' · '),
      colors: palette,
      isComplete: true,
      chapterCount: book.kind == LocalBookKind.pdf
          ? book.pageCount
          : book.chapters.length,
    );
  }

  // ---- NovelRepository ----

  @override
  Future<List<Novel>> list() async => _books.map(toNovel).toList();

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    // All local novels are complete; every sort keeps the existing book order.
    const pageSize = 20;
    final total = _books.length;
    final start = ((page - 1) * pageSize).clamp(0, total);
    final end = (start + pageSize).clamp(start, total);
    final items = [for (var i = start; i < end; i++) toNovel(_books[i])];
    return NovelPage(
      items: List.unmodifiable(items),
      page: page,
      totalPages: (total / pageSize).ceil(),
      totalItems: total,
    );
  }

  @override
  Future<Novel?> find(int id) async {
    final book = bookFor(id);
    return book == null ? null : toNovel(book);
  }

  @override
  Future<List<Novel>> search(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _books
        .where(
          (b) =>
              b.title.toLowerCase().contains(q) ||
              b.author.toLowerCase().contains(q),
        )
        .map(toNovel)
        .toList();
  }

  @override
  Future<Novel> detail(Novel novel) async => novel;

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    await ensureReady(id);
    final book = bookFor(id);
    if (book == null) return const [];
    if (book.kind == LocalBookKind.pdf) {
      return List.generate(
        book.pageCount,
        (i) => NovelChapter('第 ${i + 1} 页', '', id: i),
      );
    }
    return [
      for (var i = 0; i < book.chapters.length; i++)
        NovelChapter(
          book.chapters[i].title,
          '',
          id: i,
          revision: book.revision,
          volume: book.chapters[i].volume,
        ),
    ];
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final book = bookFor(novelId);
    if (book == null ||
        book.kind != LocalBookKind.txt ||
        book.chapters.isEmpty) {
      return '';
    }
    if (isMigrationPending(novelId) ||
        chapter.revision != book.revision ||
        chapter.id < 0 ||
        chapter.id >= book.chapters.length) {
      throw const StaleLocalChapterException();
    }
    final index = chapter.id;
    final ref = book.chapters[index];
    final text = await _readBookText(book);
    if (bookFor(novelId)?.revision != chapter.revision ||
        isMigrationPending(novelId)) {
      throw const StaleLocalChapterException();
    }
    if (!validChapterRanges(book.chapters, text.length)) {
      throw StateError('章节范围损坏，请重新扫描');
    }
    return text.substring(ref.offset, ref.offset + ref.length).trim();
  }
}

/// 从仓库中取出本地书库；仓库不是复合仓库时返回 null。
LocalLibraryStore? localLibraryOf(NovelRepository? repository) =>
    repository is LocalLibraryStore
    ? repository
    : repository is CompositeNovelRepository
    ? repository.local
    : null;

/// 本地优先的复合仓库：本地 id 走 [LocalLibraryStore]，其余走在线仓库。
class CompositeNovelRepository extends NovelRepository {
  const CompositeNovelRepository({required this.local, required this.remote});

  final LocalLibraryStore local;
  final NovelRepository remote;

  LocalBookKind? localKind(int id) =>
      isLocalNovelId(id) ? local.kindFor(id) : null;

  @override
  Future<List<Novel>> list() => remote.list();

  @override
  Future<Novel?> find(int id) =>
      isLocalNovelId(id) ? local.find(id) : remote.find(id);

  @override
  Future<List<Novel>> search(String query) async {
    final results = await local.search(query);
    results.addAll(await remote.search(query));
    return results;
  }

  @override
  Future<Novel> detail(Novel novel) => isLocalNovelId(novel.id)
      ? local.detail(novel)
      : remote.detail(novel);

  @override
  Future<List<NovelChapter>> chapters(int id) =>
      isLocalNovelId(id) ? local.chapters(id) : remote.chapters(id);

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      isLocalNovelId(novelId)
      ? local.chapterContent(novelId, chapter)
      : remote.chapterContent(novelId, chapter);
}

class StaleLocalChapterException implements Exception {
  const StaleLocalChapterException();
  @override
  String toString() => '章节目录已更新，请等待进度迁移后重新载入';
}
