import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'app_ui.dart';
import 'app_interactions.dart';

/// Punctuation-bounded sentence, including closing quotation marks. The range
/// is UTF-16 like Flutter selection offsets; dragging handles stays native.
TextRange readerSentenceRange(
  String text,
  int offset, {
  List<int> paragraphEnds = const [],
}) {
  if (text.isEmpty) return TextRange.empty;
  final at = offset.clamp(0, text.length - 1);
  const ends = '。！？!?\n';
  const closes = '」』”’）】》〉"';
  final lower = paragraphEnds.where((end) => end <= at).lastOrNull ?? 0;
  final upper =
      paragraphEnds.where((end) => end > at).firstOrNull ?? text.length;
  bool stop(int i) =>
      ends.contains(text[i]) ||
      text[i] == '.' &&
          (i + 1 == upper ||
              text[i + 1].trim().isEmpty ||
              closes.contains(text[i + 1]));
  var start = at, end = at;
  while (start > lower && !stop(start - 1)) {
    start--;
  }
  while (start < at &&
      (text[start].trim().isEmpty || closes.contains(text[start]))) {
    start++;
  }
  while (end < upper && !stop(end)) {
    end++;
  }
  if (end < upper) end++;
  while (end < upper && closes.contains(text[end])) {
    end++;
  }
  return TextRange(start: start, end: end);
}

typedef ReaderSelectionAnchor = ({int paragraph, int offset});

class ReaderQuoteRange {
  const ReaderQuoteRange(this.start, this.end, {this.chapter});
  final ReaderSelectionAnchor start, end;
  final int? chapter;
}

class ReaderQuoteSelection {
  const ReaderQuoteSelection(
    this.text,
    this.anchor, {
    this.chapter,
    this.ranges = const [],
  });
  final String text;
  final ReaderSelectionAnchor? anchor;
  final int? chapter;

  /// Source UTF-16 ranges, with an exclusive end, never a viewport cursor.
  final List<ReaderQuoteRange> ranges;
}

class ReaderSelectionController extends ValueNotifier<bool> {
  ReaderSelectionController() : super(false);
  final key = GlobalKey<SelectionAreaState>();
  String text = '';
  final _anchors =
      <
        Object,
        List<
          ({
            ReaderSelectionAnchor start,
            ReaderSelectionAnchor? end,
            int? chapter,
          })
        >
      >{};
  ReaderQuoteSelection get quote {
    final values = _anchors.values.expand((ranges) => ranges).toList()
      ..sort(
        (a, b) => a.chapter != b.chapter
            ? (a.chapter ?? 0).compareTo(b.chapter ?? 0)
            : a.start.paragraph == b.start.paragraph
            ? a.start.offset.compareTo(b.start.offset)
            : a.start.paragraph.compareTo(b.start.paragraph),
      );
    final first = values.firstOrNull;
    final ranges = [
      for (final value in values)
        if (value.end != null)
          ReaderQuoteRange(value.start, value.end!, chapter: value.chapter),
    ];
    return ReaderQuoteSelection(
      text,
      first?.start,
      chapter: first?.chapter,
      ranges: List.unmodifiable(ranges),
    );
  }

  void clear() {
    key.currentState?.selectableRegion.clearSelection();
    value = false;
    text = '';
    _anchors.clear();
  }
}

/// Lazy text fragments report exact selected offsets only while selecting.
/// Paragraph IDs remain source IDs across pagination, spreads and tategaki.
class ReaderSelectionFragment extends StatefulWidget {
  const ReaderSelectionFragment({
    super.key,
    required this.controller,
    required this.anchorForOffset,
    this.anchorForEndOffset,
    required this.child,
    this.text,
    this.selectableOffset = 0,
    this.paragraphEnds = const [],
    this.chapter,
  });
  final ReaderSelectionController controller;
  final ReaderSelectionAnchor? Function(int offset) anchorForOffset;
  final ReaderSelectionAnchor? Function(int offset)? anchorForEndOffset;
  final Widget child;
  final String? text;
  // RenderParagraph reports offsets in the full span, but excludes a leading
  // WidgetSpan from contentLength. Normalize that geometry-only indent here.
  final int selectableOffset;
  final List<int> paragraphEnds;
  final int? chapter;
  @override
  State<ReaderSelectionFragment> createState() =>
      _ReaderSelectionFragmentState();
}

