import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_platform.dart';

sealed class ReaderToolAction {
  const ReaderToolAction();
}

class ReaderSeekProgress extends ReaderToolAction {
  const ReaderSeekProgress(this.fraction);
  final double fraction;
}

class ReaderOpenBookmark extends ReaderToolAction {
  const ReaderOpenBookmark(this.bookmark);
  final ReaderBookmark bookmark;
}

class ReaderEnterFocus extends ReaderToolAction {
  const ReaderEnterFocus();
}

class ReaderOpenFind extends ReaderToolAction {
  const ReaderOpenFind();
}

/// A bounded settings sheet. Typography drafts preview the article while
/// preferences are committed once, when the gesture ends.
class ReaderTools extends StatefulWidget {
  const ReaderTools({
    super.key,
    required this.novel,
    required this.state,
    required this.position,
    required this.onAddBookmark,
    required this.onFontSize,
    required this.onLineHeight,
    required this.onReset,
    this.initialBookmarks = false,
    this.onFontPreview,
    this.onLineHeightPreview,
    this.onPreviewChanged,
  });
  final Novel novel;
  final LibraryState state;
  final ReadingPosition? position;
  final Future<ReaderBookmark?> Function() onAddBookmark;
  final ValueChanged<double> onFontSize;
  final ValueChanged<double> onLineHeight;
  final VoidCallback onReset;
  final bool initialBookmarks;
  final ValueChanged<double>? onFontPreview, onLineHeightPreview;
  final ValueChanged<bool>? onPreviewChanged;

  @override
  State<ReaderTools> createState() => _ReaderToolsState();
}

class _ReaderToolsState extends State<ReaderTools> {
  late String _tab = widget.initialBookmarks ? 'bookmarks' : 'layout';
  bool _adding = false;
  bool _added = false;
  String? _addedId;
  String? _storageError;
  Key? _activeAdjustment;

  void _preview(Key key, bool active) {
    if (!mounted) return;
    setState(() => _activeAdjustment = active ? key : null);
    widget.onPreviewChanged?.call(active);
  }

