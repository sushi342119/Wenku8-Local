import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'reader_word_segments.dart';

export 'reader_word_segments.dart';

/// Keeps short excerpts compact without measuring or segmenting the full input.
/// Larger accessibility text retains the full scrolling surface.
double readerTextSheetHeightFactor(BuildContext context, String text) {
  if (MediaQuery.textScalerOf(context).scale(16) > 20) return .82;
  if (text.length <= 32) return .50;
  if (text.length <= 120) return .68;
  return .82;
}

/// Picks one continuous range in the unchanged input text. Source/book mapping
/// remains the caller's responsibility; cancel never yields an implied range.
Future<TextRange?> showReaderTextRangePicker({
  required BuildContext context,
  required String text,
  TextRange? initialRange,
  String title = '选择文字',
  String confirmLabel = '使用选区',
  String? scopeLabel,
  bool reduceMotion = false,
  ReaderTextUnit initialUnit = ReaderTextUnit.word,
  int? maxSelectionCodeUnits,
  int? maxSelectionRunes,
  ReaderTextSegmentProvider? segmentProvider,
  bool stableScrollGeometry = false,
}) => showJellySheet<TextRange>(
  context: context,
  reduceMotion: reduceMotion,
  heightFactor: readerTextSheetHeightFactor(context, text),
  maxWidth: 640,
  builder: (sheet) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppText(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ArchiveIconButton(
              tooltip: '取消选择文字',
              onPressed: () => Navigator.pop(sheet),
              icon: const ArchiveIcon(CupertinoIcons.xmark, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (scopeLabel != null && scopeLabel.trim().isNotEmpty) ...[
          AppText(
            scopeLabel,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Theme.of(sheet).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
        ],
        Expanded(
          child: ReaderTextRangePicker(
            text: text,
            initialRange: initialRange,
            initialUnit: initialUnit,
            confirmLabel: confirmLabel,
            maxSelectionCodeUnits: maxSelectionCodeUnits,
            maxSelectionRunes: maxSelectionRunes,
            segmentProvider: segmentProvider,
            stableScrollGeometry: stableScrollGeometry,
            onConfirm: (range) => Navigator.pop(sheet, range),
            onCancel: () => Navigator.pop(sheet),
          ),
        ),
      ],
    ),
  ),
);

/// An embeddable text-only selector, also used inside the existing dictionary
/// popup so choosing a word never replaces the reading page or stacks a page.
class ReaderTextRangePicker extends StatefulWidget {
  const ReaderTextRangePicker({
    super.key,
    required this.text,
    required this.onConfirm,
    this.onCancel,
    this.initialRange,
    this.initialUnit = ReaderTextUnit.word,
    this.confirmLabel = '使用选区',
    this.maxSelectionCodeUnits,
    this.maxSelectionRunes,
    this.segmentProvider,
    this.stableScrollGeometry = false,
  });
  final String text, confirmLabel;
  final TextRange? initialRange;
  final ReaderTextUnit initialUnit;
  final ValueChanged<TextRange> onConfirm;
  final VoidCallback? onCancel;
  final int? maxSelectionCodeUnits, maxSelectionRunes;
  final ReaderTextSegmentProvider? segmentProvider;

  /// Range editors already provide bounded source windows. Resolve their token
  /// geometry before scrolling so placeholders cannot move a reading anchor.
  final bool stableScrollGeometry;
  @override
  State<ReaderTextRangePicker> createState() => _ReaderTextRangePickerState();
}

class _ReaderTextRangePickerState extends State<ReaderTextRangePicker> {
  ReaderTextPickerDocument? _document;
  TextRange? _range, _anchor;
  late ReaderTextUnit _unit = widget.initialUnit;
  bool _extend = false;
  String? _error;
  int _generation = 0;
  final _center = GlobalKey();
  final _ranges = <(int, ReaderTextUnit, Locale?), Future<List<TextRange>>>{};
  final _resolvedRanges = <(int, ReaderTextUnit, Locale?), List<TextRange>>{};
  Locale? _locale;
  bool _geometryReady = false, _preparingGeometry = false;
  String? _geometryError;
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.maybeLocaleOf(context);
    if (_locale != locale) {
      _locale = locale;
      _geometryReady = false;
      _geometryError = null;
    }
    _prepareGeometry();
  }

  @override
  void didUpdateWidget(ReaderTextRangePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.initialRange != widget.initialRange) {
      _prepare();
    }
    if (oldWidget.segmentProvider != widget.segmentProvider ||
        oldWidget.initialUnit != widget.initialUnit ||
        oldWidget.stableScrollGeometry != widget.stableScrollGeometry) {
      ++_generation;
      _ranges.clear();
      _resolvedRanges.clear();
      _geometryReady = false;
      _geometryError = null;
      _unit = widget.initialUnit;
      _prepareGeometry();
    }
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    _document = null;
    _error = null;
    _ranges.clear();
    _resolvedRanges.clear();
    _geometryReady = false;
    _geometryError = null;
    _range = null;
    _anchor = null;
    try {
      final input = (widget.text, widget.initialRange);
      final document = widget.text.length > 4096
          ? await compute(prepareReaderTextPicker, input)
          : prepareReaderTextPicker(input);
      if (!mounted || generation != _generation) return;
      setState(() {
        _document = document;
        _range = document.initialRange;
      });
      _prepareGeometry();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '这段文字暂时无法选择，请缩小选区后重试',
        );
      }
    }
  }

  Future<void> _prepareGeometry() async {
    final document = _document;
    if (!widget.stableScrollGeometry ||
        document == null ||
        _preparingGeometry ||
        _geometryReady ||
        _geometryError != null) {
      return;
    }
    final generation = _generation, locale = _locale;
    _preparingGeometry = true;
    try {
      // Keep worker messages bounded while preparing only offsets, not widgets.
      for (var start = 0; start < document.chunks.length; start += 8) {
        await Future.wait([
          for (
            var index = start;
            index < start + 8 && index < document.chunks.length;
            index++
          )
            _chunkRanges(index, unit: ReaderTextUnit.word, locale: locale),
        ]);
        if (!mounted || generation != _generation || locale != _locale) return;
      }
      if (mounted && generation == _generation) {
        setState(() => _geometryReady = true);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _geometryError = '分词未完成，可切换按字选择。');
      }
    } finally {
      _preparingGeometry = false;
      if (mounted && _geometryError == null && !_geometryReady) {
        _prepareGeometry();
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  Future<List<TextRange>> _chunkRanges(
    int index, {
    ReaderTextUnit? unit,
    Locale? locale,
  }) {
    unit ??= _unit;
    locale ??= _locale;
    final key = (index, unit, locale);
    final generation = _generation;
    final resolved = _resolvedRanges[key];
    if (resolved != null) return Future.value(resolved);
    final cached = _ranges.remove(key);
    if (cached != null) {
      _ranges[key] = cached;
      return cached;
    }
    final chunk = _document!.chunks[index];
    final window = unit == ReaderTextUnit.character
        ? chunk.core
        : chunk.context;
    final source = widget.text.substring(window.start, window.end);
    final result = () async {
      final local = unit == ReaderTextUnit.character
          ? readerTextUnitRanges(source, unit: ReaderTextUnit.character)
          : await (widget.segmentProvider ?? readerTextWordSegments)(
              source,
              locale: locale,
            );
      final ranges = <TextRange>[
        for (final range in local)
          if (range.isValid &&
              range.start >= 0 &&
              range.end <= source.length &&
              range.start + window.start >= chunk.core.start &&
              range.start + window.start < chunk.core.end)
            TextRange(
              start: range.start + window.start,
              end: range.end + window.start,
            ),
      ];
      if (mounted && generation == _generation) {
        _resolvedRanges[key] = ranges;
        if (!widget.stableScrollGeometry && _resolvedRanges.length > 96) {
          _resolvedRanges.remove(_resolvedRanges.keys.first);
        }
      }
      return ranges;
    }();
    _ranges[key] = result;
    while (_ranges.length > 24) {
      _ranges.remove(_ranges.keys.first);
    }
    return result;
  }

  void _select(TextRange range) {
    setState(() {
      if (!_extend || _anchor == null) {
        _range = range;
        _anchor = _extend ? range : null;
      } else {
        _range = TextRange(
          start: range.start < _anchor!.start ? range.start : _anchor!.start,
          end: range.end > _anchor!.end ? range.end : _anchor!.end,
        );
      }
    });
  }

  String? get _selectionError {
    final range = _range;
    if (range == null || range.isCollapsed) return null;
    if (widget.maxSelectionCodeUnits case final maximum?
        when range.end - range.start > maximum) {
      return '请选择 $maximum 字符以内的文字';
    }
    if (widget.maxSelectionRunes case final maximum?) {
      if (widget.text
              .substring(range.start, range.end)
              .runes
              .take(maximum + 1)
              .length >
          maximum) {
        return '请选择 $maximum 字以内的词语或短语';
      }
    }
    return null;
  }

  String get _preview {
    final range = _range;
    if (range == null) return '尚未选择文字';
    final characters = widget.text.substring(range.start, range.end).characters;
    final parts = characters.take(81).toList();
    return '${parts.take(80).join()}${parts.length > 80 ? '…' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final document = _document, error = _selectionError;
    final pivot =
        document?.chunkForOffset(document.initialRange?.start ?? 0) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          key: const ValueKey('reader-text-picker-toolbar'),
          children: [
            Expanded(
              child: AppControls.segments<ReaderTextUnit>(
                context,
                key: const ValueKey('reader-text-picker-mode'),
                groupValue: _unit,
                children: const {
                  ReaderTextUnit.word: Text('分词'),
                  ReaderTextUnit.character: Text('按字'),
                },
                onValueChanged: (unit) {
                  if (unit != null) setState(() => _unit = unit);
                },
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() {
                _extend = !_extend;
                _anchor = _extend ? _range : null;
              }),
              child: AppText(_extend ? '连选中' : '连续选择'),
            ),
          ],
        ),
        if (_extend)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: AppText(
              '点选起点与终点，连续保留中间文字',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child:
              (_error ??
                      (_unit == ReaderTextUnit.word ? _geometryError : null)) !=
                  null
              ? Center(
                  child: AppText(
                    (_error ?? _geometryError)!,
                    style: const TextStyle(height: 1.6),
                  ),
                )
              : document == null ||
                    widget.stableScrollGeometry &&
                        _unit == ReaderTextUnit.word &&
                        !_geometryReady
              ? const Center(child: CupertinoActivityIndicator())
              : document.chunks.isEmpty
              ? const Center(child: AppText('没有可选择的文字'))
              : CustomScrollView(
                  key: const ValueKey('reader-text-picker-scroll'),
                  center: _center,
                  cacheExtent: 0,
                  slivers: [
                    if (pivot > 0)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, index) => _chunk(pivot - 1 - index),
                          childCount: pivot,
                        ),
                      ),
                    SliverList(
                      key: _center,
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => _chunk(pivot + index),
                        childCount: document.chunks.length - pivot,
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Semantics(
                label: _range == null ? _preview : '已选文字：$_preview',
                excludeSemantics: true,
                child: AppText(
                  _preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: _range == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _range == null
                  ? null
                  : () => setState(() {
                      _range = null;
                      _anchor = null;
                    }),
              child: const AppText('重选'),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AppText(
              error,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (widget.onCancel != null) ...[
              Expanded(
                child: GlassTextButton(
                  compact: true,
                  onPressed: widget.onCancel,
                  child: const AppText('取消'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: GlassTextButton(
                key: const ValueKey('reader-text-picker-confirm'),
                compact: true,
                onPressed: _range == null || error != null
                    ? null
                    : () => widget.onConfirm(_range!),
                child: AppText(widget.confirmLabel),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chunk(int index) {
    if (_unit == ReaderTextUnit.character) {
      final core = _document!.chunks[index].core;
      return _chunkBody(
        readerTextUnitRanges(
              widget.text.substring(core.start, core.end),
              unit: ReaderTextUnit.character,
            )
            .map(
              (range) => TextRange(
                start: range.start + core.start,
                end: range.end + core.start,
              ),
            )
            .toList(),
      );
    }
    return FutureBuilder<List<TextRange>>(
      initialData: _resolvedRanges[(index, _unit, _locale)],
      future: _chunkRanges(index),
      builder: (context, snapshot) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: snapshot.hasError
            ? const AppText('分词未完成，可切换按字选择。')
            : !snapshot.hasData
            ? const SizedBox(
                height: 40,
                child: Center(child: CupertinoActivityIndicator()),
              )
            : _tokens(snapshot.data!),
      ),
    );
  }

  Widget _chunkBody(List<TextRange> ranges) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: _tokens(ranges),
  );

  Widget _tokens(List<TextRange> ranges) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [for (final range in ranges) _token(range)],
  );

  Widget _token(TextRange range) {
    final selected =
        _range != null &&
        range.start < _range!.end &&
        range.end > _range!.start;
    final scheme = Theme.of(context).colorScheme;
    final text = widget.text.substring(range.start, range.end);
    final label = text.length > 256 ? '组合字符' : text;
    return Semantics(
      selected: selected,
      label: text.length > 256 ? '长组合字符' : text,
      button: true,
      child: JellyTapSurface(
        key: ValueKey(('reader-text-unit', range.start, range.end)),
        onTap: () => _select(range),
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? scheme.onSurface.withValues(alpha: .12)
                : scheme.onSurface.withValues(alpha: .035),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.onSurface.withValues(alpha: .5)
                  : scheme.outlineVariant,
            ),
          ),
          child: AppText(
            label,
            style: const TextStyle(fontSize: 15, height: 1.4),
          ),
        ),
      ),
    );
  }
}
