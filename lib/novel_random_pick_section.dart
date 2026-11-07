import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'archive_random_pick_card.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'library_filter.dart';
import 'random_pick_weights.dart';
import 'ui_preferences.dart';

/// 首页随机抽阅的标签筛选包装组件。
/// 管理标签筛选，以及按书籍 ID 持久化的次数和上次抽取结果。
class NovelRandomPickSection extends StatefulWidget {
  const NovelRandomPickSection({
    super.key,
    required this.books,
    required this.onOpenDetail,
    this.matchMode = TagMatchMode.any,
    this.pace = RandomPickPace.quick,
    this.carouselBuilder,
  });

  final List<Novel> books;
  final ValueChanged<Novel> onOpenDetail;

  /// Shared with the shelf; OR stays the default like the old random pick.
  final TagMatchMode matchMode;

  /// 快速 900ms by default; 仪式 2400ms is optional.
  final RandomPickPace pace;

  /// Places the history action beside the discovery carousel's pager while
  /// keeping draw-count loading, writes and empty filters in this state.
  final Widget Function(Widget resetButton)? carouselBuilder;

  @override
  State<NovelRandomPickSection> createState() => _NovelRandomPickSectionState();
}

class _NovelRandomPickSectionState extends State<NovelRandomPickSection> {
  static const _drawCountsKey = 'random_pick_draw_counts_v1';
  static const _lastPickedKey = 'random_pick_last_id_v1';

  ColorScheme get _scheme => Theme.of(context).colorScheme;
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _muted => _scheme.onSurfaceVariant;
  Color get _border => _dark
      ? _scheme.outlineVariant
      : Color.lerp(_scheme.outlineVariant, _scheme.primary, .14)!;
  Color get _accent => _scheme.primary;

