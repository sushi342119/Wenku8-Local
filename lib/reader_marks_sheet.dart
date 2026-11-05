import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'catalog.dart';
import 'library_state.dart';
import 'offline_cache.dart';
import 'reader_catalogue.dart';

/// Design 2026-11 §5.4: one bottom sheet with 目录 / 书签 / 划线 tabs.
/// Pops an `int` (chapter index) from the contents tab, exactly as the
/// catalogue did, or a [ReaderBookmark] from the other two tabs.
class ReaderMarksSheet extends StatefulWidget {
  const ReaderMarksSheet({
    super.key,
    required this.state,
    required this.novel,
    required this.currentChapter,
    this.cache,
  });
  final LibraryState state;
  final Novel novel;
  final int currentChapter;
  final OfflineCacheStore? cache;

  @override
  State<ReaderMarksSheet> createState() => _ReaderMarksSheetState();
}

enum _MarksTab { contents, bookmarks, underlines }

class _ReaderMarksSheetState extends State<ReaderMarksSheet> {
  _MarksTab _tab = _MarksTab.contents;

  @override
  Widget build(BuildContext context) {
    final tabs = Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: CupertinoSlidingSegmentedControl<_MarksTab>(
        key: const ValueKey('reader-marks-tabs'),
        groupValue: _tab,
        children: const {
          _MarksTab.contents: Text('目录'),
          _MarksTab.bookmarks: Text('书签'),
          _MarksTab.underlines: Text('划线'),
        },
        onValueChanged: (tab) {
          if (tab != null) setState(() => _tab = tab);
        },
      ),
    );
    // Small keyboard/landscape viewports: the body shrinks to what is left
    // under the tab bar instead of overflowing the sheet.
    Widget layout(Widget body) => LayoutBuilder(
      builder: (context, constraints) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tabs,
          if (constraints.hasBoundedHeight) Flexible(child: body) else body,
        ],
      ),
    );
    if (_tab == _MarksTab.contents) {
      return layout(
        ReaderCatalogue(
          novel: widget.novel,
          currentChapter: widget.currentChapter,
          cache: widget.cache,
        ),
      );
    }
    final height = math.min(
      MediaQuery.sizeOf(context).height * .64,
      math.max(
        200.0,
        MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).vertical -
            40,
      ),
    );
    return layout(
      SizedBox(
        height: height,
        child: AnimatedBuilder(
          animation: widget.state.bookmarkChanges,
          builder: (context, _) => _marks(
            context,
            underlines: _tab == _MarksTab.underlines,
          ),
        ),
      ),
    );
  }

  Widget _marks(BuildContext context, {required bool underlines}) {
    final scheme = Theme.of(context).colorScheme;
    final marks = [
      for (final mark in widget.state.bookmarksFor(widget.novel.id))
        if (mark.isUnderline == underlines) mark,
    ];
    if (marks.isEmpty) {
      return Center(
        child: Text(
          underlines ? '还没有划线。长按正文选字后可划线。' : '还没有书签。在排版面板里可添加书签。',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      key: ValueKey(underlines ? 'reader-underline-list' : 'reader-bookmark-list'),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      itemCount: marks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final mark = marks[index];
        final quote = mark.quote.trim();
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          minVerticalPadding: 10,
          title: Text(
            quote.isEmpty
                ? mark.chapterTitle
                : quote.characters.take(40).toString(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              mark.chapterTitle,
              if (mark.createdAt case final at?) _relative(at),
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          onTap: () => Navigator.pop(context, mark),
        );
      },
    );
  }

  static String _relative(DateTime at) {
    final diff = DateTime.now().difference(at.toLocal());
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final local = at.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}
