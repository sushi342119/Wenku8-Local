import 'package:flutter/material.dart';

import 'archive_random_pick_card.dart';
import 'book_tags.dart';
import 'catalog.dart';

/// 首页随机抽阅的标签筛选包装组件。
/// 管理标签选择状态，按标签筛选书籍，再传给 ArchiveRandomPickCard。
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
  static const _muted = Color(0xFF81786B);
  static const _border = Color(0xFFDCD4C6);
  static const _accent = Color(0xFF715B42);

  final Set<String> _selectedTagIds = {};
  final TagStore _tagStore = TagStore.shared;

  @override
  void initState() {
    super.initState();
    _tagStore.addListener(_onTagsChanged);
  }

  @override
  void dispose() {
    _tagStore.removeListener(_onTagsChanged);
    super.dispose();
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
    return widget.books.where((book) {
      final bookTags = _tagStore.tagsForBook(book.id);
      return bookTags.any((tag) => _selectedTagIds.contains(tag.id));
    }).toList(growable: false);
  }

  Widget _buildFilterHeader(int candidateCount) {
    final tags = _tagStore.tags;
    if (tags.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _selectedTagIds.isEmpty,
                onSelected: (_) => _clearFilter(),
                selectedColor: _accent.withOpacity(0.15),
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
                    selectedColor: _accent.withOpacity(0.15),
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
        if (_selectedTagIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '符合任一所选标签 · 共 $candidateCount 本',
                  style: const TextStyle(
                    fontSize: 12,
                    color: _muted,
                  ),
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
            style: TextStyle(
              fontSize: 15,
              color: _muted,
            ),
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
        child: Text(
          '书库暂无书籍',
          style: TextStyle(fontSize: 15, color: _muted),
        ),
      );
    }

    return ArchiveRandomPickCard<Novel>(
      books: candidates,
      titleOf: (book) => book.title,
      authorOf: (book) => book.author,
      identityOf: (book) => book.id,
      onOpenDetail: widget.onOpenDetail,
      filterHeader: _buildFilterHeader(candidates.length),
      emptyState: emptyState,
    );
  }
}