  /// Same selection as the shelf and the carousel (LibraryFilter.shared).
  Set<String> get _selectedTagIds => LibraryFilter.shared.tagIds;
  final TagStore _tagStore = TagStore.shared;
  final Map<int, int> _drawCounts = {};
  SharedPreferences? _preferences;
  bool _countsLoaded = false;
  bool _countsWritable = true;
  bool _lastIdWritable = true;
  int? _lastPickedId;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _tagStore.addListener(_onTagsChanged);
    LibraryFilter.shared.addListener(_onFilterChanged);
    unawaited(_loadDrawCounts());
  }

  @override
  void dispose() {
    _tagStore.removeListener(_onTagsChanged);
    LibraryFilter.shared.removeListener(_onFilterChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDrawCounts() async {
    final counts = <int, int>{};
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final last = preferences.get(_lastPickedKey);
      if (last == null || last is int) {
        _lastPickedId = last as int?;
      } else {
        // 上次 ID 损坏不影响恢复次数，也不静默覆盖原始值。
        _lastIdWritable = false;
      }
      final raw = preferences.get(_drawCountsKey);
      final decoded = raw is String ? jsonDecode(raw) : null;
      if (raw != null && decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid draw counts');
      }
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          final id = int.tryParse(entry.key);
          final count = entry.value;
          if (id != null && count is int && count > 0) {
            counts[id] = count;
          } else {
            _countsWritable = false;
          }
        }
      }
    } catch (_) {
      _countsWritable = false;
    }
    if (!mounted) return;
    setState(() {
      // 当前列表可能只是分页或筛选结果，不以其缺失项判断书籍已删除。
      _drawCounts.addAll(counts);
      _countsLoaded = true;
    });
  }

  Future<bool> _persistDrawCounts() {
    if (!_countsWritable) return Future.value(false);
    // 保存快照并串行写入，防止较早的抽取覆盖后来的重置。
    final encoded = jsonEncode(
      _drawCounts.map((id, count) => MapEntry('$id', count)),
    );
    final lastPickedId = _lastPickedId;
    final write = _pendingWrite.then((_) async {
      try {
        final preferences = _preferences ??=
            await SharedPreferences.getInstance();
        if (!await preferences.setString(_drawCountsKey, encoded)) return false;
        if (!_lastIdWritable) return false;
        // 两个键按同一快照串行保存；部分失败不丢弃已保存的次数。
        return lastPickedId == null
            ? await preferences.remove(_lastPickedKey)
            : await preferences.setInt(_lastPickedKey, lastPickedId);
      } catch (_) {
        return false;
      }
    });
    _pendingWrite = write.then((_) {});
    return write;
  }

  void _recordPick(Novel book) {
    setState(() {
      _drawCounts[book.id] = (_drawCounts[book.id] ?? 0) + 1;
      _lastPickedId = book.id;
    });
    unawaited(_persistDrawCounts());
  }

  Future<void> _resetDrawCounts() async {
    setState(() {
      _drawCounts.clear();
      _lastPickedId = null;
    });
    final saved = await _persistDrawCounts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '已重置抽取记录' : '已重置抽取记录，但保存失败')),
    );
  }

  void _onTagsChanged() {
    LibraryFilter.shared.prune(_tagStore);
    if (mounted) setState(() {});
  }

  void _toggleTag(String tagId, bool selected) {
    if (_selectedTagIds.contains(tagId) != selected) {
      LibraryFilter.shared.toggleTag(tagId);
    }
  }

  void _clearFilter() => LibraryFilter.shared.setSingleTag(null);

  List<Novel> _filterBooks() {
    final seen = <int>{};
    return widget.books
        .where((book) {
          return seen.add(book.id) &&
              (_selectedTagIds.isEmpty ||
                  LibraryFilter.shared.matchesTags(
                    book.id,
                    widget.matchMode,
                    store: _tagStore,
                  ));
        })
        .toList(growable: false);
  }

  Widget _buildFilterHeader(int candidateCount) {
    final tags = _tagStore.tags;
    final resetButton = TextButton(
      onPressed: _countsLoaded ? _resetDrawCounts : null,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        minimumSize: const Size(0, 32),
      ),
      child: const Text('重置抽取记录', style: TextStyle(fontSize: 12)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.carouselBuilder case final builder?)
          builder(resetButton)
        else
          Align(alignment: Alignment.centerRight, child: resetButton),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _selectedTagIds.isEmpty,
                  onSelected: (_) => _clearFilter(),
                  backgroundColor: _dark
                      ? Color.lerp(
                          _scheme.surface,
                          _scheme.surfaceContainerHigh,
                          .65,
                        )!
                      : _scheme.surface,
                  selectedColor: Color.lerp(
                    _scheme.surface,
                    _accent,
                    _dark ? .24 : .12,
                  )!,
                  checkmarkColor: _accent,
                  surfaceTintColor: Colors.transparent,
                  labelStyle: TextStyle(
                    color: _selectedTagIds.isEmpty ? _accent : _muted,
                    fontSize: 13,
                    fontWeight: _selectedTagIds.isEmpty
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                  side: BorderSide(
                    color: _selectedTagIds.isEmpty
                        ? _accent.withValues(alpha: _dark ? .50 : .34)
                        : _border,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                const SizedBox(width: 8),
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tag.name),
                      selected: _selectedTagIds.contains(tag.id),
                      onSelected: (selected) => _toggleTag(tag.id, selected),
                      backgroundColor: _dark
                          ? Color.lerp(
                              _scheme.surface,
                              _scheme.surfaceContainerHigh,
                              .65,
                            )!
                          : _scheme.surface,
                      selectedColor: Color.lerp(
                        _scheme.surface,
                        _accent,
                        _dark ? .24 : .12,
                      )!,
                      checkmarkColor: _accent,
                      surfaceTintColor: Colors.transparent,
                      labelStyle: TextStyle(
                        color: _selectedTagIds.contains(tag.id)
                            ? _accent
                            : _muted,
                        fontSize: 13,
                        fontWeight: _selectedTagIds.contains(tag.id)
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      side: BorderSide(
                        color: _selectedTagIds.contains(tag.id)
                            ? _accent.withValues(alpha: _dark ? .50 : .34)
                            : _border,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (_selectedTagIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.matchMode == TagMatchMode.all
                      ? '符合全部所选标签 · 共 $candidateCount 本'
                      : '符合任一所选标签 · 共 $candidateCount 本',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
              ),
              TextButton(
                onPressed: _clearFilter,
                style: TextButton.styleFrom(
                  foregroundColor: _accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                child: const Text('清除筛选', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(
            '没有符合所选标签的书籍',
            style: TextStyle(fontSize: 15, color: _muted),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _clearFilter,
            style: TextButton.styleFrom(foregroundColor: _accent),
            child: const Text('清除筛选'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _filterBooks();
    final weights = buildRandomPickWeights(
      candidates.map((book) => book.id).toList(growable: false),
      _drawCounts,
      lastPickedId: _lastPickedId,
    );
    final hasFilter = _selectedTagIds.isNotEmpty;

    Widget? emptyState;
    if (hasFilter && candidates.isEmpty) {
      emptyState = _buildEmptyState();
    } else if (widget.books.isEmpty) {
      // 书库为空时显示明确提示
      emptyState = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('书库暂无书籍', style: TextStyle(fontSize: 15, color: _muted)),
      );
    }

    // 等待恢复完成再接收点击，确保重启后的第一次抽取也使用历史权重。
    return AbsorbPointer(
      absorbing: !_countsLoaded,
      child: ArchiveRandomPickCard<Novel>(
        books: candidates,
        titleOf: (book) => book.title,
        authorOf: (book) => book.author,
        identityOf: (book) => book.id,
        weightOf: (book) => weights[book.id] ?? 0,
        resultLabelOf: (book) =>
            (_drawCounts[book.id] ?? 0) == 0 ? '第一次抽到' : '又遇见这本书',
        onPicked: _recordPick,
        onOpenDetail: widget.onOpenDetail,
        totalDuration: widget.pace.duration,
        filterHeader: _buildFilterHeader(candidates.length),
        emptyState: emptyState,
      ),
    );
  }
}
