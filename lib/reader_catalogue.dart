import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'catalog.dart';
import 'offline_cache.dart';

/// A bounded, lazy chapter picker using the existing glass drawer. The current
/// chapter is the scroll origin, so locating it never lays out earlier rows.
class ReaderCatalogue extends StatefulWidget {
  const ReaderCatalogue({
    super.key,
    required this.novel,
    required this.currentChapter,
    this.cache,
  });
  final Novel novel;
  final int currentChapter;
  final OfflineCacheStore? cache;

  @override
  State<ReaderCatalogue> createState() => _ReaderCatalogueState();
}

class _ReaderCatalogueState extends State<ReaderCatalogue> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _center = GlobalKey();
  late List<int> _matches = _filter('');

  List<int> _filter(String query) {
    final chapters = widget.novel.chapters;
    final text = query.trim().toLowerCase();
    if (text.isEmpty) return List.generate(chapters.length, (index) => index);
    final number = int.tryParse(text);
    if (number != null) {
      return number > 0 && number <= chapters.length ? [number - 1] : [];
    }
    return [
      for (var index = 0; index < chapters.length; index++)
        if (chapters[index].title.toLowerCase().contains(text)) index,
    ];
  }

  void _filterChanged(String query) {
    setState(() => _matches = _filter(query));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _locateCurrent() {
    _search.clear();
    _filterChanged('');
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = math.max(
      0.0,
      media.size.height - media.padding.vertical - media.viewInsets.bottom - 40,
    );
    final height = math.min(media.size.height * .64, available);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Small landscape/keyboard viewports can scroll the header as well;
          // the chapter list still has its own finite lazy viewport.
          if (constraints.maxHeight < 210) {
            return SingleChildScrollView(
              child: SizedBox(height: 300, child: _contents(context)),
            );
          }
          return _contents(context);
        },
      ),
    );
  }

  Widget _contents(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: ArchiveSection(title: '目录', code: 'READER / CONTENTS'),
            ),
            GlassIconButton(
              icon: CupertinoIcons.location,
              label: '定位当前章节',
              onPressed: _locateCurrent,
            ),
            GlassIconButton(
              icon: CupertinoIcons.xmark,
              label: '关闭目录',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
        CupertinoSearchTextField(
          key: const ValueKey('reader-chapter-search'),
          controller: _search,
          borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
          backgroundColor: Theme.of(context).colorScheme.surface,
          placeholder: '搜索章节名或输入章序',
          onChanged: _filterChanged,
          onSubmitted: (_) => FocusScope.of(context).unfocus(),
          onSuffixTap: () {
            _search.clear();
            _filterChanged('');
          },
        ),
        const SizedBox(height: 10),
        Text(
          _search.text.trim().isEmpty
              ? '共 ${widget.novel.chapters.length} 章 · 当前第 ${widget.currentChapter + 1} 章'
              : '找到 ${_matches.length} 章',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _chapters(context)),
      ],
    ),
  );

  Widget _chapters(BuildContext context) {
    if (_matches.isEmpty) {
      return const Center(child: Text('没有匹配的章节'));
    }
    final current = _matches.indexOf(widget.currentChapter);
    final origin = current < 0 ? 0 : current;
    return CustomScrollView(
      key: const ValueKey('reader-catalogue-scroll'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      center: _center,
      anchor: current > 0 ? .22 : 0,
      slivers: [
        SliverList.builder(
          itemCount: origin,
          itemBuilder: (context, index) =>
              _row(context, _matches[origin - index - 1]),
        ),
        SliverList.builder(
          key: _center,
          itemCount: _matches.length - origin,
          itemBuilder: (context, index) =>
              _row(context, _matches[origin + index]),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int index) {
    final chapter = widget.novel.chapters[index];
    final current = index == widget.currentChapter;
    return Semantics(
      selected: current,
      child: JellyTapSurface(
        key: ValueKey('reader-chapter-$index'),
        onTap: () {
          FocusScope.of(context).unfocus();
          Navigator.pop(context, index);
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: current
                ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .06)
                : null,
            borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 38,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  chapter.title,
                  style: const TextStyle(fontSize: 14, height: 1.45),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (current)
                    const Text('正在阅读', style: TextStyle(fontSize: 10)),
                  if (widget.cache case final OfflineCacheStore cache)
                    AnimatedBuilder(
                      animation: cache.bookChanges(widget.novel.id),
                      builder: (context, _) =>
                          cache
                                  .book(widget.novel.id)
                                  ?.chapterBytes
                                  .containsKey(chapter.id) ==
                              true
                          ? const Text('已缓存', style: TextStyle(fontSize: 10))
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