class _ReaderSelectionFragmentState extends State<ReaderSelectionFragment> {
  late final _registrar = _FragmentRegistrar(
    _changed,
    () => widget.text,
    () => widget.paragraphEnds,
    () => widget.selectableOffset,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registrar.parent = SelectionContainer.maybeOf(context);
  }

  void _changed() {
    final range = _registrar.selectedRange;
    if (range == null) {
      widget.controller._anchors.remove(this);
      return;
    }
    final ranges =
        <
          ({
            ReaderSelectionAnchor start,
            ReaderSelectionAnchor? end,
            int? chapter,
          })
        >[];
    var lower = range.start;
    for (final upper in [
      ...widget.paragraphEnds.where(
        (end) => end > range.start && end < range.end,
      ),
      range.end,
    ]) {
      final start = widget.anchorForOffset(lower);
      final end = (widget.anchorForEndOffset ?? widget.anchorForOffset)(upper);
      if (start != null) {
        ranges.add((start: start, end: end, chapter: widget.chapter));
      }
      lower = upper;
    }
    if (ranges.isEmpty) {
      widget.controller._anchors.remove(this);
    } else {
      widget.controller._anchors[this] = ranges;
    }
  }

  @override
  void didUpdateWidget(ReaderSelectionFragment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._anchors.remove(this);
    }
    _changed();
  }

  @override
  void deactivate() {
    // Detach while the text renderer and its handle layers are still alive.
    // Waiting until dispose leaves the selection owner pointing at a renderer
    // that a page/viewport transition has already disposed.
    _registrar.parent = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _registrar.parent = SelectionContainer.maybeOf(context);
  }

  @override
  void dispose() {
    widget.controller._anchors.remove(this);
    _registrar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionRegistrarScope(registrar: _registrar, child: widget.child);
}

/// Observe the real text selectables without inserting a geometry container
/// into a lazy scrollable. Its native registrar keeps hit-testing, reading order
/// and drag auto-scroll; only selected UTF-16 offsets are observed here.
class _FragmentRegistrar implements SelectionRegistrar {
  _FragmentRegistrar(this.changed, this.text, this.paragraphEnds, this.offset);
  final VoidCallback changed;
  final String? Function() text;
  final List<int> Function() paragraphEnds;
  final int Function() offset;
  final _members = <Selectable, _SentenceSelectable>{};
  SelectionRegistrar? _parent;
  set parent(SelectionRegistrar? value) {
    if (identical(value, _parent)) return;
    for (final member in _members.values) {
      _parent?.remove(member);
    }
    _parent = value;
    for (final member in _members.values) {
      _parent?.add(member);
    }
  }

  TextRange? get selectedRange {
    var preceding = 0;
    int? start, end;
    for (final member in _members.values) {
      final range = member.getSelection();
      if (range != null && range.startOffset != range.endOffset) {
        final lower = range.startOffset < range.endOffset
            ? range.startOffset
            : range.endOffset;
        final upper = range.startOffset > range.endOffset
            ? range.startOffset
            : range.endOffset;
        start ??= preceding + lower;
        end = preceding + upper;
      }
      preceding += member.contentLength;
    }
    return start == null || end == null
        ? null
        : TextRange(start: start, end: end);
  }

