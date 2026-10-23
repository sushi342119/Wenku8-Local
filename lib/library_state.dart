import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'library_backup.dart';
import 'book_tags.dart';
import 'performance_preferences.dart';
import 'app_typography.dart';

class ReadingPosition {
  const ReadingPosition({
    required this.chapter,
    required this.chapterId,
    required this.offset,
    required this.fraction,
    required this.fontSize,
    required this.width,
    required this.updatedAt,
    this.lineHeight = 1.72,
    this.paragraphIndex,
    this.paragraphFraction = 0,
    this.textScale = 1,
    this.typeface = 'system',
  });
  final int chapter;
  final int chapterId;
  final double offset;
  final double fraction;
  final double fontSize;
  final double width;
  final int updatedAt;
  final double lineHeight;
  final int? paragraphIndex;
  final double paragraphFraction;
  final double textScale;
  final String typeface;

  Map<String, Object> toJson() => {
    'chapter': chapter,
    'chapterId': chapterId,
    'offset': offset,
    'fraction': fraction,
    'fontSize': fontSize,
    'width': width,
    'updatedAt': updatedAt,
    'lineHeight': lineHeight,
    'paragraphIndex': ?paragraphIndex,
    'paragraphFraction': paragraphFraction,
    'textScale': textScale,
    'typeface': typeface,
  };

  factory ReadingPosition.fromJson(Map<String, dynamic> value) {
    double number(String key, double fallback) {
      final number = value[key];
      return number is num && number.isFinite ? number.toDouble() : fallback;
    }

    return ReadingPosition(
      chapter: value['chapter'] is int
          ? (value['chapter'] as int).clamp(0, 100000)
          : 0,
      chapterId: value['chapterId'] is int ? value['chapterId'] : 0,
      offset: number('offset', 0).clamp(0, double.infinity),
      fraction: number('fraction', 0).clamp(0, 1),
      fontSize: number('fontSize', 19),
      width: number('width', 0),
      updatedAt: value['updatedAt'] is int ? value['updatedAt'] : 0,
      lineHeight: number('lineHeight', 1.72).clamp(1.3, 2.2),
      paragraphIndex:
          value['paragraphIndex'] is int && value['paragraphIndex'] >= 0
          ? value['paragraphIndex']
          : null,
      paragraphFraction: number('paragraphFraction', 0).clamp(0, 1),
      textScale: number('textScale', 1).clamp(.5, 5),
      typeface: value['typeface'] == 'sourceHanSerif'
          ? 'sourceHanSerif'
          : 'system',
    );
  }
}

class ReaderBookmark {
  const ReaderBookmark({
    required this.id,
    required this.chapterTitle,
    required this.position,
  });
  final String id;
  final String chapterTitle;
  final ReadingPosition position;

  Map<String, Object> toJson() => {
    'id': id,
    'chapterTitle': chapterTitle,
    'position': position.toJson(),
  };

  factory ReaderBookmark.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['chapterTitle'];
    final position = json['position'];
    if (id is! String || id.isEmpty || title is! String || position is! Map) {
      throw const FormatException('Damaged bookmark');
    }
    return ReaderBookmark(
      id: id,
      chapterTitle: title,
      position: ReadingPosition.fromJson(Map<String, dynamic>.from(position)),
    );
  }
}