  Widget _adjustment(Widget child, [Key? key]) {
    final active = _activeAdjustment != null;
    final visible = !active || key == _activeAdjustment;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: active && visible
                ? Theme.of(context).colorScheme.surface.withValues(alpha: .96)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        ),
      ),
    );
  }

  Future<void> _add() async {
    if (_adding || widget.position == null) return;
    setState(() {
      _adding = true;
      _storageError = null;
    });
    try {
      final mark = await widget.onAddBookmark();
      if (mounted) {
        setState(() {
          _added = mark != null;
          _addedId = mark?.id;
          if (mark == null) _storageError = '阅读位置正在恢复，请稍后再试';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _storageError = '书签保存失败，请重试');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(ReaderBookmark mark) async {
    setState(() => _storageError = null);
    try {
      await widget.state.removeBookmark(widget.novel.id, mark.id);
      if (mounted && mark.id == _addedId) setState(() => _added = false);
    } catch (_) {
      if (mounted) setState(() => _storageError = '书签删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // In landscape/keyboard + large text, scrolling only the body can leave a
      // zero-height viewport below the title/tabs. Let the entire panel scroll.
      final compact = constraints.maxHeight < 260;
      Widget body() => _tab == 'layout'
          ? compact
                ? _layout(context)
                : SingleChildScrollView(
                    key: const ValueKey('reader-settings-scroll'),
                    primary: false,
                    child: _layout(context),
                  )
          : _bookmarks(context);
      final contents = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _adjustment(
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 14, 8),
              child: Row(
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
            ),
          ),
          _adjustment(
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: _tab,
                children: const {
                  'layout': Text('排版与进度'),
                  'bookmarks': Text('书签'),
                },
                onValueChanged: (tab) {
                  if (tab != null) setState(() => _tab = tab);
                },
              ),
            ),
          ),
          if (compact) body() else Flexible(child: body()),
        ],
      );
      return compact
          ? SingleChildScrollView(
              key: const ValueKey('reader-settings-scroll'),
              primary: false,
              child: contents,
            )
          : contents;
    },
  );

  Widget _layout(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
    child: AnimatedBuilder(
      animation: widget.state.readerSettingsChanges,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _adjustment(
            ReaderValueSlider(
              sliderKey: const ValueKey('reader-font-slider'),
              label: '字体大小',
              value: widget.state.fontSize,
              min: 15,
              max: 27,
              divisions: 12,
              format: (value) => '${value.round()} pt',
              onCommitted: widget.onFontSize,
              onPreview: widget.onFontPreview,
              onInteractionChanged: (value) =>
                  _preview(const ValueKey('reader-font-slider'), value),
            ),
            const ValueKey('reader-font-slider'),
          ),
          const SizedBox(height: 8),
          _adjustment(
            ReaderValueSlider(
              sliderKey: const ValueKey('reader-line-height-slider'),
              label: '行距',
              value: widget.state.lineHeight,
              min: 1.3,
              max: 2.2,
              format: (value) => '${value.toStringAsFixed(2)} 倍',
              onCommitted: widget.onLineHeight,
              onPreview: widget.onLineHeightPreview,
              onInteractionChanged: (value) =>
                  _preview(const ValueKey('reader-line-height-slider'), value),
            ),
            const ValueKey('reader-line-height-slider'),
          ),
          _adjustment(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: GlassTextButton(
                    onPressed: widget.onReset,
                    child: const Text('恢复默认排版'),
                  ),
                ),
                const Divider(height: 24),
                ReaderValueSlider(
                  sliderKey: const ValueKey('reader-progress-slider'),
                  label: '本章进度',
                  value: widget.position?.fraction ?? 0,
                  min: 0,
                  max: 1,
                  format: (value) => '${(value * 100).round()}%',
                  onCommitted: widget.position == null
                      ? null
                      : (value) =>
                            Navigator.pop(context, ReaderSeekProgress(value)),
                ),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    GlassTextButton(
                      onPressed: widget.position == null
                          ? null
                          : () => Navigator.pop(
                              context,
                              const ReaderSeekProgress(0),
                            ),
                      child: const Text('回到章首'),
                    ),
                    GlassTextButton(
                      onPressed: widget.position == null
                          ? null
                          : () => Navigator.pop(
                              context,
                              const ReaderSeekProgress(1),
                            ),
                      child: const Text('跳至章末'),
                    ),
                  ],
                ),
                const Divider(height: 24),
                GlassTextButton(
                  key: const ValueKey('reader-open-find'),
                  onPressed: widget.position == null
                      ? null
                      : () => Navigator.pop(context, const ReaderOpenFind()),
                  child: const Text('章内查找'),
                ),
                if (LocalPlatform.android)
                  AnimatedBuilder(
                    animation: widget.state.readerBehaviorChanges,
                    builder: (context, _) => Row(
                      children: [
                        const Expanded(child: Text('阅读时保持亮屏')),
                        CupertinoSwitch(
                          key: const ValueKey('reader-keep-screen-on'),
                          value: widget.state.keepScreenOn,
                          activeTrackColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          onChanged: (value) async {
                            try {
                              await widget.state.setKeepScreenOn(value);
                            } catch (_) {
                              if (context.mounted) {
                                showNovelFeedback(context, '亮屏设置保存失败，请重试');
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                GlassTextButton(
                  onPressed: widget.position == null
                      ? null
                      : () => Navigator.pop(context, const ReaderEnterFocus()),
                  child: const Text('专注阅读 · 隐藏控件'),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '点按正文即可显示或隐藏控件',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _bookmarks(BuildContext context) => SizedBox(
    height: math.min(420, MediaQuery.sizeOf(context).height * .46),
    child: AnimatedBuilder(
      animation: widget.state.bookmarkChanges,
      builder: (context, _) {
        final marks = widget.state.bookmarksFor(widget.novel.id);
        return CustomScrollView(
          key: const ValueKey('reader-bookmarks-scroll'),
          primary: false,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GlassTextButton(
                      key: const ValueKey('reader-add-bookmark'),
                      onPressed: widget.position == null || _adding
                          ? null
                          : _add,
                      child: Text(
                        _adding
                            ? '正在保存…'
                            : _added
                            ? '已添加书签'
                            : '添加当前位置书签',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.position == null
                          ? '章节加载完成后，可保存当前阅读位置。'
                          : '先添加当前位置，再点按下方书签即可回到这里。',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '本书 ${marks.length} 个书签',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_storageError != null)
                      Text(
                        _storageError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (marks.isEmpty)
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(24, 20, 24, 28),
                sliver: SliverToBoxAdapter(child: Text('将喜欢的位置存成书签，下次直接回到这里。')),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                sliver: SliverList.builder(
                  itemCount: marks.length,
                  itemBuilder: (context, index) {
                    final mark = marks[index];
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
                                : () {
                                    Navigator.pop(
                                      context,
                                      ReaderOpenBookmark(mark),
                                    );
                                  },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 14,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    mark.chapterTitle,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    chapter == null
                                        ? '章节已从目录移除'
                                        : '第 ${chapter + 1} 章 · ${(mark.position.fraction * 100).round()}%',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
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
                  },
                ),
              ),
          ],
        );
      },
    ),
  );
}

class ReaderValueSlider extends StatefulWidget {
  const ReaderValueSlider({
    super.key,
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onCommitted,
    this.divisions,
    this.onPreview,
    this.onInteractionChanged,
  });
  final Key sliderKey;
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) format;
  final ValueChanged<double>? onCommitted;
  final ValueChanged<double>? onPreview;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<ReaderValueSlider> createState() => _ReaderValueSliderState();
}

class _ReaderValueSliderState extends State<ReaderValueSlider> {
  late double _draft = widget.value;
  bool _dragging = false;
  bool _pointerCancelled = false;
  double get _unit => (widget.max - widget.min) / (widget.divisions ?? 20);

  void _change(double value) {
    setState(() => _draft = value.clamp(widget.min, widget.max));
    // Accessibility increments have no pointer drag/end callback.
    if (_dragging) {
      widget.onPreview?.call(_draft);
    } else {
      widget.onCommitted?.call(_draft);
    }
  }

  void _adjust(double direction) {
    _change((_draft + direction * _unit).clamp(widget.min, widget.max));
  }

  void _finish() {
    if (!_dragging) return;
    _dragging = false;
    widget.onCommitted?.call(_draft);
    widget.onInteractionChanged?.call(false);
  }

  @override
  void dispose() {
    if (_dragging) {
      // Back navigation can remove the slider before Cupertino's end callback.
      // Retain the last visible value without calling the disposed sheet.
      final commit = widget.onCommitted, draft = _draft;
      scheduleMicrotask(() => commit?.call(draft));
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(ReaderValueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_dragging) _draft = widget.value;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(widget.label)),
          Text(
            widget.format(_draft),
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
      Semantics(
        key: ValueKey('reader-slider-semantics-${widget.label}'),
        label: widget.label,
        value: widget.format(_draft),
        increasedValue: widget.format(
          (_draft + _unit).clamp(widget.min, widget.max),
        ),
        decreasedValue: widget.format(
          (_draft - _unit).clamp(widget.min, widget.max),
        ),
        slider: true,
        enabled: widget.onCommitted != null,
        onIncrease: widget.onCommitted == null || _draft >= widget.max
            ? null
            : () => _adjust(1),
        onDecrease: widget.onCommitted == null || _draft <= widget.min
            ? null
            : () => _adjust(-1),
        child: ExcludeSemantics(
          child: Listener(
            onPointerCancel: (_) {
              _pointerCancelled = _dragging;
              _finish();
            },
            child: CupertinoSlider(
              key: widget.sliderKey,
              value: _draft.clamp(widget.min, widget.max),
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              activeColor: Theme.of(context).colorScheme.primary,
              onChanged: widget.onCommitted == null ? null : _change,
              onChangeStart: (_) {
                _pointerCancelled = false;
                _dragging = true;
                widget.onInteractionChanged?.call(true);
              },
              onChangeEnd: (value) {
                if (_pointerCancelled) return;
                if (_dragging) {
                  _draft = value.clamp(widget.min, widget.max);
                  _finish();
                } else {
                  widget.onCommitted?.call(value);
                }
              },
            ),
          ),
        ),
      ),
    ],
  );
}
