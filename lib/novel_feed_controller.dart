import 'dart:async';

import 'package:flutter/foundation.dart';

import 'catalog.dart';

/// Owns page cursors, stale-result isolation and explicit recovery. A failed
/// page never advances the cursor or loops automatically against the service.
class NovelFeedController extends ChangeNotifier {
  NovelFeedController(
    this.repository, {
    this.search = false,
    this.initialItems = 0,
  }) : assert(initialItems >= 0);
  final NovelRepository repository;
  final bool search;

  /// Discovery can warm a useful list below the ten featured files. Service
  /// page sizes/cursors stay unchanged; search remains one page at a time.
  final int initialItems;
  List<Novel> _items = const [];
  NovelSort sort = NovelSort.lastUpdate;
  String query = '';
  int page = 0;
  int? totalItems;
  bool hasMore = true;
  bool loading = false;
  Object? error;
  bool refreshFailed = false;
  int _generation = 0;
  // Accepted data batches, not request attempts. Failed/stale requests must not
  // restart presentation, and appended pages must leave the old rows alone.
  int _resultRevision = 0;
  int _resultStartIndex = 0;
  bool refreshing = false;
  bool _disposed = false;
  Timer? _searchDelay;

  List<Novel> get items => _items;
  int get resultRevision => _resultRevision;
  int get resultStartIndex => _resultStartIndex;

  Future<void> refresh() {
    _searchDelay?.cancel();
    _searchDelay = null;
    return _load(replace: true, force: true);
  }

  Future<void> loadInitial() => _load(replace: true);
  Future<void> loadMore() async {
    if (loading || !hasMore || error != null) return;
    await _load(replace: false);
  }

  Future<void> retry() => loading
      ? Future.value()
      : _load(replace: page == 0 || refreshFailed, force: true);

  Future<void> selectSort(NovelSort value) async {
    if (sort == value) return;
    sort = value;
    _reset();
    await _load(replace: true);
  }

  Future<void> searchFor(String value) async {
    if (_disposed) return;
    final term = value.trim();
    if (query == term &&
        ((loading && _searchDelay == null) || (page > 0 && error == null))) {
      return;
    }
    _searchDelay?.cancel();
    _searchDelay = null;
    query = term;
    _reset();
    await _load(replace: true);
  }

  /// Invalidate old results immediately, but request only the final input after
  /// a short quiet period. Pagination cannot start during the debounce window.
  void scheduleSearch(
    String value, {
    Duration delay = const Duration(milliseconds: 280),
  }) {
    if (_disposed || !search) return;
    final term = value.trim();
    if (query == term &&
        (_searchDelay != null || loading || (page > 0 && error == null))) {
      return;
    }
    _searchDelay?.cancel();
    query = term;
    _reset();
    loading = true;
    notifyListeners();
    _searchDelay = Timer(delay, () {
      _searchDelay = null;
      unawaited(_load(replace: true));
    });
  }

  /// A closed search keeps its last result/query, without launching a request
  /// which the user can no longer see. Reopening can explicitly resume it.
  void cancelScheduledSearch() {
    if (_searchDelay == null) return;
    _searchDelay!.cancel();
    _searchDelay = null;
    loading = false;
    refreshing = false;
    notifyListeners();
  }

  void _reset() {
    _generation++;
    _items = const [];
    page = 0;
    totalItems = null;
    hasMore = true;
    error = null;
    refreshFailed = false;
    loading = false;
    refreshing = false;
  }

  Future<void> _load({required bool replace, bool force = false}) async {
    if (_disposed) return;
    if (!replace && loading) return;
    final generation = replace ? ++_generation : _generation;
    var requestedPage = replace ? 1 : page + 1;
    var replacing = replace;
    final requestedSort = sort;
    final requestedQuery = query;
    final hadItems = _items.isNotEmpty;
    loading = true;
    refreshing = replace && _items.isNotEmpty;
    error = null;
    refreshFailed = false;
    notifyListeners();
    try {
      while (true) {
        final result = search
            ? await repository.searchPage(
                requestedQuery,
                page: requestedPage,
                refresh: force,
              )
            : await repository.browse(
                sort: requestedSort,
                page: requestedPage,
                refresh: force,
              );
        if (_disposed || generation != _generation) return;
        if (result.page != requestedPage) {
          throw const FormatException('分页游标不匹配');
        }
        final oldCount = _items.length;
        final merged = <int, Novel>{
          if (!replacing)
            for (final item in _items) item.id: item,
          for (final item in result.items) item.id: item,
        };
        _resultStartIndex = replacing ? 0 : oldCount;
        _items = List.unmodifiable(merged.values);
        if (_resultStartIndex < _items.length) _resultRevision++;
        page = requestedPage;
        hasMore = result.hasMore;
        totalItems = result.totalItems;
        replacing = false;
        refreshing = false;
        // At most the first three ordinary API pages, sequentially. Publish
        // page one immediately, stop on duplicates/errors/end or a new sort.
        if (search ||
            _items.length >= initialItems ||
            page >= 3 ||
            !hasMore ||
            result.items.isEmpty ||
            _items.length <= _resultStartIndex) {
          break;
        }
        notifyListeners();
        if (_disposed || generation != _generation) return;
        requestedPage = page + 1;
      }
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      error = failure;
      refreshFailed = replacing && hadItems;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        refreshing = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchDelay?.cancel();
    _generation++;
    super.dispose();
  }
}
