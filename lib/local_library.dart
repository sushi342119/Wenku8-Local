import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'local_platform.dart';
import 'book_tags.dart';

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

class LocalChapterIndex {
  const LocalChapterIndex(this.title, this.offset, this.length);
  final String title;
  final int offset;
  final int length;

  Map<String, Object?> toJson() =>
      {'t': title, 'o': offset, 'l': length};

  factory LocalChapterIndex.fromJson(Map<String, Object?> json) =>
      LocalChapterIndex(
        json['t'] is String ? json['t'] as String : '正文',
        (json['o'] as num?)?.toInt() ?? 0,
        (json['l'] as num?)?.toInt() ?? 0,
      );
}

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
  }) =>
      LocalBook(
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

  /// 文件夹切换时被清理的旧来源书籍 ID（调用方据此清理书架/标签/进度）。
  final List<int> switchedRemovedIds;

  /// 章节重切（切分规则升级）导致章节表变化的书：调用方须据此迁移阅读
  /// 进度（旧章节序号在新章节表下指向不同内容）。oldChapters/newChapters
  /// 为 (字符起点, 长度) 列表。
  final List<
      ({
        int bookId,
        List<({int offset, int length})> oldChapters,
        List<({int offset, int length})> newChapters
      })> chapterRemaps;
}

/// 章节标题启发式：行首的"第X章/节/回"、Chapter N、序章/番外/后记等短行。
/// 章节标题行（切分版本 2）。实测用户书库的漏检主因：
/// 标题行常以多个全角空格（U+3000）缩进甚至居中（十余个），旧版行首只认
/// 半角空白且最多 8 个；数字常为全角（第１章）；标题尾随文字可达近 40 字。
/// 行首放宽到 32 个空白/括号字符、数字含全角、单位加「话/幕」，尾随放宽
/// 到 40 字，配合 _splitChapters 的总长 64 字上限防正文行误报。
final _chapterTitlePattern = RegExp(
  r'^[ \t　【\[（(]{0,32}(第[一二三四五六七八九十百千零〇两\d０-９ \t　]+[章节回集卷部篇话幕]|卷[一二三四五六七八九十百千零〇两\d０-９]+|Chapter[ \t]*\d+|序章|序曲|楔子|终章|终曲|番外(?:[ \t]*\d+)?|后记|前言|引子|尾声)[^\n]{0,40}$',
  multiLine: true,
);

