import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'glass_choices.dart';
import 'library_state.dart';
import 'reader_mark_style.dart';
import 'reader_underline.dart';
import 'reader_annotation_range.dart';
import 'reader_text_picker.dart';
export 'reader_annotation_range.dart';

/// Opens the same bookmark editor from selection, reader lists or My bookmarks.
/// Existing notes remain editable even when the original file is unavailable.
Future<ReaderBookmark?> showReaderAnnotationEditor(
  BuildContext context, {
  required LibraryState state,
  required int novelId,
  Novel? novel,
  ReaderBookmark? bookmark,
  ReadingPosition? position,
  List<ReaderUnderlineRange> ranges = const [],
  String quote = '',
  ReaderMarkStyle? initialStyle,
  ReaderAnnotationContextResolver? rangeContextResolver,
  Widget Function(Widget)? surfaceWrapper,
}) {
  if (bookmark == null && ranges.isNotEmpty) {
    final selected = canonicalReaderUnderlineRanges(ranges);
    bookmark = state.bookmarksFor(novelId).where((mark) {
      if (!mark.isUnderline) return false;
      final stored = canonicalReaderUnderlineRanges(mark.underlineRanges);
      return selected.length == stored.length &&
          List.generate(
            selected.length,
            (i) => selected[i] == stored[i],
          ).every((same) => same);
    }).firstOrNull;
  }
  return showJellySheet<ReaderBookmark>(
    context: context,
    reduceMotion: state.reduceMotion,
    guardDragDismiss: true,
    maxWidth: 620,
    surfaceWrapper: surfaceWrapper,
    builder: (_) => ReaderAnnotationEditor(
      state: state,
      novelId: novelId,
      novel: novel,
      bookmark: bookmark,
      position: position,
      ranges: ranges,
      quote: quote,
      initialStyle: initialStyle,
      rangeContextResolver: rangeContextResolver,
    ),
  );
}

/// Shared popup body; storage is delegated to LibraryState's serialized writes.
class ReaderAnnotationEditor extends StatefulWidget {
  const ReaderAnnotationEditor({
    super.key,
    required this.state,
    required this.novelId,
    this.novel,
    this.bookmark,
    this.position,
    this.ranges = const [],
    this.quote = '',
    this.initialStyle,
    this.rangeContextResolver,
  });
  final LibraryState state;
  final int novelId;
  final Novel? novel;
  final ReaderBookmark? bookmark;
  final ReadingPosition? position;
  final List<ReaderUnderlineRange> ranges;
  final String quote;
  final ReaderMarkStyle? initialStyle;
  final ReaderAnnotationContextResolver? rangeContextResolver;

  @override
  State<ReaderAnnotationEditor> createState() => _ReaderAnnotationEditorState();
}

