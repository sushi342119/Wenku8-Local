import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'library_backup.dart';
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
    _appTypeface = AppTypeface.fromRecord(_prefs.get('appTypeface'));
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
  AppTypeface _appTypeface = AppTypeface.system;
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
  AppTypeface get appTypeface => _appTypeface;
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
      typeface: AppTypeface.fromRecord(typeface ?? appTypeface.name).name,
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

  Future<void> setAppTypeface(AppTypeface value) async {
    if (_restoreBarrier case final barrier?) {
      return barrier.future.then((_) => setAppTypeface(value));
    }
    await _queuePositionWrite(() async {
      if (_appTypeface == value) return;
      await _commitLibraryRecords({'appTypeface': value.name});
      _appTypeface = value;
      if (!_disposed) {
        _application.notifyListeners();
        _appearance.notifyListeners();
        _readerSettings.notifyListeners();
        _settings.notifyListeners();
        notifyListeners();
      }
    });
  }

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
    'appTypeface': _appTypeface.name,
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
          if (records['appTypeface'] case final String value) {
            _appTypeface = AppTypeface.fromRecord(value);
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
