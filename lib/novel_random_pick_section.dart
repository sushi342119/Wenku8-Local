import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'archive_random_pick_card.dart';
import 'book_tags.dart';
import 'catalog.dart';

/// 首页随机抽阅的标签筛选包装组件。
/// 管理标签筛选及按书籍 ID 持久化的抽取次数。
class NovelRandomPickSection extends StatefulWidget {
  const NovelRandomPickSection({
    super.key,
    required this.books,
    required this.onOpenDetail,
  });

  final List<Novel> books;
  final ValueChanged<Novel> onOpenDetail;

  @override
  State<NovelRandomPickSection> createState() => _NovelRandomPickSectionState();
}

class _NovelRandomPickSectionState extends State<NovelRandomPickSection> {
  static const _drawCountsKey = 'random_pick_draw_counts_v1';

  static const _muted = Color(0xFF81786B);
  static const _border = Color(0xFFDCD4C6);
  static const _accent = Color(0xFF715B42);

  final Set<String> _selectedTagIds = {};
  final TagStore _tagStore = TagStore.shared;
  final Map<int, int> _drawCounts = {};
  SharedPreferences? _preferences;
  bool _countsLoaded = false;
  Future<void> _pendingWrite = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _tagStore.addListener(_onTagsChanged);
    unawaited(_loadDrawCounts());
  }

  @override
  void dispose() {
    _tagStore.removeListener(_onTagsChanged);
    super.dispose();
  }

  Future<void> _loadDrawCounts() async {
    final counts = <int, int>{};
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final raw = preferences.get(_drawCountsKey);
      final decoded = raw is String ? jsonDecode(raw) : null;
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          final id = int.tryParse(entry.key);
          final count = entry.value;
          if (id != null && count is int && count > 0) {
            counts[id] = count;
          }
        }
      }
    } catch (_) {
      // 损坏或不可用的本地记录不影响抽阅。
    }
    if (!mounted) return;
    setState(() {
      // 当前列表可能只是分页或筛选结果，不以其缺失项判断书籍已删除。
      _drawCounts.addAll(counts);
      _countsLoaded = true;
    });
  }

  double _weightOf(Novel book) {
    final count = _drawCounts[book.id] ?? 0;
    // 极大的次数也保留正权重，避免浮点下溢造成硬排除。
    return math.max(math.pow(0.25, count).toDouble(), double.minPositive);
  }

  Future<bool> _persistDrawCounts() {
    // 保存快照并串行写入，防止较早的抽取覆盖后来的重置。
    final encoded = jsonEncode(
      _drawCounts.map((id, count) => MapEntry('$id', count)),
    );
    final write = _pendingWrite.then((_) async {
      try {
        final preferences = _preferences ??=
            await SharedPreferences.getInstance();
        return await preferences.setString(_drawCountsKey, encoded);
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
    });
    unawaited(_persistDrawCounts());
  }

  Future<void> _resetDrawCounts() async {
    setState(_drawCounts.clear);
    final saved = await _persistDrawCounts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '已重置抽取记录' : '已重置抽取记录，但保存失败')),
    );
  }

  void _onTagsChanged() {
    final validIds = _tagStore.tags.map((t) => t.id).toSet();
    setState(() {
      _selectedTagIds.removeWhere((id) => !validIds.contains(id));
    });
  }

  void _toggleTag(String tagId, bool selected) {
    setState(() {
      if (selected) {
        _selectedTagIds.add(tagId);
      } else {
        _selectedTagIds.remove(tagId);
      }
    });
  }

  void _clearFilter() {
    setState(_selectedTagIds.clear);
  }

  List<Novel> _filterBooks() {
    if (_selectedTagIds.isEmpty) return widget.books;
    return widget.books
        .where((book) {
          final bookTags = _tagStore.tagsForBook(book.id);
          return bookTags.any((tag) => _selectedTagIds.contains(tag.id));
        })
        .toList(growable: false);
  }

  Widget _buildFilterHeader(int candidateCount) {
    final tags = _tagStore.tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _countsLoaded ? _resetDrawCounts : null,
            style: TextButton.styleFrom(
              foregroundColor: _muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('重置抽取记录', style: TextStyle(fontSize: 12)),
          ),
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _selectedTagIds.isEmpty,
                  onSelected: (_) => _clearFilter(),
                  selectedColor: _accent.withAlpha((0.15 * 255).round()),
                  labelStyle: TextStyle(
                    color: _selectedTagIds.isEmpty ? _accent : _muted,
                    fontSize: 13,
                  ),
                  side: const BorderSide(color: _border),
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
                      selectedColor: _accent.withAlpha((0.15 * 255).round()),
                      labelStyle: TextStyle(
                        color: _selectedTagIds.contains(tag.id)
                            ? _accent
                            : _muted,
                        fontSize: 13,
                      ),
                      side: const BorderSide(color: _border),
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
                  '符合任一所选标签 · 共 $candidateCount 本',
                  style: const TextStyle(fontSize: 12, color: _muted),
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
          const Text(
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
    final hasFilter = _selectedTagIds.isNotEmpty;

    Widget? emptyState;
    if (hasFilter && candidates.isEmpty) {
      emptyState = _buildEmptyState();
    } else if (widget.books.isEmpty) {
      // 书库为空时显示明确提示
      emptyState = const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
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
        weightOf: _weightOf,
        onPicked: _recordPick,
        onOpenDetail: widget.onOpenDetail,
        filterHeader: _buildFilterHeader(candidates.length),
        emptyState: emptyState,
      ),
    );
  }
}