  @override
  void add(Selectable selectable) {
    if (_members.containsKey(selectable)) return;
    final proxy = _SentenceSelectable(selectable, offset, (offset) {
      final source = text();
      if (source == null) return null;
      var start = 0;
      for (final member in _members.keys) {
        if (identical(member, selectable)) break;
        start += member.contentLength;
      }
      if (start + selectable.contentLength > source.length) return null;
      final range = readerSentenceRange(
        source,
        start + offset,
        paragraphEnds: paragraphEnds(),
      );
      return TextRange(
        start:
            range.start.clamp(start, start + selectable.contentLength) - start,
        end: range.end.clamp(start, start + selectable.contentLength) - start,
      );
    });
    _members[selectable] = proxy;
    selectable.addListener(changed);
    _parent?.add(proxy);
  }

  @override
  void remove(Selectable selectable) {
    final proxy = _members.remove(selectable);
    if (proxy == null) return;
    selectable.removeListener(changed);
    _parent?.remove(proxy);
    changed();
  }

  void dispose() {
    for (final member in _members.values.toList()) {
      member.removeListener(changed);
      _parent?.remove(member);
    }
    _members.clear();
    _parent = null;
  }
}

class _SentenceSelectable with Selectable {
  _SentenceSelectable(this.inner, this.offset, this.sentence);
  final Selectable inner;
  final int Function() offset;
  final TextRange? Function(int) sentence;
  @override
  SelectionGeometry get value => inner.value;
  @override
  Size get size => inner.size;
  @override
  List<Rect> get boundingBoxes => inner.boundingBoxes;
  @override
  int get contentLength => inner.contentLength;
  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      inner.getTransformTo(ancestor);
  @override
  void addListener(VoidCallback listener) => inner.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => inner.removeListener(listener);
  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) =>
      inner.pushHandleLayers(startHandle, endHandle);
  @override
  SelectedContent? getSelectedContent() => inner.getSelectedContent();
  @override
  SelectedContentRange? getSelection() {
    final selection = inner.getSelection();
    if (selection == null) return null;
    return SelectedContentRange(
      startOffset: (selection.startOffset - offset()).clamp(0, contentLength),
      endOffset: (selection.endOffset - offset()).clamp(0, contentLength),
    );
  }

  @override
  void dispose() {} // The actual renderer owns the underlying member.
  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final result = inner.dispatchSelectionEvent(event);
    if (event is! SelectWordSelectionEvent || result != SelectionResult.end) {
      return result;
    }
    final selected = getSelection();
    if (selected == null || selected.startOffset == selected.endOffset) {
      return result;
    }
    final range = sentence(selected.startOffset);
    if (range == null) return result;
    // Only a long press expands. Handle drags and later word/character events
    // are forwarded unchanged, including cross-paragraph auto-scrolling.
    for (final isEnd in [false, true]) {
      final target = isEnd ? range.end : range.start;
      for (var n = 0; n < contentLength; n++) {
        final current = getSelection();
        if (current == null) break;
        final edge = isEnd ? current.endOffset : current.startOffset;
        if (edge == target) break;
        inner.dispatchSelectionEvent(
          GranularlyExtendSelectionEvent(
            forward: target > edge,
            isEnd: isEnd,
            granularity: TextGranularity.character,
          ),
        );
        final next = getSelection();
        if (next == null ||
            (isEnd ? next.endOffset : next.startOffset) == edge) {
          break;
        }
      }
    }
    return result;
  }
}