class LibraryState extends ChangeNotifier {
  LibraryState(this._prefs) {
    _shelf.addAll(
      ((_prefs.get('shelf') is List<String>)
              ? _prefs.getStringList('shelf')!
              : const <String>[])
          .map(int.tryParse)
          .whereType<int>()
          .where((id) => id > 0),
    );
    _hiddenHistory.addAll(
      ((_prefs.get('reading_history_hidden') is List<String>)
              ? _prefs.getStringList('reading_history_hidden')!
              : const <String>[])
          .map(int.tryParse)
          .whereType<int>()
          .where((id) => id > 0),
    );
    for (final key in _prefs.getKeys()) {
      if (key.startsWith('chapter_')) {
        final id = int.tryParse(key.substring('chapter_'.length));
        final value = _prefs.get(key);
        if (id != null && value is int) _chapters[id] = value.clamp(0, 100000);
      }
      if (key.startsWith('shelf_added_')) {
        final id = int.tryParse(key.substring('shelf_added_'.length));
        final value = _prefs.get(key);
        if (id != null && value is int) _added[id] = value;
      }
      if (key.startsWith('novel_meta_')) {
        try {
          final novel = Novel.fromSnapshot(
            jsonDecode(_prefs.getString(key)!) as Map<String, dynamic>,
          );
          _known[novel.id] = novel;
          _persistedNovels[novel.id] = novel;
        } catch (_) {
          // A damaged cache never removes its saved shelf ID or preferences.
        }
      }
      if (key.startsWith('reading_position_')) {
        final id = int.tryParse(key.substring('reading_position_'.length));
        if (id == null) continue;
        try {
          _positions[id] = ReadingPosition.fromJson(
            jsonDecode(_prefs.getString(key)!) as Map<String, dynamic>,
          );
        } catch (_) {
          // The legacy chapter index remains usable without a position record.
        }
      }
      if (key.startsWith('reader_bookmarks_')) {
        final id = int.tryParse(key.substring('reader_bookmarks_'.length));
        if (id == null || id <= 0) continue;
        try {
          final records = jsonDecode(_prefs.getString(key)!);
          if (records is! List) continue;
          final bookmarks = <ReaderBookmark>[];
          final ids = <String>{};
          for (final record in records) {
            try {
              final bookmark = ReaderBookmark.fromJson(
                Map<String, dynamic>.from(record as Map),
              );
              if (ids.add(bookmark.id)) bookmarks.add(bookmark);
            } catch (_) {
              // One damaged bookmark does not erase the remaining marks.
            }
          }
          bookmarks.sort(
            (a, b) => b.position.updatedAt.compareTo(a.position.updatedAt),
          );
          _bookmarks[id] = bookmarks;
        } catch (_) {
          // Resume records are independent of the bookmark list.
        }
      }
    }
    _theme = switch (_prefs.get('theme')) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    double preference(String key, double fallback, double min, double max) {
      final value = _prefs.get(key);
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    _fontSize = preference('readerFontSize', 19, 15, 27);
    _lineHeight = preference('readerLineHeight', 1.72, 1.3, 2.2);
    _reduceMotion = _prefs.get('reduceMotion') == true;
    _loadFontState();
    _performance = PerformancePreferences.fromRecords({
      for (final key in [
        PerformancePreferences.modeKey,
        ...PerformanceEffect.values.map((effect) => effect.preferenceKey),
      ])
        key: _prefs.get(key),
    });
    _glassBlur = preference('glassBlur', 8, 0, 24);
    _glassOpacity = preference('glassOpacity', .87, 0, 1);
    _keepScreenOn = _prefs.get('readerKeepScreenOn') == true;
    _shelfSort = switch (_prefs.get('shelfSort')) {
      'recentAdded' => 'recentAdded',
      'title' => 'title',
      _ => 'recentRead',
    };
    _shelfFilter = switch (_prefs.get('shelfFilter')) {
      'unread' => 'unread',
      'reading' => 'reading',
      'finished' => 'finished',
      _ => 'all',
    };
    final recent = _prefs.get('recentSearches');
    if (recent is List<String>) {
      final seen = <String>{};
      _recentSearches = recent
          .map((query) => query.trim())
          .where(
            (query) =>
                validSearchHistory(query) && seen.add(query.toLowerCase()),
          )
          .take(12)
          .toList(growable: false);
    }
  }

  final SharedPreferences _prefs;
  final _appearance = ChangeNotifier();
  final _application = ChangeNotifier();
  final _glassChanges = ChangeNotifier();
  final _readerSettings = ChangeNotifier();
  final _settings = ChangeNotifier();
  final _history = ChangeNotifier();
  final _bookmarkChanges = ChangeNotifier();
  final _searchChanges = ChangeNotifier();
  final _shelfViewChanges = ChangeNotifier();
  final _readerBehaviorChanges = ChangeNotifier();
  final Set<int> _shelf = {};
  final Set<int> _hiddenHistory = {};
  final Map<int, Novel> _known = {};
  final Map<int, Novel> _persistedNovels = {};
  final Map<int, int> _chapters = {};
  final Map<int, ReadingPosition> _positions = {};
  final Map<int, int> _added = {};
  final Map<int, List<ReaderBookmark>> _bookmarks = {};
  final Map<int, int> _shelfRevisions = {};
  List<String> _recentSearches = const [];
  String _shelfSort = 'recentRead';
  String _shelfFilter = 'all';
  bool _keepScreenOn = false;
  int _metadataEncodes = 0;
  Future<void> _positionWrites = Future.value();
  Completer<void>? _restoreBarrier;
  ThemeMode _theme = ThemeMode.system;
  double _fontSize = 19;
  double _lineHeight = 1.72;
  bool _reduceMotion = false;
  String _appFontId = appFontSystem.id;
  final List<AppFontEntry> _importedFonts = [];

  /// 已通过 FontLoader 注册的 family，避免重复加载。
  final Set<String> _loadedFontFamilies = {};

  /// 进行中的字体加载任务（按 family），并发调用等待同一任务。
  final Map<String, Future<bool>> _fontLoadInflight = {};
  PerformancePreferences _performance = const PerformancePreferences();
  double _glassBlur = 8;
  double _glassOpacity = .87;
  bool _disposed = false;
  bool _historyNotificationQueued = false;

  static Future<LibraryState> load() async {
    final prefs = await SharedPreferences.getInstance();
    await recoverLibraryRestore(prefs);
    return LibraryState(prefs);
  }

  Set<int> get shelf => Set.unmodifiable(_shelf);
  Listenable get appearanceChanges => _appearance;
  Listenable get applicationChanges => _application;
  Listenable get glassChanges => _glassChanges;
  Listenable get readerSettingsChanges => _readerSettings;
  Listenable get settingsChanges => _settings;
  Listenable get historyChanges => _history;
  Listenable get bookmarkChanges => _bookmarkChanges;
  Listenable get searchChanges => _searchChanges;
  Listenable get shelfViewChanges => _shelfViewChanges;
  Listenable get readerBehaviorChanges => _readerBehaviorChanges;
  List<String> get recentSearches => List.unmodifiable(_recentSearches);
  String get shelfSort => _shelfSort;
  String get shelfFilter => _shelfFilter;
  bool get keepScreenOn => _keepScreenOn;
  ThemeMode get theme => _theme;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  int get debugMetadataEncodeCount => _metadataEncodes;
  bool get reduceMotion => _reduceMotion;

  /// 当前字体 ID（稳定 ID，持久化）。
  String get appFontId => _appFontId;

  /// 全部可用字体：系统、内置、已导入。
  List<AppFontEntry> get allFonts => [
        appFontSystem,
        appFontSourceHanSerif,
        ..._importedFonts,
      ];

  List<AppFontEntry> get importedFonts => List.unmodifiable(_importedFonts);

  /// 当前字体条目；ID 失效时回退到系统字体。
  AppFontEntry get currentFont {
    for (final f in allFonts) {
      if (f.id == _appFontId) return f;
    }
    return appFontSystem;
  }

  /// 缺字回退链：用户字体 → 内置思源宋体 → 系统。
  List<String> get fontFamilyFallback {
    final family = currentFont.family;
    if (family == null || family == appFontSourceHanSerif.family) {
      return const [];
    }
    return const ['SourceHanSerifCN'];
  }

  /// 兼容旧代码：由字体 ID 映射回枚举。
  AppTypeface get appTypeface => _appFontId == appFontSourceHanSerif.id
      ? AppTypeface.sourceHanSerif
      : AppTypeface.system;
  PerformancePreferences get performance => _performance;
  bool get effectiveReduceMotion => _reduceMotion || !_performance.motion;
  double get glassBlur => _glassBlur;
  double get glassOpacity => _glassOpacity;

  bool contains(int id) => _shelf.contains(id);
  int chapterFor(int id) => _chapters[id] ?? _positions[id]?.chapter ?? 0;
  Novel? cachedNovel(int id) => _known[id];
  ReadingPosition? positionFor(int id) => _positions[id];
  List<ReaderBookmark> bookmarksFor(int id) =>
      List.unmodifiable(_bookmarks[id] ?? const <ReaderBookmark>[]);

  int? chapterForPosition(Novel novel, ReadingPosition position) {
    if (position.chapterId > 0) {
      final index = novel.chapters.indexWhere(
        (chapter) => chapter.id == position.chapterId,
      );
      return index < 0 ? null : index;
    }
    return position.chapter >= 0 && position.chapter < novel.chapters.length
        ? position.chapter
        : null;
  }

  bool hasRead(int id) =>
      _chapters.containsKey(id) || _positions.containsKey(id);
  int addedAt(int id) => _added[id] ?? 0;
  int shelfRevision(int id) => _shelfRevisions[id] ?? 0;
  int lastReadAt(int id) => _positions[id]?.updatedAt ?? 0;

  bool finishedReading(Novel novel) {
    final position = positionFor(novel.id);
    final count = novel.chapters.isEmpty
        ? novel.chapterCount
        : novel.chapters.length;
    if (position == null || count <= 0 || position.fraction < .995) {
      return false;
    }
    if (position.chapterId > 0 && novel.chapters.isNotEmpty) {
      return novel.chapters.last.id == position.chapterId;
    }
    return position.chapter == count - 1;
  }

  static bool validSearchHistory(String query) =>
      query.isNotEmpty &&
      query.length <= 120 &&
      !RegExp(r'[\x00-\x1f]').hasMatch(query);

  Future<void> recordSearch(String query) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => recordSearch(query));
    }
    final term = query.trim();
    if (!validSearchHistory(term)) return Future.value();
    return _queuePositionWrite(() async {
      if (_recentSearches.isNotEmpty && _recentSearches.first == term) return;
      final next = [
        term,
        ..._recentSearches.where(
          (old) => old.toLowerCase() != term.toLowerCase(),
        ),
      ].take(12).toList(growable: false);
      await writeLibraryPreference(_prefs, 'recentSearches', next);
      _recentSearches = next;
      if (!_disposed) _searchChanges.notifyListeners();
    });
  }

  Future<void> clearRecentSearches() {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => clearRecentSearches());
    }
    return _queuePositionWrite(() async {
      await writeLibraryPreference(_prefs, 'recentSearches', <String>[]);
      _recentSearches = const [];
      if (!_disposed) _searchChanges.notifyListeners();
    });
  }

  Future<void> setShelfView({String? sort, String? filter}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setShelfView(sort: sort, filter: filter),
      );
    }
    await _queuePositionWrite(() async {
      final nextSort = ['recentRead', 'recentAdded', 'title'].contains(sort)
          ? sort!
          : _shelfSort;
      final nextFilter =
          ['all', 'unread', 'reading', 'finished'].contains(filter)
          ? filter!
          : _shelfFilter;
      await _commitLibraryRecords({
        'shelfSort': nextSort,
        'shelfFilter': nextFilter,
      });
      if (nextSort != _shelfSort || nextFilter != _shelfFilter) {
        _shelfSort = nextSort;
        _shelfFilter = nextFilter;
        if (!_disposed) _shelfViewChanges.notifyListeners();
      }
    });
  }

  Future<void> setKeepScreenOn(bool value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setKeepScreenOn(value));
    }
    await _queuePositionWrite(() async {
      await writeLibraryPreference(_prefs, 'readerKeepScreenOn', value);
      if (_keepScreenOn != value) {
        _keepScreenOn = value;
        if (!_disposed) {
          _readerBehaviorChanges.notifyListeners();
          _settings.notifyListeners();
        }
      }
    });
  }

  List<int> get readingHistoryIds {
    final ids =
        {
            ..._chapters.keys,
            ..._positions.keys,
          }.where((id) => id > 0 && !_hiddenHistory.contains(id)).toList()
          ..sort((a, b) {
            final time = lastReadAt(b).compareTo(lastReadAt(a));
            return time != 0 ? time : a.compareTo(b);
          });
    return List.unmodifiable(ids);
  }

  void _historyChanged() {
    if (_disposed) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_historyNotificationQueued) return;
      _historyNotificationQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _historyNotificationQueued = false;
        if (!_disposed) _history.notifyListeners();
      });
      return;
    }
    _history.notifyListeners();
  }

  Future<void> _queuePositionWrite(Future<void> Function() write) {
    _positionWrites = _positionWrites.catchError((Object _) {}).then((_) async {
      if (_prefs.get(restoreJournalKey) != null) {
        await recoverLibraryRestore(_prefs);
      }
      await write();
    });
    return _positionWrites;
  }

  /// Hide history without destroying resume positions, shelf or body files.
  Future<void> hideReadingHistory(int id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => hideReadingHistory(id));
    }
    return _queuePositionWrite(() async {
      if (id <= 0 || !hasRead(id) || _hiddenHistory.contains(id)) return;
      final next = {..._hiddenHistory, id};
      await writeLibraryPreference(
        _prefs,
        'reading_history_hidden',
        next.map((id) => '$id').toList(),
      );
      _hiddenHistory
        ..clear()
        ..addAll(next);
      _historyChanged();
    });
  }

  /// 彻底清除某本书的阅读进度、章节与历史隐藏标记（用于源文件被删除时）。
  /// 即使内存中没有条目，也尝试删除持久化键，保证重试能清干净。
  Future<void> clearBookProgress(int id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => clearBookProgress(id));
    }
    return _queuePositionWrite(() async {
      if (id <= 0) return;
      _positions.remove(id);
      _chapters.remove(id);
      _hiddenHistory.remove(id);
      _known.remove(id);
      await _prefs.remove('reading_position_$id');
      await _prefs.remove('chapter_$id');
      _historyChanged();
      notifyListeners();
    });
  }

  /// 本地书章节重切（切分规则升级）后迁移阅读进度，避免按旧章节序号串章。
  /// 锚点换算：旧章节字符起点 + 旧滚动比例 × 旧章节长度 ≈ 全书字符位置，
  /// 再落到包含该位置的新章节，章内比例按新章节长度折算。落点是近似位置
  /// （比例来自滚动而非字符），但保证仍在原来读到的那段文字附近。
  /// 段落锚点与像素偏移一并作废（width 置 0 强制阅读器按比例恢复），
  /// updatedAt 保持不变，不扰动「最近阅读」排序。无进度记录时不处理。
  Future<void> remapChapterProgress(
    int id, {
    required List<({int offset, int length})> oldChapters,
    required List<({int offset, int length})> newChapters,
  }) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => remapChapterProgress(
          id,
          oldChapters: oldChapters,
          newChapters: newChapters,
        ),
      );
    }
    return _queuePositionWrite(() async {
      if (id <= 0 || oldChapters.isEmpty || newChapters.isEmpty) return;
      final pos = _positions[id];
      final savedChapter = _chapters[id];
      if (pos == null && savedChapter == null) return;
      final oldIndex = (pos?.chapter ?? savedChapter!)
          .clamp(0, oldChapters.length - 1);
      final oldChapter = oldChapters[oldIndex];
      final global = oldChapter.offset +
          ((pos?.fraction ?? 0) * oldChapter.length).round();
      var newIndex = newChapters.length - 1;
      for (var i = 0; i < newChapters.length; i++) {
        if (global < newChapters[i].offset + newChapters[i].length) {
          newIndex = i;
          break;
        }
      }
      final newChapter = newChapters[newIndex];
      final newFraction = newChapter.length > 0
          ? ((global - newChapter.offset) / newChapter.length)
              .clamp(0.0, 1.0)
              .toDouble()
          : 0.0;
      _chapters[id] = newIndex;
      ReadingPosition? newPos;
      if (pos != null) {
        newPos = ReadingPosition(
          chapter: newIndex,
          chapterId: newIndex,
          offset: 0,
          fraction: newFraction,
          fontSize: pos.fontSize,
          width: 0,
          updatedAt: pos.updatedAt,
          lineHeight: pos.lineHeight,
          textScale: pos.textScale,
          typeface: pos.typeface,
        );
        _positions[id] = newPos;
      }
      // 先写阅读位置、后写章节键：中途崩溃时旧章节键与旧位置仍成对，
      // 不会出现「新章节键 + 旧位置」的错位组合。
      if (newPos != null) {
        await writeLibraryPreference(
          _prefs,
          'reading_position_$id',
          jsonEncode(newPos.toJson()),
        );
      }
      await writeLibraryPreference(_prefs, 'chapter_$id', newIndex);
      notifyListeners();
    });
  }

  Future<void> clearReadingHistory() {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => clearReadingHistory());
    }
    return _queuePositionWrite(() async {
      final visible = readingHistoryIds;
      if (visible.isEmpty) return;
      final next = {..._hiddenHistory, ...visible};
      await writeLibraryPreference(
        _prefs,
        'reading_history_hidden',
        next.map((id) => '$id').toList(),
      );
      _hiddenHistory
        ..clear()
        ..addAll(next);
      _historyChanged();
    });
  }

  Future<void> restoreReadingHistory(int id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => restoreReadingHistory(id));
    }
    return _queuePositionWrite(() async {
      if (id <= 0 || !hasRead(id) || !_hiddenHistory.contains(id)) return;
      final next = {..._hiddenHistory}..remove(id);
      await writeLibraryPreference(
        _prefs,
        'reading_history_hidden',
        next.map((id) => '$id').toList(),
      );
      _hiddenHistory
        ..clear()
        ..addAll(next);
      _historyChanged();
    });
  }

  int chapterForNovel(Novel novel) {
    final position = _positions[novel.id];
    if (position != null && position.chapterId > 0) {
      final index = novel.chapters.indexWhere(
        (chapter) => chapter.id == position.chapterId,
      );
      if (index >= 0) return index;
    }
    final count = novel.chapters.isEmpty
        ? novel.chapterCount
        : novel.chapters.length;
    return count == 0
        ? chapterFor(novel.id)
        : chapterFor(novel.id).clamp(0, count - 1);
  }

  String? _novelSnapshot(Novel novel) {
    if (identical(_persistedNovels[novel.id], novel)) return null;
    assert(() {
      _metadataEncodes++;
      return true;
    }());
    final snapshot = jsonEncode(novel.toSnapshot());
    _persistedNovels[novel.id] = novel;
    return snapshot;
  }

  Future<void> _writeNovel(Novel novel, String snapshot) async {
    try {
      await writeLibraryPreference(_prefs, 'novel_meta_${novel.id}', snapshot);
    } catch (_) {
      if (identical(_persistedNovels[novel.id], novel)) {
        _persistedNovels.remove(novel.id);
      }
      rethrow;
    }
  }

  Future<void> rememberNovel(Novel novel) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => rememberNovel(novel));
    }
    if (novel.id <= 0) return Future.value();
    _known[novel.id] = novel;
    final snapshot = _novelSnapshot(novel);
    return snapshot == null
        ? _positionWrites
        : _queuePositionWrite(() => _writeNovel(novel, snapshot));
  }

  Future<ReaderBookmark?> addBookmark({
    required Novel novel,
    required ReadingPosition position,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => addBookmark(novel: novel, position: position),
      );
    }
    final index = chapterForPosition(novel, position);
    if (novel.id <= 0 ||
        index == null ||
        !position.offset.isFinite ||
        position.offset < 0 ||
        !position.fraction.isFinite ||
        position.fraction < 0 ||
        position.fraction > 1 ||
        !position.width.isFinite ||
        !position.fontSize.isFinite ||
        !position.lineHeight.isFinite) {
      return null;
    }
    ReaderBookmark? result;
    await _queuePositionWrite(() async {
      final marks = _bookmarks[novel.id] ?? const <ReaderBookmark>[];
      for (final mark in marks) {
        if (chapterForPosition(novel, mark.position) == index &&
            (mark.position.offset - position.offset).abs() < 12 &&
            (mark.position.fontSize - position.fontSize).abs() < .01 &&
            (mark.position.lineHeight - position.lineHeight).abs() < .01 &&
            (mark.position.width - position.width).abs() < 1) {
          result = mark;
          return;
        }
      }
      final mark = ReaderBookmark(
        id: '${DateTime.now().microsecondsSinceEpoch}-${marks.length}',
        chapterTitle: novel.chapters[index].title,
        position: position,
      );
      final next = [mark, ...marks];
      await _writeBookmarks(novel.id, next);
      _bookmarks[novel.id] = next;
      if (!_disposed) _bookmarkChanges.notifyListeners();
      result = mark;
    });
    return result;
  }

  Future<void> removeBookmark(int novelId, String id) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => removeBookmark(novelId, id));
    }
    return _queuePositionWrite(() async {
      final marks = _bookmarks[novelId];
      if (marks == null || !marks.any((mark) => mark.id == id)) return;
      final next = marks.where((mark) => mark.id != id).toList();
      await _writeBookmarks(novelId, next);
      _bookmarks[novelId] = next;
      if (!_disposed) _bookmarkChanges.notifyListeners();
    });
  }

  Future<void> _writeBookmarks(int novelId, List<ReaderBookmark> marks) async {
    final record = jsonEncode(marks.map((mark) => mark.toJson()).toList());
    await writeLibraryPreference(_prefs, 'reader_bookmarks_$novelId', record);
  }

  Future<void> toggleShelf(int id, {Novel? novel}) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => toggleShelf(id, novel: novel));
    }
    return setShelfMembership(id, !contains(id), novel: novel);
  }

  /// One transactional merge/notification rather than rebuilding the shelf
  /// once per imported cloud/legacy ID. Reading records are never overwritten.
  Future<void> addShelfIds(Iterable<int> values) async {
    final ids = values.where((id) => id > 0 && id <= 0x7fffffff).toSet();
    if (_restoreBarrier case final barrier?) {
      await barrier.future;
      return addShelfIds(ids);
    }
    await _queuePositionWrite(() async {
      final additions = ids.difference(_shelf);
      if (additions.isEmpty) return;
      final shelf = {..._shelf, ...additions};
      final now = DateTime.now().millisecondsSinceEpoch;
      await _commitLibraryRecords({
        'shelf': shelf.map((id) => '$id').toList(),
        for (final id in additions) 'shelf_added_$id': now,
      });
      _shelf.addAll(additions);
      for (final id in additions) {
        _added[id] = now;
        _shelfRevisions[id] = shelfRevision(id) + 1;
      }
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> setShelfMembership(
    int id,
    bool present, {
    Novel? novel,
    int? restoredAddedAt,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setShelfMembership(
          id,
          present,
          novel: novel,
          restoredAddedAt: restoredAddedAt,
        ),
      );
    }
    if (id <= 0) return;
    await _queuePositionWrite(() async {
      final changedMembership = contains(id) != present;
      final shelf = {..._shelf};
      if (present) {
        shelf.add(id);
      } else {
        shelf.remove(id);
      }
      final timestamp = changedMembership && present
          ? restoredAddedAt != null && restoredAddedAt >= 0
                ? restoredAddedAt
                : DateTime.now().millisecondsSinceEpoch
          : _added[id];
      final snapshot = novel == null ? null : _novelSnapshot(novel);
      try {
        await _commitLibraryRecords({
          if (changedMembership) 'shelf': shelf.map((id) => '$id').toList(),
          if (present && timestamp != null) 'shelf_added_$id': timestamp,
          'novel_meta_$id': ?snapshot,
        });
      } catch (_) {
        if (novel != null && identical(_persistedNovels[id], novel)) {
          _persistedNovels.remove(id);
        }
        rethrow;
      }
      _shelf
        ..clear()
        ..addAll(shelf);
      if (present && timestamp != null) _added[id] = timestamp;
      if (novel != null) _known[id] = novel;
      if (changedMembership) _shelfRevisions[id] = shelfRevision(id) + 1;
      if (!_disposed && (changedMembership || novel != null)) notifyListeners();
    });
  }

  Future<void> setChapter(int id, int chapter) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setChapter(id, chapter));
    }
    if (id <= 0 || chapter < 0) return;
    _chapters[id] = chapter;
    final reveal = _hiddenHistory.remove(id);
    final hidden = reveal ? _hiddenHistory.map((id) => '$id').toList() : null;
    notifyListeners();
    _historyChanged();
    await _queuePositionWrite(() async {
      await writeLibraryPreference(_prefs, 'chapter_$id', chapter);
      if (hidden != null) {
        await writeLibraryPreference(_prefs, 'reading_history_hidden', hidden);
      }
    });
  }

  Future<void> savePosition({
    required Novel novel,
    required int chapter,
    required double offset,
    required double maximum,
    required double width,
    bool notify = true,
    int? paragraphIndex,
    double paragraphFraction = 0,
    double textScale = 1,
    String? typeface,
  }) {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => savePosition(
          novel: novel,
          chapter: chapter,
          offset: offset,
          maximum: maximum,
          width: width,
          notify: notify,
          paragraphIndex: paragraphIndex,
          paragraphFraction: paragraphFraction,
          textScale: textScale,
          typeface: typeface,
        ),
      );
    }
    if (novel.id <= 0 ||
        !offset.isFinite ||
        !maximum.isFinite ||
        !width.isFinite ||
        !paragraphFraction.isFinite ||
        !textScale.isFinite ||
        chapter < 0 ||
        chapter >= novel.chapters.length) {
      return Future.value();
    }
    final position = ReadingPosition(
      chapter: chapter,
      chapterId: novel.chapters[chapter].id,
      offset: offset.clamp(0, double.infinity),
      fraction: maximum > 0 ? (offset / maximum).clamp(0, 1) : 0,
      fontSize: fontSize,
      width: width,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      lineHeight: lineHeight,
      paragraphIndex: paragraphIndex != null && paragraphIndex >= 0
          ? paragraphIndex
          : null,
      paragraphFraction: paragraphFraction.clamp(0, 1),
      textScale: textScale.clamp(.5, 5),
      typeface: typeface ?? _appFontId,
    );
    _positions[novel.id] = position;
    final chapterChanged = _chapters[novel.id] != chapter;
    _chapters[novel.id] = chapter;
    _known[novel.id] = novel;
    final reveal = _hiddenHistory.remove(novel.id);
    final hidden = reveal ? _hiddenHistory.map((id) => '$id').toList() : null;
    if (notify) notifyListeners();
    _historyChanged();
    final snapshot = _novelSnapshot(novel);
    final record = jsonEncode(position.toJson());
    return _queuePositionWrite(() async {
      if (chapterChanged) {
        await writeLibraryPreference(_prefs, 'chapter_${novel.id}', chapter);
      }
      await writeLibraryPreference(
        _prefs,
        'reading_position_${novel.id}',
        record,
      );
      if (snapshot != null) await _writeNovel(novel, snapshot);
      if (hidden != null) {
        await writeLibraryPreference(_prefs, 'reading_history_hidden', hidden);
      }
    });
  }

  Future<void> setTheme(ThemeMode mode) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setTheme(mode));
    }
    if (_theme == mode) {
      if (_prefs.get('theme') != null && _prefs.get('theme') != mode.name) {
        await writeLibraryPreference(_prefs, 'theme', mode.name);
      }
      return;
    }
    _theme = mode;
    _application.notifyListeners();
    _appearance.notifyListeners();
    _settings.notifyListeners();
    notifyListeners();
    await writeLibraryPreference(_prefs, 'theme', mode.name);
  }

  /// 从持久化恢复字体选择与导入字体列表；兼容旧版 appTypeface。
  void _loadFontState() {
    final rawId = _prefs.getString('appFontId');
    if (rawId != null && rawId.isNotEmpty) {
      _appFontId = rawId;
    } else {
      // 旧版迁移：appTypeface 存的是 'system' / 'sourceHanSerif'。
      // 落盘迁移结果，下次不再依赖旧 key。
      _appFontId = AppTypeface.fromRecord(_prefs.get('appTypeface')).name ==
              'sourceHanSerif'
          ? appFontSourceHanSerif.id
          : appFontSystem.id;
      unawaited(_persistMigratedFontId());
    }
    _importedFonts.clear();
    final rawList = _prefs.getString('importedFonts');
    if (rawList != null && rawList.isNotEmpty) {
      try {
        final list = jsonDecode(rawList);
        if (list is List) {
          for (final item in list) {
            if (item is Map<String, Object?>) {
              final entry = AppFontEntry.fromJson(item);
              if (entry.id.isNotEmpty &&
                  entry.source == AppFontSource.imported &&
                  entry.family != null) {
                _importedFonts.add(entry);
              }
            }
          }
        }
      } catch (_) {}
    }
    // 选择的导入字体若已不在列表中，回退到系统字体。
    if (_appFontId != appFontSystem.id &&
        _appFontId != appFontSourceHanSerif.id &&
        !_importedFonts.any((f) => f.id == _appFontId)) {
      _appFontId = appFontSystem.id;
    }
  }

  /// 后台落盘迁移后的字体 ID；异常内部消化，不污染未处理错误通道。
  Future<void> _persistMigratedFontId() async {
    try {
      await _prefs.setString('appFontId', _appFontId);
    } catch (_) {}
  }

  Future<void> _persistFontState() async {
    await _prefs.setString('appFontId', _appFontId);
    await _prefs.setString(
      'importedFonts',
      jsonEncode(_importedFonts.map((f) => f.toJson()).toList()),
    );
  }

  /// 持久化导入字体列表（不进备份日志，文件本身不在备份范围内）。

  /// 用 FontLoader 注册单个导入字体；已加载或正在加载的复用同一任务。
  /// 返回 true 表示可用。
  Future<bool> _loadImportedEntry(AppFontEntry entry) {
    final family = entry.family;
    final path = entry.filePath;
    if (family == null || path == null) return Future.value(false);
    if (_loadedFontFamilies.contains(family)) return Future.value(true);
    final inflight = _fontLoadInflight[family];
    if (inflight != null) return inflight;
    late final Future<bool> task;
    task = _doLoadImportedFont(family, path).then((ok) {
      // 仅当仍是当前任务时才清理映射（防御性，避免误删更新的任务）。
      if (identical(_fontLoadInflight[family], task)) {
        _fontLoadInflight.remove(family);
      }
      if (ok) _loadedFontFamilies.add(family);
      return ok;
    }, onError: (Object _) {
      if (identical(_fontLoadInflight[family], task)) {
        _fontLoadInflight.remove(family);
      }
      return false;
    });
    _fontLoadInflight[family] = task;
    return task;
  }

  Future<bool> _doLoadImportedFont(String family, String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 确保当前选中的导入字体已通过 FontLoader 加载（启动时调用）。
  /// 加载失败时回退到系统字体。
  Future<void> ensureFontLoaded() async {
    final entry = currentFont;
    if (entry.source != AppFontSource.imported) return;
    try {
      if (!await _loadImportedEntry(entry)) throw StateError('字体不可用');
    } catch (_) {
      _appFontId = appFontSystem.id;
      try {
        await _persistFontState();
      } catch (_) {}
      notifyListeners();
    }
  }

  /// 预加载全部已导入字体（供字体选择器预览用）；失败的跳过。
  /// 遍历快照，避免与导入/删除并发修改冲突。
  Future<void> preloadImportedFonts() async {
    final snapshot = List.of(_importedFonts);
    for (final entry in snapshot) {
      try {
        await _loadImportedEntry(entry);
      } catch (_) {}
    }
  }

  /// 切换应用字体；导入字体会先确保加载成功。
  Future<void> setAppFont(String id) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setAppFont(id));
    }
    await _queuePositionWrite(() async {
      if (_appFontId == id) return;
      final previous = _appFontId;
      _appFontId = id;
      if (currentFont.source == AppFontSource.imported) {
        try {
          await ensureFontLoaded();
        } catch (_) {
          _appFontId = previous;
          return;
        }
        // ensureFontLoaded 失败时已将 _appFontId 置为 system，
        // 下面继续走持久化与通知，保证回退生效。
      }
      try {
        await _persistFontState();
      } catch (_) {
        _appFontId = previous;
        rethrow;
      }
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
        notifyListeners();
      }
    });
  }

  /// 注册从手机导入的字体文件（文件已由原生层复制到私有目录）。
  /// 返回新字体的稳定 ID。
  Future<String> registerImportedFont(String filePath, String displayName) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('字体文件不存在');
    final id =
        'imported_${DateTime.now().millisecondsSinceEpoch}_${filePath.hashCode.abs()}';
    final entry = AppFontEntry(
      id: id,
      displayName: displayName.isEmpty ? '导入字体' : displayName,
      family: 'user_font_$id',
      source: AppFontSource.imported,
      filePath: filePath,
    );
    // 先加载验证字体可用；任何失败都删除已复制的文件，不留孤立文件。
    bool loadedOk = false;
    try {
      loadedOk = await _loadImportedEntry(entry);
    } catch (_) {
      loadedOk = false;
    }
    if (!loadedOk) {
      try {
        await file.delete();
      } catch (_) {}
      // 加载失败的 family 不应留在去重集合中，允许重试。
      _loadedFontFamilies.remove(entry.family);
      _fontLoadInflight.remove(entry.family);
      throw StateError('字体文件无效或已损坏');
    }
    _importedFonts.add(entry);
    await _persistFontState();
    notifyListeners();
    return id;
  }

  /// 删除导入的字体（含文件）；若正选中则回退到系统字体。
  Future<void> removeImportedFont(String id) async {
    final index = _importedFonts.indexWhere((f) => f.id == id);
    if (index < 0) return;
    final entry = _importedFonts[index];
    _importedFonts.removeAt(index);
    _loadedFontFamilies.remove(entry.family);
    _fontLoadInflight.remove(entry.family);
    try {
      final path = entry.filePath;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
    if (_appFontId == id) _appFontId = appFontSystem.id;
    // 持久化失败也发出通知（内存已是最新状态，调用方会提示重试）。
    try {
      await _persistFontState();
    } finally {
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
        notifyListeners();
      }
    }
  }

  /// 兼容旧调用：枚举转字体 ID。
  Future<void> setAppTypeface(AppTypeface value) => setAppFont(
        value == AppTypeface.sourceHanSerif
            ? appFontSourceHanSerif.id
            : appFontSystem.id,
      );

  Future<void> setFontSize(double size, {bool persist = true}) =>
      setTypography(fontSize: size, persist: persist);

  Future<void> setLineHeight(double value, {bool persist = true}) =>
      setTypography(lineHeight: value, persist: persist);

  Future<void> setTypography({
    double? fontSize,
    double? lineHeight,
    bool persist = true,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setTypography(
          fontSize: fontSize,
          lineHeight: lineHeight,
          persist: persist,
        ),
      );
    }
    final font = fontSize?.isFinite == true
        ? fontSize!.clamp(15.0, 27.0)
        : _fontSize;
    final spacing = lineHeight?.isFinite == true
        ? lineHeight!.clamp(1.3, 2.2)
        : _lineHeight;
    if (font != _fontSize || spacing != _lineHeight) {
      _fontSize = font;
      _lineHeight = spacing;
      _readerSettings.notifyListeners();
      _settings.notifyListeners();
    }
    if (persist) {
      if (fontSize?.isFinite == true) {
        await writeLibraryPreference(_prefs, 'readerFontSize', font);
      }
      if (lineHeight?.isFinite == true) {
        await writeLibraryPreference(_prefs, 'readerLineHeight', spacing);
      }
    }
  }

  Future<void> setPerformance(PerformancePreferences value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setPerformance(value));
    }
    await _queuePositionWrite(() async {
      if (_performance == value) return;
      // Commit all switches together. A failed disk write must not leave the
      // visible mode different from the one restored on the next launch.
      await _commitLibraryRecords(value.toRecords());
      _performance = value;
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _settings.notifyListeners();
      }
    });
  }

  Future<void> setReduceMotion(bool value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setReduceMotion(value));
    }
    if (_reduceMotion == value) {
      if (_prefs.get('reduceMotion') != null &&
          _prefs.get('reduceMotion') != value) {
        await writeLibraryPreference(_prefs, 'reduceMotion', value);
      }
      return;
    }
    _reduceMotion = value;
    _application.notifyListeners();
    _appearance.notifyListeners();
    _settings.notifyListeners();
    notifyListeners();
    await writeLibraryPreference(_prefs, 'reduceMotion', value);
  }

  Future<void> setGlassBlur(double value, {bool persist = true}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setGlassBlur(value, persist: persist));
    }
    if (!value.isFinite) return;
    final next = value.clamp(0.0, 24.0);
    if (_glassBlur != next) {
      _glassBlur = next;
      _glassChanges.notifyListeners();
      _appearance.notifyListeners();
      _settings.notifyListeners();
      notifyListeners();
    }
    if (persist) {
      await writeLibraryPreference(_prefs, 'glassBlur', next);
    }
  }

  Future<void> setGlassOpacity(double value, {bool persist = true}) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => setGlassOpacity(value, persist: persist),
      );
    }
    if (!value.isFinite) return;
    final next = value.clamp(0.0, 1.0);
    if (_glassOpacity != next) {
      _glassOpacity = next;
      _glassChanges.notifyListeners();
      _appearance.notifyListeners();
      _settings.notifyListeners();
      notifyListeners();
    }
    if (persist) {
      await writeLibraryPreference(_prefs, 'glassOpacity', next);
    }
  }

  Map<String, Object> _backupRecords() => {
    'shelf': _shelf.map((id) => '$id').toList(),
    'reading_history_hidden': _hiddenHistory.map((id) => '$id').toList(),
    'recentSearches': _recentSearches,
    'theme': _theme.name,
    'readerFontSize': _fontSize,
    'readerLineHeight': _lineHeight,
    'reduceMotion': _reduceMotion,
    'appFontId': _appFontId,
    ..._performance.toRecords(),
    'glassBlur': _glassBlur,
    'glassOpacity': _glassOpacity,
    'readerKeepScreenOn': _keepScreenOn,
    'shelfSort': _shelfSort,
    'shelfFilter': _shelfFilter,
    for (final entry in _added.entries) 'shelf_added_${entry.key}': entry.value,
    for (final entry in _known.entries)
      'novel_meta_${entry.key}': jsonEncode(entry.value.toSnapshot()),
    for (final entry in _chapters.entries) 'chapter_${entry.key}': entry.value,
    for (final entry in _positions.entries)
      'reading_position_${entry.key}': jsonEncode(entry.value.toJson()),
    for (final entry in _bookmarks.entries)
      'reader_bookmarks_${entry.key}': jsonEncode(
        entry.value.map((mark) => mark.toJson()).toList(),
      ),
    // 标签定义与归属：重装迁移时靠它恢复，平时备份也一并带上。
    ...TagStore.shared.exportTagRecords(),
  };

  Future<LibraryBackup> createBackup() async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => createBackup());
    }
    late LibraryBackup backup;
    await _queuePositionWrite(() async {
      backup = await LibraryBackup.fromRecords(_backupRecords());
    });
    return backup;
  }

  /// Merge, do not replace: current newer positions and metadata win. Memory is
  /// published only after all keys commit, with a rollback journal across kills.
  Future<void> restoreBackup(
    LibraryBackup backup, {
    bool importPreferences = false,
  }) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then(
        (_) => restoreBackup(backup, importPreferences: importPreferences),
      );
    }
    final barrier = Completer<void>();
    _restoreBarrier = barrier;
    try {
      await _queuePositionWrite(() async {
        final records = backup.records;
        final shelf = {
          ..._shelf,
          ...(records['shelf'] as List<String>? ?? const []).map(int.parse),
        };
        final added = {..._added};
        final known = {..._known};
        final chapters = {..._chapters};
        final positions = {..._positions};
        final marks = <int, List<ReaderBookmark>>{
          for (final entry in _bookmarks.entries) entry.key: [...entry.value],
        };
        final hidden = {..._hiddenHistory};
        final changed = <String, Object>{};
        final oldRead = {..._chapters.keys, ..._positions.keys};
        for (final entry in records.entries) {
          final key = entry.key;
          if (key.startsWith('novel_meta_')) {
            final id = int.parse(key.substring('novel_meta_'.length));
            if (!known.containsKey(id)) {
              known[id] = Novel.fromSnapshot(jsonDecode(entry.value as String));
              changed[key] = entry.value;
            }
          } else if (key.startsWith('shelf_added_')) {
            final id = int.parse(key.substring('shelf_added_'.length));
            if (!added.containsKey(id)) {
              added[id] = entry.value as int;
              changed[key] = entry.value;
            }
          } else if (key.startsWith('chapter_')) {
            final id = int.parse(key.substring('chapter_'.length));
            if (!chapters.containsKey(id) && !positions.containsKey(id)) {
              chapters[id] = entry.value as int;
              changed[key] = entry.value;
            }
          } else if (key.startsWith('reading_position_')) {
            final id = int.parse(key.substring('reading_position_'.length));
            final incoming = ReadingPosition.fromJson(
              jsonDecode(entry.value as String),
            );
            if (positions[id] == null ||
                positions[id]!.updatedAt < incoming.updatedAt) {
              positions[id] = incoming;
              chapters[id] = incoming.chapter;
              changed[key] = jsonEncode(incoming.toJson());
              changed['chapter_$id'] = incoming.chapter;
            }
          } else if (key.startsWith('reader_bookmarks_')) {
            final id = int.parse(key.substring('reader_bookmarks_'.length));
            final current = marks.putIfAbsent(id, () => []);
            final fingerprints = current.map(_bookmarkFingerprint).toSet();
            final ids = current.map((mark) => mark.id).toSet();
            for (final raw in jsonDecode(entry.value as String) as List) {
              var mark = ReaderBookmark.fromJson(
                Map<String, dynamic>.from(raw),
              );
              if (!fingerprints.add(_bookmarkFingerprint(mark))) continue;
              var candidate = mark.id;
              for (var suffix = 1; ids.contains(candidate); suffix++) {
                candidate = 'import-${mark.position.updatedAt}-$suffix';
              }
              ids.add(candidate);
              if (candidate != mark.id) {
                mark = ReaderBookmark(
                  id: candidate,
                  chapterTitle: mark.chapterTitle,
                  position: mark.position,
                );
              }
              current.add(mark);
            }
            if (current.length > 1000) {
              throw const FormatException('合并后单本书超过 1000 个书签，请先整理书签');
            }
            current.sort(
              (a, b) => b.position.updatedAt.compareTo(a.position.updatedAt),
            );
            changed[key] = jsonEncode(
              current.map((mark) => mark.toJson()).toList(),
            );
          }
        }
        for (final id in shelf) {
          added.putIfAbsent(id, () => backup.createdAt);
          if (!_added.containsKey(id)) changed['shelf_added_$id'] = added[id]!;
        }
        for (final id
            in (records['reading_history_hidden'] as List<String>? ?? const [])
                .map(int.parse)) {
          if (!oldRead.contains(id) &&
              (positions.containsKey(id) || chapters.containsKey(id))) {
            hidden.add(id);
          }
        }
        final seen = <String>{};
        final searches = <String>[
          ..._recentSearches,
          ...(records['recentSearches'] as List<String>? ?? const []),
        ].where((term) => seen.add(term.toLowerCase())).take(12).toList();
        changed['shelf'] = shelf.map((id) => '$id').toList();
        changed['reading_history_hidden'] = hidden.map((id) => '$id').toList();
        changed['recentSearches'] = searches;
        if (importPreferences) {
          for (final key in backupPreferenceKeys) {
            if (records[key] case final value?) changed[key] = value;
          }
        }
        await _commitLibraryRecords(changed);
        // 标签是独立存储，合并语义与书架一致（只增不减）。
        final tagRecords = <String, Object>{};
        for (final key in const ['tag_defs', 'tag_map']) {
          if (records[key] case final String value) tagRecords[key] = value;
        }
        if (tagRecords.isNotEmpty) {
          await TagStore.shared.importTagRecords(tagRecords);
        }
        final oldShelf = {..._shelf};
        _shelf
          ..clear()
          ..addAll(shelf);
        for (final id in {...oldShelf, ...shelf}) {
          if (oldShelf.contains(id) != shelf.contains(id)) {
            _shelfRevisions[id] = shelfRevision(id) + 1;
          }
        }
        _added
          ..clear()
          ..addAll(added);
        _known
          ..clear()
          ..addAll(known);
        _persistedNovels
          ..clear()
          ..addAll(known);
        _chapters
          ..clear()
          ..addAll(chapters);
        _positions
          ..clear()
          ..addAll(positions);
        _bookmarks
          ..clear()
          ..addAll(marks);
        _hiddenHistory
          ..clear()
          ..addAll(hidden);
        _recentSearches = searches;
        if (importPreferences) {
          if (records['theme'] case final String value) {
            _theme = ThemeMode.values.firstWhere((mode) => mode.name == value);
          }
          if (records['readerFontSize'] case final num value) {
            _fontSize = value.toDouble();
          }
          if (records['readerLineHeight'] case final num value) {
            _lineHeight = value.toDouble();
          }
          if (records['glassBlur'] case final num value) {
            _glassBlur = value.toDouble();
          }
          if (records['glassOpacity'] case final num value) {
            _glassOpacity = value.toDouble();
          }
          if (records['reduceMotion'] case final bool value) {
            _reduceMotion = value;
          }
          if (records['appFontId'] case final String value) {
            if (value == appFontSystem.id ||
                value == appFontSourceHanSerif.id) {
              _appFontId = value;
            }
          } else if (records['appTypeface'] case final String value) {
            // 旧版备份兼容。
            _appFontId = value == 'sourceHanSerif'
                ? appFontSourceHanSerif.id
                : appFontSystem.id;
          }
          _performance = PerformancePreferences.fromRecords({
            ..._performance.toRecords(),
            for (final key in _performance.toRecords().keys)
              if (records.containsKey(key)) key: records[key],
          });
          if (records['readerKeepScreenOn'] case final bool value) {
            _keepScreenOn = value;
          }
          if (records['shelfSort'] case final String value) _shelfSort = value;
          if (records['shelfFilter'] case final String value) {
            _shelfFilter = value;
          }
        }
        if (!_disposed) {
          _historyChanged();
          _bookmarkChanges.notifyListeners();
          _searchChanges.notifyListeners();
          _shelfViewChanges.notifyListeners();
          if (importPreferences) {
            _application.notifyListeners();
            _appearance.notifyListeners();
            _glassChanges.notifyListeners();
            _readerSettings.notifyListeners();
            _readerBehaviorChanges.notifyListeners();
            _settings.notifyListeners();
          }
          notifyListeners();
        }
      });
    } finally {
      _restoreBarrier = null;
      barrier.complete();
    }
  }

  static String _bookmarkFingerprint(ReaderBookmark bookmark) {
    final position = {...bookmark.position.toJson()}..remove('updatedAt');
    return jsonEncode(position);
  }

  Future<void> _commitLibraryRecords(Map<String, Object> changes) async {
    changes.removeWhere(
      (key, value) => jsonEncode(_prefs.get(key)) == jsonEncode(value),
    );
    if (changes.isEmpty) return;
    final journal = jsonEncode({
      for (final key in changes.keys) key: _prefs.get(key),
    });
    if (utf8.encode(journal).length > LibraryBackup.maxBytes * 2) {
      throw const FormatException('本地恢复日志过大');
    }
    try {
      await writeLibraryPreference(_prefs, restoreJournalKey, journal);
      for (final entry in changes.entries) {
        await writeLibraryPreference(_prefs, entry.key, entry.value);
      }
      await writeLibraryPreference(_prefs, restoreJournalKey, null);
    } catch (_) {
      if (_prefs.get(restoreJournalKey) != null) {
        await recoverLibraryRestore(_prefs);
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _appearance.dispose();
    _application.dispose();
    _glassChanges.dispose();
    _readerSettings.dispose();
    _settings.dispose();
    _history.dispose();
    _bookmarkChanges.dispose();
    _searchChanges.dispose();
    _shelfViewChanges.dispose();
    _readerBehaviorChanges.dispose();
    super.dispose();
  }
}