class _ReaderAnnotationEditorState extends State<ReaderAnnotationEditor> {
  late final TextEditingController _note;
  final _excerptScroll = ScrollController(debugLabel: 'annotation excerpt');
  final _excerptFocus = FocusNode(debugLabel: 'annotation excerpt selection');
  late ReaderMarkStyle _style;
  late ReaderMarkColor _color;
  bool _saving = false, _closing = false, _askingToClose = false;
  bool _selectingRange = false;
  ReaderAnnotationRangeChange? _rangeChange;
  Novel? _rangeNovel;
  String? _error;
  List<ReaderUnderlineRange> get _ranges =>
      _rangeChange?.ranges ?? widget.bookmark?.underlineRanges ?? widget.ranges;
  bool get _hasRange => _ranges.isNotEmpty;
  String get _quote =>
      _rangeChange?.quote ?? widget.bookmark?.quote ?? widget.quote;
  bool get _dirty => _annotationDirty || _rangeChange != null;
  bool get _annotationDirty =>
      _note.text != (widget.bookmark?.note ?? '') ||
      _style !=
          (widget.bookmark?.annotation.style ??
              widget.initialStyle ??
              ReaderMarkStyle.highlight) ||
      _color != (widget.bookmark?.annotation.color ?? ReaderMarkColor.amber);

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.bookmark?.note ?? '');
    _note.addListener(_edited);
    _style =
        widget.bookmark?.annotation.style ??
        widget.initialStyle ??
        ReaderMarkStyle.highlight;
    _color = widget.bookmark?.annotation.color ?? ReaderMarkColor.amber;
  }

  void _edited() {
    if (mounted) setState(() => _error = null);
  }

  @override
  void dispose() {
    _note.dispose();
    _excerptScroll.dispose();
    _excerptFocus.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_saving || _closing || _askingToClose) return;
    if (_dirty) {
      _askingToClose = true;
      final discard = await confirmNovelAction(
        context,
        title: '放弃未保存的批注？',
        message: '已保存的书签和标记不会改变。',
        confirmLabel: '放弃修改',
        reduceMotion: widget.state.reduceMotion,
      );
      _askingToClose = false;
      if (!discard) return;
    }
    if (!mounted) return;
    _finish();
  }

  void _finish([ReaderBookmark? result]) {
    setState(() => _closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, result);
    });
  }

  Future<({ReaderAnnotationContext source, Novel novel})>
  _sourceContext() async {
    final resolver = widget.rangeContextResolver;
    final anchor = widget.bookmark?.position ?? widget.position;
    if (resolver == null || anchor == null) {
      throw const FormatException('请打开原书后调整文字范围，个人批注和颜色仍可编辑');
    }
    final source = await resolver(_ranges, anchor);
    if (source == null) {
      throw const FormatException('原文尚未载入或本机不可用，个人批注和颜色仍可编辑');
    }
    if (source.novelId != widget.novelId) {
      throw const FormatException('原文不属于这本书');
    }
    final novel =
        source.novel ??
        widget.novel ??
        widget.state.cachedNovel(widget.novelId);
    if (novel == null || novel.id != widget.novelId) {
      throw const FormatException('原书目录暂不可用，个人批注和颜色仍可编辑');
    }
    return (source: source, novel: novel);
  }

  Future<void> _selectStyle(ReaderMarkStyle style) async {
    if (_saving || _selectingRange || style == _style) return;
    if (style == ReaderMarkStyle.none || _hasRange) {
      setState(() {
        _style = style;
        _error = null;
      });
      return;
    }
    setState(() {
      _selectingRange = true;
      _error = null;
    });
    try {
      final loaded = await _sourceContext();
      if (!mounted) return;
      final change = loaded.source.paragraphAt(
        widget.bookmark?.position ?? widget.position!,
      );
      setState(() {
        _rangeChange = change;
        _rangeNovel = loaded.novel;
        _style = style;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '原文暂时不可读取，个人批注和颜色仍可编辑',
        );
      }
    } finally {
      if (mounted) setState(() => _selectingRange = false);
    }
  }

  Future<void> _adjustRange() async {
    if (_saving || _selectingRange) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _selectingRange = true;
      _error = null;
    });
    try {
      final anchor = widget.bookmark?.position ?? widget.position;
      final loaded = await _sourceContext();
      if (!mounted) return;
      final source = loaded.source, novel = loaded.novel;
      var component = 0;
      if (_ranges.length > 1) {
        final chosen = await showJellySheet<int>(
          context: context,
          reduceMotion: widget.state.reduceMotion,
          builder: (sheet) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ArchiveSection(
                  title: '调整哪个片段',
                  code: 'BOOKMARK / SOURCE RANGE',
                ),
                const SizedBox(height: 12),
                const AppText(
                  '仅调整所选片段，其他片段与隐藏文字保持不变。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 12),
                for (final (index, range) in _ranges.indexed)
                  GlassTextButton(
                    key: ValueKey('annotation-range-component-$index'),
                    onPressed: () => Navigator.pop(sheet, index),
                    child: AppText(
                      '片段 ${index + 1} · ${source.chapters.where((s) => s.chapterId == range.chapterId).firstOrNull?.title ?? '原章节'} · 第 ${range.startParagraph + 1}–${range.endParagraph + 1} 段',
                    ),
                  ),
              ],
            ),
          ),
        );
        if (!mounted || chosen == null) return;
        component = chosen;
      }
      final projection = source.project(
        ranges: _ranges,
        anchor: anchor!,
        component: component,
      );
      final picked = await showReaderTextRangePicker(
        context: context,
        text: projection.text,
        initialRange: projection.initialRange,
        title: '调整原文范围',
        scopeLabel: projection.scopeLabel,
        confirmLabel: '使用此范围',
        reduceMotion: widget.state.reduceMotion,
        maxSelectionCodeUnits: 12000,
        stableScrollGeometry: true,
      );
      if (!mounted || picked == null) return;
      final change = projection.apply(picked);
      setState(() {
        _rangeChange = change;
        _rangeNovel = novel;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '原文暂时不可读取，个人批注仍可编辑',
        );
      }
    } finally {
      if (mounted) setState(() => _selectingRange = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final previous = widget.bookmark;
      final ReaderBookmark result;
      if (previous != null) {
        final change = _rangeChange;
        if (change != null) {
          result = await widget.state.updateBookmarkRange(
            widget.novelId,
            previous.id,
            novel: _rangeNovel!,
            change: change,
            expectedRangeUpdatedAt: previous.rangeUpdatedAt,
            expectedRanges: previous.underlineRanges,
            annotation: _annotationDirty
                ? ReaderAnnotationData(
                    style: _style,
                    color: _color,
                    note: _note.text,
                  )
                : null,
          );
        } else {
          result = await widget.state.updateBookmarkAnnotation(
            widget.novelId,
            previous.id,
            style: _style,
            color: _color,
            note: _note.text,
          );
        }
      } else {
        final novel = _rangeNovel ?? widget.novel, position = widget.position;
        if (novel == null ||
            position == null ||
            novel.id != widget.novelId ||
            _ranges.isEmpty) {
          throw const FormatException('暂时无法定位完整选区，请重新选择');
        }
        result = await widget.state.saveAnnotation(
          novel: novel,
          position: position,
          ranges: _ranges,
          quote: _quote,
          style: _style,
          color: _color,
          note: _note.text,
        );
      }
      if (!mounted) return;
      _finish(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is FormatException ? error.message : '批注未保存，请重试';
        });
      }
    }
  }

  Future<void> _delete() async {
    final mark = widget.bookmark;
    if (mark == null ||
        _saving ||
        !await confirmNovelAction(
          context,
          title: '删除这条${mark.kindLabel}与批注？',
          message: '原书和阅读进度不会改变。',
          confirmLabel: '删除记录',
          reduceMotion: widget.state.reduceMotion,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.removeBookmark(widget.novelId, mark.id);
      if (!mounted) return;
      _finish();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '记录未删除，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final inputStyle = theme.textTheme.bodyMedium!.copyWith(
      inherit: false,
      fontFamily:
          widget.state.appFontFamily ??
          theme.typography.black.bodyMedium?.fontFamily,
      fontSize: 15,
      height: 1.65,
      leadingDistribution: TextLeadingDistribution.even,
      fontWeight: FontWeight.w400,
      color: scheme.onSurface,
    );
    // The hint and editable text must share font metrics, including CJK fallback.
    final inputStrut = StrutStyle.fromTextStyle(
      inputStyle,
      forceStrutHeight: true,
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
      borderSide: BorderSide.none,
    );
    return PopScope<ReaderBookmark>(
      canPop: _closing || !_saving && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: SingleChildScrollView(
        key: const ValueKey('reader-annotation-scroll'),
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: ArchiveSection(
                    title: widget.bookmark == null ? '标记与批注' : '书签与批注',
                    code: 'PERSONAL / ANNOTATION',
                  ),
                ),
                GlassIconButton(
                  icon: CupertinoIcons.xmark,
                  label: '关闭批注',
                  onPressed: _saving ? null : _close,
                ),
              ],
            ),
            if (_quote.isNotEmpty) ...[
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 112),
                child: SingleChildScrollView(
                  key: const ValueKey('reader-annotation-excerpt-scroll'),
                  controller: _excerptScroll,
                  primary: false,
                  // A read-only excerpt has no editable caret to reveal when
                  // delayed keyboard metrics arrive after its selection focus.
                  child: SelectionArea(
                    focusNode: _excerptFocus,
                    child: Text(
                      _quote,
                      style: inputStyle.copyWith(
                        height: 1.7,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            GlassTextButton(
              key: const ValueKey('annotation-adjust-range'),
              onPressed: _saving || _selectingRange ? null : _adjustRange,
              child: AppText(_selectingRange ? '正在载入原文…' : '调整原文范围'),
            ),
            if (_rangeChange != null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: AppText(
                  '范围将在保存后更新；隐藏文字和其他片段保持不变。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            GlassChoiceGroup<ReaderMarkStyle>(
              name: 'reader-mark-style',
              label: '标记方式',
              value: _style,
              options: {
                for (final style in [
                  ReaderMarkStyle.none,
                  ReaderMarkStyle.underline,
                  ReaderMarkStyle.highlight,
                  ReaderMarkStyle.outline,
                ])
                  style: style.label,
              },
              optionName: (style) => style.name,
              enabled: !_saving && !_selectingRange,
              onChanged: _selectStyle,
            ),
            GlassChoiceGroup<ReaderMarkColor>(
              name: 'reader-mark-color',
              label: '标记颜色',
              value: _color,
              options: {
                for (final color in ReaderMarkColor.values) color: color.label,
              },
              optionName: (color) => color.name,
              enabled: !_saving,
              leading: (color) => Icon(
                CupertinoIcons.circle_fill,
                size: 12,
                color: readerMarkInk(color, scheme.onSurface, dark: dark),
              ),
              onChanged: (value) => setState(() => _color = value),
            ),
            const SizedBox(height: 20),
            const AppText(
              '个人批注',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            DefaultSelectionStyle.merge(
              cursorColor: scheme.primary,
              selectionColor: scheme.onSurface.withValues(
                alpha: dark ? .20 : .18,
              ),
              child: DefaultTextStyle.merge(
                textHeightBehavior: const TextHeightBehavior(),
                child: DefaultTextHeightBehavior(
                  textHeightBehavior: const TextHeightBehavior(),
                  child: TextField(
                    key: const ValueKey('reader-annotation-note'),
                    controller: _note,
                    enabled: !_saving,
                    minLines: 5,
                    maxLines: 12,
                    maxLength: ReaderAnnotationData.maxNoteLength,
                    textCapitalization: TextCapitalization.sentences,
                    style: inputStyle,
                    strutStyle: inputStrut,
                    textAlignVertical: TextAlignVertical.top,
                    // Paragraph leading is not part of the visible caret height.
                    cursorHeight: MediaQuery.textScalerOf(
                      context,
                    ).scale(inputStyle.fontSize!),
                    cursorColor: scheme.primary,
                    keyboardAppearance: theme.brightness,
                    decoration: InputDecoration(
                      hint: Text(
                        '记下此刻的理解，或慢慢写一段长文想法…',
                        style: inputStyle.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        strutStyle: inputStrut,
                        textHeightBehavior: const TextHeightBehavior(),
                      ),
                      contentPadding: const EdgeInsets.all(14),
                      isDense: true,
                      filled: true,
                      fillColor: scheme.onSurface.withValues(alpha: .045),
                      border: inputBorder,
                      enabledBorder: inputBorder,
                      focusedBorder: inputBorder,
                      disabledBorder: inputBorder,
                      counterText: '',
                    ),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: AppText(
                  _error!,
                  style: TextStyle(color: scheme.error, height: 1.5),
                ),
              ),
            const SizedBox(height: 18),
            GlassPillButton(
              icon: CupertinoIcons.checkmark,
              label: _saving ? '正在保存…' : '保存到书签',
              onPressed: _saving ? null : _save,
            ),
            if (widget.bookmark != null) ...[
              const SizedBox(height: 8),
              GlassTextButton(
                onPressed: _saving ? null : _delete,
                child: const AppText('删除这条记录'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
