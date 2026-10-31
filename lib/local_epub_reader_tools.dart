import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'reader_tools.dart';

class LocalEpubReaderTools extends StatefulWidget {
  const LocalEpubReaderTools({
    super.key,
    required this.novel,
    required this.state,
    required this.chapter,
    required this.onAddBookmark,
    this.initialBookmarks = false,
    this.chapterProgress = 0,
  });

  final Novel novel;
  final LibraryState state;
  final int chapter;
  final Future<ReaderBookmark?> Function() onAddBookmark;
  final bool initialBookmarks;

  /// 打开面板时当前章的滚动比例（0~1）。
  final double chapterProgress;

  @override
  State<LocalEpubReaderTools> createState() => _LocalEpubReaderToolsState();
}

class _LocalEpubReaderToolsState extends State<LocalEpubReaderTools> {
  late String _tab = widget.initialBookmarks ? 'bookmarks' : 'layout';
  bool _adding = false;
  String? _addedId;
  String? _error;

  Future<void> _typography({
    double? fontSize,
    double? lineHeight,
    bool persist = true,
  }) async {
    try {
      await widget.state.setTypography(
        fontSize: fontSize,
        lineHeight: lineHeight,
        persist: persist,
      );
    } catch (_) {
      if (mounted) setState(() => _error = '排版设置保存失败，请重试');
    }
  }

  Future<void> _add() async {
    if (_adding) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final mark = await widget.onAddBookmark();
      if (mounted) {
        setState(() {
          _addedId = mark?.id;
          if (mark == null) _error = '书签保存失败，请重试';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '书签保存失败，请重试');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(ReaderBookmark mark) async {
    setState(() => _error = null);
    try {
      await widget.state.removeBookmark(widget.novel.id, mark.id);
      if (mounted && mark.id == _addedId) setState(() => _addedId = null);
    } catch (_) {
      if (mounted) setState(() => _error = '书签删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.state.readerSettingsChanges,
      widget.state.bookmarkChanges,
    ]),
    builder: (context, _) => ListView(
      key: const ValueKey('epub-settings-scroll'),
      shrinkWrap: true,
      primary: false,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: ArchiveSection(
                title: '阅读设置',
                code: 'READER / CONTROL PANEL',
              ),
            ),
            GlassIconButton(
              icon: CupertinoIcons.xmark,
              label: '关闭阅读设置',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        CupertinoSlidingSegmentedControl<String>(
          groupValue: _tab,
          children: const {'layout': Text('排版与进度'), 'bookmarks': Text('书签')},
          onValueChanged: (tab) {
            if (tab != null) setState(() => _tab = tab);
          },
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_tab == 'layout') ..._layout() else ..._bookmarks(),
      ],
    ),
  );

  List<Widget> _layout() => [
    ReaderValueSlider(
      sliderKey: const ValueKey('reader-font-slider'),
      label: '字体大小',
      value: widget.state.fontSize,
      min: 15,
      max: 27,
      divisions: 12,
      format: (value) => '${value.round()} pt',
      onPreview: (value) => _typography(fontSize: value, persist: false),
      onCommitted: (value) => _typography(fontSize: value),
    ),
    const SizedBox(height: 8),
    ReaderValueSlider(
      sliderKey: const ValueKey('reader-line-height-slider'),
      label: '行距',
      value: widget.state.lineHeight,
      min: 1.3,
      max: 2.2,
      format: (value) => '${value.toStringAsFixed(2)} 倍',
      onPreview: (value) => _typography(lineHeight: value, persist: false),
      onCommitted: (value) => _typography(lineHeight: value),
    ),
    Align(
      alignment: Alignment.centerRight,
      child: GlassTextButton(
        onPressed: () => _typography(fontSize: 19, lineHeight: 1.72),
        child: const Text('恢复默认排版'),
      ),
    ),
    const Divider(height: 24),
    Text('第 ${widget.chapter + 1} 章 / 共 ${widget.novel.chapters.length} 章'),
    const SizedBox(height: 8),
    Text(
      '本章已读 ${(widget.chapterProgress.clamp(0.0, 1.0) * 100).round()}%',
      key: const ValueKey('epub-chapter-progress'),
    ),
    GlassTextButton(
      onPressed: () => Navigator.pop(context, const ReaderEnterFocus()),
      child: const Text('专注阅读 · 隐藏控件'),
    ),
    const Text('点按正文即可显示或隐藏控件'),
  ];

  List<Widget> _bookmarks() {
    final marks = widget.state.bookmarksFor(widget.novel.id);
    return [
      GlassTextButton(
        key: const ValueKey('reader-add-bookmark'),
        onPressed: _adding ? null : _add,
        child: Text(
          _adding
              ? '正在保存…'
              : _addedId != null
              ? '已添加书签'
              : '添加当前章节书签',
        ),
      ),
      const SizedBox(height: 8),
      const Text('EPUB 书签保存到章节开头，点按书签可跳到该章章首。'),
      const SizedBox(height: 8),
      Text('本书 ${marks.length} 个书签'),
      if (marks.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('将喜欢的章节存成书签，下次直接回到这里。'),
        ),
      for (final mark in marks) _bookmark(mark),
    ];
  }

  Widget _bookmark(ReaderBookmark mark) {
    final chapter = widget.state.chapterForPosition(
      widget.novel,
      mark.position,
    );
    return Row(
      children: [
        Expanded(
          child: JellyTapSurface(
            key: ValueKey('reader-bookmark-${mark.id}'),
            onTap: chapter == null
                ? null
                : () => Navigator.pop(context, ReaderOpenBookmark(mark)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mark.chapterTitle),
                  Text(
                    chapter == null ? '章节已从目录移除' : '第 ${chapter + 1} 章 · 章首',
                  ),
                ],
              ),
            ),
          ),
        ),
        GlassIconButton(
          icon: CupertinoIcons.trash,
          label: '删除书签 ${mark.id}',
          onPressed: () => _remove(mark),
        ),
      ],
    );
  }
}