/// Native range selection, with the app's existing glass material. No editable
/// field, keyboard request, note storage or per-paragraph gesture recognizers.
class ReaderSelection extends StatelessWidget {
  const ReaderSelection({
    super.key,
    required this.controller,
    required this.child,
    this.onSelect,
    this.vertical = false,
    this.onBookmark,
    this.onDictionary,
    this.onIllustrations,
  });
  final ReaderSelectionController controller;
  final Widget child;
  final VoidCallback? onSelect;
  final bool vertical;
  final ValueChanged<ReaderQuoteSelection>? onBookmark;
  final ValueChanged<ReaderQuoteSelection>? onDictionary;
  final VoidCallback? onIllustrations;
  @override
  Widget build(BuildContext context) {
    final readerTheme = Theme.of(context);
    final appearance = GlassAppearance.of(context);
    return SelectionArea(
      key: controller.key,
      onSelectionChanged: (content) {
        controller.text = content?.plainText ?? '';
        final active = controller.text.isNotEmpty;
        if (active && !controller.value) onSelect?.call();
        controller.value = active;
      },
      contextMenuBuilder: (context, region) {
        void action(ValueChanged<ReaderQuoteSelection> callback) {
          final selected = controller.quote;
          region.hideToolbar();
          if (selected.text.trim().isNotEmpty) callback(selected);
        }

        var anchors = region.contextMenuAnchors;
        final points = region.selectionEndpoints;
        if (vertical && points.length == 2) {
          final box = region.context.findRenderObject()! as RenderBox;
          final start = box.localToGlobal(points.first.point);
          final end = box.localToGlobal(points.last.point);
          final x = (start.dx + end.dx) / 2;
          anchors = TextSelectionToolbarAnchors(
            primaryAnchor: Offset(x, start.dy < end.dy ? start.dy : end.dy),
            secondaryAnchor: Offset(x, start.dy > end.dy ? start.dy : end.dy),
          );
        }
        return CustomSingleChildLayout(
          delegate: TextSelectionToolbarLayoutDelegate(
            anchorAbove: anchors.primaryAnchor - const Offset(0, 8),
            anchorBelow:
                (anchors.secondaryAnchor ?? anchors.primaryAnchor) +
                const Offset(0, 8),
          ),
          child: GlassAppearance(
            blur: appearance.blur,
            opacity: appearance.opacity,
            child: Theme(
              data: readerTheme,
              child: Material(
                type: MaterialType.transparency,
                child: GlassOverlaySurface(
                  key: const ValueKey('reader-selection-toolbar'),
                  preserveOptics: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width - 44,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final item in region.contextMenuButtonItems)
                              if (item.type == ContextMenuButtonType.copy)
                                _selectionAction(
                                  key: ValueKey(
                                    'reader-selection-${item.type.name}',
                                  ),
                                  icon: CupertinoIcons.doc_on_doc,
                                  label: '复制',
                                  onPressed: () async {
                                    final text = controller.quote.text;
                                    region.hideToolbar();
                                    try {
                                      await Clipboard.setData(
                                        ClipboardData(text: text),
                                      );
                                      controller.clear();
                                      if (context.mounted) {
                                        showNovelFeedback(context, '已复制');
                                      }
                                    } catch (_) {
                                      if (context.mounted) {
                                        showNovelFeedback(context, '复制失败，请重试');
                                      }
                                    }
                                  },
                                ),
                            if (onBookmark != null)
                              _selectionAction(
                                key: const ValueKey(
                                  'reader-selection-bookmark',
                                ),
                                icon: CupertinoIcons.bookmark,
                                label: '书签',
                                onPressed: () => action(onBookmark!),
                              ),
                            if (onDictionary != null)
                              _selectionAction(
                                key: const ValueKey(
                                  'reader-selection-dictionary',
                                ),
                                icon: CupertinoIcons.book,
                                label: '词典',
                                semanticLabel: '词典',
                                onPressed: () => action(onDictionary!),
                              ),
                            if (onIllustrations != null)
                              _selectionAction(
                                key: const ValueKey(
                                  'reader-selection-illustrations',
                                ),
                                icon: CupertinoIcons.photo,
                                label: '插图',
                                onPressed: () {
                                  region.hideToolbar();
                                  controller.clear();
                                  onIllustrations!();
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

Widget _selectionAction({
  required Key key,
  required IconData icon,
  required String label,
  required VoidCallback onPressed,
  String? semanticLabel,
}) => Semantics(
  button: true,
  label: semanticLabel ?? label,
  child: JellyTapSurface(
    key: key,
    onTap: onPressed,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArchiveIcon(icon, size: 20),
          const SizedBox(width: 8),
          AppText(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  ),
);