/// 章节切分规则版本：规则变化时递增，scan 据此对存量书重切一次。
const _chapterSplitVersion = 2;

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
    return store;
  }

  Directory get _booksDir =>
      Directory('${_supportDir.path}/local_books');

  String? get folderUri => _prefs.getString('local_library_folder');

  List<LocalBook> get books => List.unmodifiable(_books);

  LocalBook? bookFor(int id) {
    for (final book in _books) {
      if (book.id == id) return book;
    }
    return null;
  }

  LocalBookKind? kindFor(int id) => bookFor(id)?.kind;

  Future<void> _loadIndex() async {
    final file = File('${_booksDir.path}/index.json');
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
    if (need > saved) await _prefs.setInt('local_library_next', need);
  }

  Future<void> _saveIndex() async {
    final dir = _booksDir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final json = jsonEncode({
      'books': _books.map((b) => b.toJson()).toList(),
    });
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
  }

  int _nextId() {
    final next = _prefs.getInt('local_library_next') ?? 0;
    final id = localNovelIdBase + next;
    if (id > 0x7fffffff) throw StateError('本地书籍数量已达上限');
    _prefs.setInt('local_library_next', next + 1);
    return id;
  }

  /// 打开系统文件夹选择器；用户取消返回 null。
  /// prefs 写入必须检查返回值：SharedPreferences 的 set 方法失败时返回 false
  /// 而非抛异常；关键路径上返回 false 必须视为失败并中断，避免静默丢数据。
  static Future<void> _checkedSet(
      Future<bool> Function() write, String what) async {
    final ok = await write();
    if (!ok) throw StateError('写入失败: $what');
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
                  'local_library_pending_cleanups', pending),
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

  static String _ignoredKeyFor(String sourceId, String sourceKey) =>
      jsonEncode([sourceId, sourceKey]);

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

  /// 书籍的有效忽略 key：sourceKey 为空用 fileUri 兜底；
  /// sourceId 为空（旧数据）用当前文件夹推导，与 scan 的 sourceId 对齐。
  String _effectiveIgnoredKeyFor(LocalBook book) {
    final sourceKey = book.sourceKey.isNotEmpty ? book.sourceKey : book.fileUri;
    var sourceId = book.sourceId;
    if (sourceId.isEmpty) {
      final folder = folderUri;
      if (folder != null && folder.isNotEmpty) sourceId = 'saf:$folder';
    }
    return _ignoredKeyFor(sourceId, sourceKey);
  }

  /// 扫描已选文件夹：新增导入、内容变化的重新导入、源文件已删的移除。
  Future<LocalScanResult> scan() => _synchronized(() async {
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
    // 章节切分规则版本落后时，本轮对存量书重切一次（按来源分别标记）。
    final chaptersStale = _prefs.getInt('local_library_chapter_split_v_saf') !=
        _chapterSplitVersion;
    final chapterRemaps = <
        ({
          int bookId,
          List<({int offset, int length})> oldChapters,
          List<({int offset, int length})> newChapters
        })>[];
    var chaptersRefreshFailed = false;
    // 忽略名单对账移除的书：先只移除记录，其内部副本等索引落盘后再删。
    final reconciledData = <LocalBook>[];
    // 按 sourceKey 索引当前来源的书籍，避免误删其他来源（修复#1）。
    final byKey = {
      for (final book in _books)
        if (book.sourceId == sourceId && book.sourceKey.isNotEmpty)
          book.sourceKey: book
    };
    // 兼容旧数据：没有 sourceId 的书用 fileUri 匹配。
    final byUriLegacy = {
      for (final book in _books)
        if (book.sourceId.isEmpty) book.fileUri: book
    };
    final seen = <String>{};
    final ignored = _readIgnoredSources();
    var added = 0, refreshed = 0, removed = 0, skipped = 0, backfilled = 0;
    for (final entry in entries) {
      final uri = entry['uri'] as String? ?? '';
      final name = entry['name'] as String? ?? '';
      if (uri.isEmpty || name.isEmpty) continue;
      final sourceKey = uri;
      seen.add(sourceKey);
      // 「仅移出书库」的书：源文件还在，但用户已明确移出，跳过导入。
      if (ignored.contains(_ignoredKeyFor(sourceId, sourceKey))) {
        skipped++;
        // 对账：记录若仍在库中（移出过程中进程中断、忽略已写但索引未落盘），
        // 在此完成移除，避免「书还在但永远被跳过」的死状态。
        // 内部副本延迟到本轮索引落盘后删除，避免中途抛错时索引与副本不一致。
        final existing = byKey[sourceKey] ?? byUriLegacy[uri];
        if (existing != null) {
          _books.remove(existing);
          reconciledData.add(existing);
          removed++;
        }
        continue;
      }
      final size = (entry['size'] as num?)?.toInt() ?? 0;
      final modified = (entry['modified'] as num?)?.toInt() ?? 0;
      var existing = byKey[sourceKey] ?? byUriLegacy[uri];
      if (existing != null) {
        if (existing.size == size && existing.modified == modified) {
          // 旧数据回填来源标识：sourceId 为空的书在忽略名单等逻辑里需要
          // 明确来源，按当前扫描来源补齐（sourceKey 同步为本次 uri）。
          if (existing.sourceId.isEmpty) {
            final idx = _books.indexWhere((b) => b.id == existing!.id);
            if (idx >= 0) {
              existing = _books[idx] = existing.copyWith(
                sourceId: sourceId,
                sourceKey: sourceKey,
                customTitle: existing.customTitle,
                customAuthor: existing.customAuthor,
              );
            }
          }
          // 文件未变但缺字数时静默补算（v15 之前导入的书）。
          if (await _backfillWordCount(existing)) backfilled++;
          if (chaptersStale) {
            final outcome =
                await _refreshChaptersIfStale(existing, chapterRemaps);
            if (outcome == 1) refreshed++;
            if (outcome == 2) chaptersRefreshFailed = true;
          }
          continue;
        }
        // 先尝试导入，成功后再删除旧数据（修复#3：避免失败后丢失）。
        LocalBook? book;
        try {
          book = await _importEntry(
            uri: uri,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
            existing: existing,
          );
        } catch (_) {
          skipped++;
          continue;
        }
        if (book == null) {
          skipped++;
          continue;
        }
        // 刷新时 ID 相同，_importEntry 已原地覆盖 book_$id.txt，无需再删除
        // （否则会删掉刚写入的新文件）。只有 ID 变化时才清理旧数据。
        if (book.id != existing.id) {
          await _deleteBookData(existing);
        }
        _books.remove(existing);
        _books.add(book);
        refreshed++;
      } else {
        final book = await _importEntry(
          uri: uri,
          name: name,
          size: size,
          modified: modified,
          sourceId: sourceId,
          sourceKey: sourceKey,
        );
        if (book == null) {
          skipped++;
          continue;
        }
        _books.add(book);
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
        .where((b) =>
            b.sourceId == sourceId &&
            b.sourceKey.isNotEmpty &&
            !seen.contains(b.sourceKey))
        .toList();
    // 文件已从磁盘删除：不暂存标签，同时清除可能残留的暂存条目。
    if (removedBooks.isNotEmpty) {
      await _clearTagStashKeys(removedBooks);
    }
    for (final book in removedBooks) {
      await _deleteBookData(book);
      _books.remove(book);
      removed++;
    }
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
      toDelete.addAll(
        _books.where((b) => b.sourceId == oldSourceId),
      );
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
            'local_library_associated_cleanup', merged.toList()),
        'local_library_associated_cleanup',
      );
    }
    // 入队成功后，才删除数据与内存记录。
    for (final book in toDelete) {
      await _deleteBookData(book);
      _books.remove(book);
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
    // 有单本重切失败时不写版本标记，下一轮扫描继续重试失败的书。
    if (chaptersStale && !chaptersRefreshFailed) {
      try {
        await _prefs.setInt(
            'local_library_chapter_split_v_saf', _chapterSplitVersion);
      } catch (_) {}
    }
    return LocalScanResult(
      added: added,
      refreshed: refreshed,
      removed: removed,
      total: _books.length,
      skipped: skipped,
      backfilled: backfilled,
      switchedRemovedIds: switchedRemovedIds,
      chapterRemaps: chapterRemaps,
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

  Future<LocalScanResult> scanAppFolder() => _synchronized(() async {
    final folderPath = await appFolderPath;
    const sourceId = 'appFolder:novels';
    final chaptersStale =
        _prefs.getInt('local_library_chapter_split_v_app') !=
            _chapterSplitVersion;
    final dir = Directory(folderPath);
    final byKey = {
      for (final book in _books)
        if (book.sourceId == sourceId && book.sourceKey.isNotEmpty)
          book.sourceKey: book
    };
    final byUriLegacy = {
      for (final book in _books)
        if (book.sourceId.isEmpty && book.fileUri.startsWith('file://'))
          book.fileUri: book
    };
    final seen = <String>{};
    final ignored = _readIgnoredSources();
    final chapterRemaps = <
        ({
          int bookId,
          List<({int offset, int length})> oldChapters,
          List<({int offset, int length})> newChapters
        })>[];
    var chaptersRefreshFailed = false;
    final reconciledData = <LocalBook>[];
    var added = 0, refreshed = 0, removed = 0, skipped = 0, backfilled = 0;
    final files = await dir.list().where((e) => e is File).cast<File>().toList();
    for (final file in files) {
      final name = file.path.split('/').last;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.txt')) continue;
      final uri = 'file://${file.path}';
      final sourceKey = file.path;
      seen.add(sourceKey);
      // 「仅移出书库」的书跳过导入；记录仍在时对账移除（与 scan() 同规则）。
      if (ignored.contains(_ignoredKeyFor(sourceId, sourceKey))) {
        skipped++;
        final existingIgnored = byKey[sourceKey] ?? byUriLegacy[uri];
        if (existingIgnored != null) {
          _books.remove(existingIgnored);
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
        if (existing.size == size && existing.modified == modified) {
          // 旧数据回填来源标识（与 scan() 同规则）。
          if (existing.sourceId.isEmpty) {
            final idx = _books.indexWhere((b) => b.id == existing!.id);
            if (idx >= 0) {
              existing = _books[idx] = existing.copyWith(
                sourceId: sourceId,
                sourceKey: sourceKey,
                customTitle: existing.customTitle,
                customAuthor: existing.customAuthor,
              );
            }
          }
          // 文件未变但缺字数时静默补算（v15 之前导入的书）。
          if (await _backfillWordCount(existing)) backfilled++;
          if (chaptersStale) {
            final outcome =
                await _refreshChaptersIfStale(existing, chapterRemaps);
            if (outcome == 1) refreshed++;
            if (outcome == 2) chaptersRefreshFailed = true;
          }
          continue;
        }
        LocalBook? book;
        try {
          book = await _importDirectFile(
            path: file.path,
            name: name,
            size: size,
            modified: modified,
            sourceId: sourceId,
            sourceKey: sourceKey,
            existing: existing,
          );
        } catch (_) {
          skipped++;
          continue;
        }
        if (book == null) {
          skipped++;
          continue;
        }
        // 刷新时 ID 相同，已原地覆盖，无需删除（否则删掉新文件）。
        if (book.id != existing.id) {
          await _deleteBookData(existing);
        }
        _books.remove(existing);
        _books.add(book);
        refreshed++;
      } else {
        final book = await _importDirectFile(
          path: file.path,
          name: name,
          size: size,
          modified: modified,
          sourceId: sourceId,
          sourceKey: sourceKey,
        );
        if (book == null) {
          skipped++;
          continue;
        }
        _books.add(book);
        added++;
      }
    }
    // 只清理当前来源的书籍（修复#1）。
    final appRemovedBooks = _books
        .where((b) =>
            b.sourceId == sourceId &&
            b.sourceKey.isNotEmpty &&
            !seen.contains(b.sourceKey))
        .toList();
    // 文件已从磁盘删除：不暂存标签，同时清除可能残留的暂存条目。
    if (appRemovedBooks.isNotEmpty) {
      await _clearTagStashKeys(appRemovedBooks);
    }
    for (final book in appRemovedBooks) {
      await _deleteBookData(book);
      _books.remove(book);
      removed++;
    }
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
    await _saveIndex();
    for (final book in reconciledData) {
      await _deleteBookData(book);
    }
    // 完整扫描成功：恢复暂存标签并清理失效条目（与 scan() 同规则）。
    await _restoreStashedTags(sourceId);
    if (chaptersStale && !chaptersRefreshFailed) {
      try {
        await _prefs.setInt(
            'local_library_chapter_split_v_app', _chapterSplitVersion);
      } catch (_) {}
    }
    return LocalScanResult(
      added: added,
      refreshed: refreshed,
      removed: removed,
      total: _books.length,
      skipped: skipped,
      backfilled: backfilled,
      chapterRemaps: chapterRemaps,
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
    if (size > maxSize) return null;
    // 流式读取并在过程中强制大小限制，防止 stat 与读取之间的竞态（修复#6）。
    Uint8List bytes;
    try {
      final file = File(path);
      final sink = BytesBuilder();
      var total = 0;
      await for (final chunk in file.openRead()) {
        total += chunk.length;
        if (total > maxSize) return null;
        sink.add(chunk);
      }
      bytes = sink.takeBytes();
    } catch (_) {
      return null;
    }
    String text;
    try {
      if (LocalPlatform.android) {
        // Android 用原生解码自动识别 UTF-8/GB18030。
        text = await LocalPlatform.decodeLocalText(bytes);
      } else {
        // 其他平台只支持严格 UTF-8。
        text = utf8.decode(bytes, allowMalformed: false);
      }
    } catch (_) {
      return null;
    }
    if (text.isEmpty) return null;
    if (text.startsWith('﻿')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 统计字数：非空白 Unicode 字符数（含标点）
    final wordCount = _countWords(text);
    final chapters = _splitChapters(text);
    final id = existing?.id ?? _nextId();
    final dir = _booksDir;
    if (!await dir.exists()) await dir.create(recursive: true);
    await File('${dir.path}/book_$id.txt').writeAsString(text);
    return LocalBook(
      id: id,
      title: _titleFromName(name),
      author: _authorFromName(name),
      fileUri: 'file://$path',
      fileName: name,
      kind: LocalBookKind.txt,
      size: size,
      modified: modified,
      chapters: chapters,
      pageCount: 0,
      wordCount: wordCount,
      sourceId: sourceId,
      sourceKey: sourceKey,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
    );
  }

  Future<void> removeBook(int id) => _synchronized(() async {
    final book = bookFor(id);
    if (book == null) return;
    await _deleteBookData(book);
    _books.remove(book);
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
    final index = _books.indexOf(book);
    _books.removeAt(index);
    // 用户明确删除：不暂存标签，同时清除该书的暂存条目。
    await _clearTagStashKeys([book]);
    try {
      await _saveIndex();
    } catch (e) {
      _books.insert(index, book);
      throw const BookCleanupFailed('书籍记录保存失败');
    }
  });

  /// 仅移出书库：删除内部副本与书籍记录，源文件保留在手机存储中。
  /// 记录加入忽略名单，后续扫描不会把同一源文件重新导入（扫描侧另有对账，
  /// 见 scan 中 ignored 分支）。
  /// 事务顺序：先清标签暂存并保存索引（源文件与内部副本都还在），成功后
  /// 才写忽略名单；任一步失败都恢复内存记录、标签暂存快照并重新保存索引，
  /// 回滚异常不覆盖原始失败，最终抛 [BookCleanupFailed]。这样任何失败都
  /// 收敛到「书还在库里」而不是半移出状态。书架/标签/阅读进度的清理由
  /// 调用方负责（与 [deleteBookFile] 相同约定）。
  Future<void> removeBookRecordOnly(int id) => _synchronized(() async {
    final book = bookFor(id);
    if (book == null) return;
    final index = _books.indexOf(book);
    final stashSnapshot = _readTagStash();
    final hasIgnoreKey = book.sourceKey.isNotEmpty || book.fileUri.isNotEmpty;
    final ignoreKey = hasIgnoreKey ? _effectiveIgnoredKeyFor(book) : null;
    _books.removeAt(index);
    try {
      await _clearTagStashKeys([book]);
      await _saveIndex();
      if (ignoreKey != null) {
        final ignored = _readIgnoredSources();
        if (ignored.add(ignoreKey)) await _writeIgnoredSources(ignored);
      }
    } catch (e) {
      _books.insert(index, book);
      try {
        await _writeTagStash(stashSnapshot);
      } catch (_) {}
      try {
        await _saveIndex();
      } catch (_) {}
      throw const BookCleanupFailed('书籍记录保存失败');
    }
    // 记录与忽略名单都落盘后才删内部副本；_deleteBookData 内部吞错，
    // 不会让已落盘的移除回滚。
    await _deleteBookData(book);
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
    final index = _books.indexWhere((b) => b.id == id);
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
      _books[index] = updated;
      await _saveIndex();
    } catch (e) {
      // 索引保存失败：尝试把文件名改回去。
      // - 回滚失败 → 内存恢复为原记录（磁盘索引未被修改过，与原记录一致）；
      // - 回滚成功 → 内存保留回滚后实际返回的记录，并尽力持久化；
      //   若持久化仍失败，内存为回滚后的真实状态，磁盘索引保持修改前的原记录。
      if (renamed && updated.fileName != book.fileName) {
        try {
          final rolledBack = await _renameBack(book, updated);
          _books[index] = rolledBack;
          try {
            await _saveIndex();
          } catch (_) {
            // 回滚后的持久化仍失败：内存已是回滚后的真实状态，
            // 磁盘索引保持修改前的原记录。
          }
        } catch (_) {
          _books[index] = book;
        }
      } else {
        _books[index] = book;
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

  Future<void> _deleteBookData(LocalBook book) async {
    try {
      final textFile = File('${_booksDir.path}/book_${book.id}.txt');
      if (await textFile.exists()) await textFile.delete();
    } catch (_) {}
    if (book.kind == LocalBookKind.pdf) {
      try {
        await LocalPlatform.clearPdfCache(book.fileUri);
      } catch (_) {}
    }
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
      );
    }
    if (size > 16 * 1024 * 1024) return null;
    var text = await LocalPlatform.readLocalText(uri);
    if (text.isEmpty) return null;
    if (text.startsWith('﻿')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final chapters = _splitChapters(text);
    final dir = _booksDir;
    if (!await dir.exists()) await dir.create(recursive: true);
    await File('${dir.path}/book_$id.txt').writeAsString(text);
    return LocalBook(
      id: id,
      title: title,
      author: author,
      fileUri: uri,
      fileName: name,
      kind: kind,
      size: size,
      modified: modified,
      chapters: chapters,
      pageCount: 0,
      sourceId: sourceId,
      sourceKey: sourceKey,
      customTitle: existing?.customTitle,
      customAuthor: existing?.customAuthor,
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
  static List<LocalChapterIndex> _splitChapters(String text) {
    final matches = _chapterTitlePattern.allMatches(text).toList();
    final valid = <RegExpMatch>[];
    for (final match in matches) {
      final title = match.group(0)!.trim();
      if (title.isNotEmpty && title.length <= 64) valid.add(match);
    }
    if (valid.length < 2) {
      return [LocalChapterIndex('正文', 0, text.length)];
    }
    final chapters = <LocalChapterIndex>[];
    for (var i = 0; i < valid.length; i++) {
      final title = valid[i].group(0)!.trim();
      final lineEnd = text.indexOf('\n', valid[i].end);
      final contentStart = lineEnd < 0 ? text.length : lineEnd + 1;
      final end = i + 1 < valid.length ? valid[i + 1].start : text.length;
      chapters.add(
        LocalChapterIndex(title, contentStart, (end - contentStart).clamp(0, text.length)),
      );
    }
    return chapters;
  }

  @visibleForTesting
  static List<LocalChapterIndex> splitChaptersForTest(String text) =>
      _splitChapters(text);

  @visibleForTesting
  static String titleFromNameForTest(String name) => _titleFromName(name);

  @visibleForTesting
  static String authorFromNameForTest(String name) => _authorFromName(name);

  Future<String> _readBookText(LocalBook book) async {
    final file = File('${_booksDir.path}/book_${book.id}.txt');
    if (await file.exists()) return file.readAsString();
    // 缓存被清理时按需重新导入。
    final text = await LocalPlatform.readLocalText(book.fileUri);
    await file.writeAsString(text);
    return text;
  }

  /// 章节切分规则升级后，对文件未变的存量书用应用内副本重切一次。
  /// 返回 0=无变化，1=已更新，2=失败（调用方据此推迟版本标记，下轮重试，
  /// 不能把失败与无变化混同）。更新时以 _books 中的当前对象为基底（保留
  /// 本轮刚补算的字数等），并把旧/新章节表写入 [remaps] 供调用方迁移进度。
  Future<int> _refreshChaptersIfStale(
    LocalBook existing,
    List<
            ({
              int bookId,
              List<({int offset, int length})> oldChapters,
              List<({int offset, int length})> newChapters
            })>
        remaps,
  ) async {
    if (existing.kind != LocalBookKind.txt) return 0;
    try {
      final index = _books.indexWhere((b) => b.id == existing.id);
      if (index < 0) return 2;
      final current = _books[index];
      final text = await _readBookText(current);
      if (text.isEmpty) return 2;
      final chapters = _splitChapters(text);
      final old = current.chapters;
      if (chapters.length == old.length) {
        var same = true;
        for (var i = 0; i < chapters.length; i++) {
          if (chapters[i].title != old[i].title ||
              chapters[i].offset != old[i].offset) {
            same = false;
            break;
          }
        }
        if (same) return 0;
      }
      // copyWith 传 null 会清空 customTitle/customAuthor，这里必须透传原值。
      _books[index] = current.copyWith(
        chapters: chapters,
        customTitle: current.customTitle,
        customAuthor: current.customAuthor,
      );
      remaps.add((
        bookId: current.id,
        oldChapters: [
          for (final c in old) (offset: c.offset, length: c.length)
        ],
        newChapters: [
          for (final c in chapters) (offset: c.offset, length: c.length)
        ],
      ));
      return 1;
    } catch (_) {
      return 2;
    }
  }

  /// v15 之前导入的 TXT 没有字数：扫描时用应用内副本一次性补算。
  /// 静默迁移，不计入 added/refreshed；单本失败不影响扫描整体。
  /// 返回 true 表示本次补算成功了一本。
  Future<bool> _backfillWordCount(LocalBook existing) async {
    if (existing.kind != LocalBookKind.txt || existing.wordCount != null) {
      return false;
    }
    try {
      final text = await _readBookText(existing);
      if (text.isEmpty) return false;
      final index = _books.indexWhere((b) => b.id == existing.id);
      if (index < 0) return false;
      // 注意 copyWith 传 null 会清空 customTitle/customAuthor，这里必须透传原值。
      _books[index] = existing.copyWith(
        wordCount: _countWords(text),
        customTitle: existing.customTitle,
        customAuthor: existing.customAuthor,
      );
      return true;
    } catch (_) {
      return false;
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
        NovelChapter(book.chapters[i].title, '', id: i),
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
    final index = chapter.id.clamp(0, book.chapters.length - 1);
    final ref = book.chapters[index];
    final text = await _readBookText(book);
    final end = (ref.offset + ref.length).clamp(0, text.length);
    final start = ref.offset.clamp(0, end);
    return text.substring(start, end).trim();
  }
}

/// 从仓库中取出本地书库；仓库不是复合仓库时返回 null。
LocalLibraryStore? localLibraryOf(NovelRepository? repository) =>
    repository is CompositeNovelRepository ? repository.local : null;

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
