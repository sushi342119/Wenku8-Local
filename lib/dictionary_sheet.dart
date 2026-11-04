import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_search_field.dart';
import 'app_ui.dart';
import 'app_interactions.dart';
import 'feature_pages.dart' show confirmNovelAction;
import 'book_documents.dart';
import 'dictionary_store.dart';
import 'reader_text_picker.dart';

String _formatLabel(String format) => switch (format) {
  'mobi' => 'MOBI',
  'stardict' => 'StarDict',
  _ => 'MDX',
};

/// Looks up the selection in-place; dictionary management is another sheet,
/// never a browser or a replacement reading page.
Future<void> showReaderDictionarySheet({
  required BuildContext context,
  required String word,
  DictionaryStore? store,
  bool reduceMotion = false,
  ReaderTextSegmentProvider? segmentProvider,
  Widget Function(Widget)? surfaceWrapper,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: reduceMotion,
  heightFactor: readerTextSheetHeightFactor(context, word),
  maxWidth: 640,
  surfaceWrapper: surfaceWrapper,
  builder: (_) => DictionaryLookupSheet(
    word: word,
    store: store ?? DictionaryStore.shared,
    reduceMotion: reduceMotion,
    segmentProvider: segmentProvider,
  ),
);

Future<void> showDictionaryManagementSheet({
  required BuildContext context,
  DictionaryStore? store,
  bool reduceMotion = false,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: reduceMotion,
  heightFactor: .82,
  maxWidth: 640,
  builder: (_) => DictionaryManagementSheet(
    store: store ?? DictionaryStore.shared,
    reduceMotion: reduceMotion,
  ),
);

/// The actual lookup surface is public for focused rendering/interaction checks.
class DictionaryLookupSheet extends StatefulWidget {
  const DictionaryLookupSheet({
    super.key,
    required this.word,
    required this.store,
    this.reduceMotion = false,
    this.segmentProvider,
  });
  final String word;
  final DictionaryStore store;
  final bool reduceMotion;
  final ReaderTextSegmentProvider? segmentProvider;
  @override
  State<DictionaryLookupSheet> createState() => _DictionaryLookupSheetState();
}

class _DictionaryLookupSheetState extends State<DictionaryLookupSheet> {
  final _query = TextEditingController();
  late String _sourceText = widget.word;
  TextRange? _pickedRange;
  Timer? _debounce;
  int _generation = 0;
  int? _session;
  bool _initializing = true, _picking = false;
  int _pickerGeneration = 0;
  String? _resultsQuery, _pickerReturnQuery;
  bool _busy = true, _loaded = false;
  bool _managing = false, _pendingLibraryChange = false;
  String? _error;
  List<DictionaryLookupGroup> _groups = const [];
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_libraryChanged);
    _initializeSelection();
  }

  Future<void> _initializeSelection() async {
    final generation = ++_generation;
    TextRange? single;
    if (_sourceText.length <= 512) {
      try {
        final ranges = await (widget.segmentProvider ?? readerTextWordSegments)(
          _sourceText,
        );
        if (ranges.length == 1) {
          final range = ranges.single;
          if (_sourceText.substring(0, range.start).trim().isEmpty &&
              _sourceText.substring(range.end).trim().isEmpty &&
              _sourceText
                      .substring(range.start, range.end)
                      .runes
                      .take(129)
                      .length <=
                  128) {
            single = range;
          }
        }
      } catch (_) {
        // A segmentation failure still leaves character/range selection usable.
      }
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _initializing = false;
      _picking = single == null;
      _busy = false;
      _pickedRange = single;
      if (single != null) {
        _query.text = _sourceText.substring(single.start, single.end);
      }
    });
    if (single != null) _search();
  }

  void _cancelPendingLookup() {
    ++_generation;
    _debounce?.cancel();
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(
        widget.store.cancelLookupSession(session).catchError((Object _) {}),
      );
    }
  }

  void _chooseFromText({String? source}) {
    _cancelPendingLookup();
    setState(() {
      _pickerReturnQuery = _resultsQuery;
      if (source != null && source != _sourceText) {
        _sourceText = source;
        _pickedRange = null;
      }
      ++_pickerGeneration;
      _initializing = false;
      _picking = true;
      _busy = false;
      _error = null;
    });
  }

  void _confirmText(TextRange range) {
    setState(() {
      _pickedRange = range;
      _query.text = _sourceText.substring(range.start, range.end).trim();
      _picking = false;
      _pendingLibraryChange = false;
    });
    _search();
  }

  void _cancelText() {
    if (_pickerReturnQuery == null) {
      Navigator.pop(context);
      return;
    }
    final refresh = _pendingLibraryChange;
    setState(() {
      _picking = false;
      _busy = false;
      _error = null;
      _query.text = _pickerReturnQuery!;
      _pendingLibraryChange = false;
    });
    if (refresh) _search();
  }

  void _libraryChanged() {
    if (_managing || _picking || _initializing) {
      _pendingLibraryChange = true;
      return;
    }
    _search();
  }

  Future<void> _search() async {
    if (_picking || _initializing) return;
    final query = _query.text.trim();
    if (query.runes.take(129).length > 128) {
      _chooseFromText(source: _query.text);
      return;
    }
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.load();
      if (!mounted || generation != _generation) return;
      final groups = await widget.store.lookup(
        query,
        session: _session ??= widget.store.createLookupSession(),
        generation: generation,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _groups = groups;
          _loaded = true;
          _resultsQuery = query;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _manage() async {
    if (_managing) return;
    _managing = true;
    try {
      await showDictionaryManagementSheet(
        context: context,
        store: widget.store,
        reduceMotion: widget.reduceMotion,
      );
    } finally {
      _managing = false;
      if (mounted && _pendingLibraryChange && !_picking && !_initializing) {
        _pendingLibraryChange = false;
        _search();
      }
    }
  }

  void _changed(String _) {
    ++_generation;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _search);
  }

  @override
  void dispose() {
    _cancelPendingLookup();
    widget.store.removeListener(_libraryChanged);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppText(
                _picking ? '选词查词' : '词典',
                style: const TextStyle(
                  fontSize: 20,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ArchiveIconButton(
              tooltip: '管理词典',
              onPressed: _manage,
              icon: const ArchiveIcon(
                CupertinoIcons.slider_horizontal_3,
                size: 22,
              ),
            ),
            ArchiveIconButton(
              tooltip: '关闭词典',
              onPressed: () => Navigator.pop(context),
              icon: const ArchiveIcon(CupertinoIcons.xmark, size: 20),
            ),
          ],
        ),
        if (!_picking && !_initializing) ...[
          const SizedBox(height: 8),
          AppSearchField(
            controller: _query,
            hint: '查词或短语',
            onChanged: _changed,
            onSubmitted: (_) => _search(),
            trailing: ArchiveIconButton(
              tooltip: '重新选词',
              onPressed: _chooseFromText,
              icon: const ArchiveIcon(CupertinoIcons.square_pencil, size: 19),
            ),
          ),
          const SizedBox(height: 12),
        ] else
          const SizedBox(height: 4),
        Expanded(
          child: _initializing
              ? const Center(child: CupertinoActivityIndicator())
              : _picking
              ? ReaderTextRangePicker(
                  key: ValueKey(('dictionary-text-picker', _pickerGeneration)),
                  text: _sourceText,
                  initialRange: _pickedRange,
                  confirmLabel: '查词',
                  maxSelectionRunes: 128,
                  segmentProvider: widget.segmentProvider,
                  onConfirm: _confirmText,
                  onCancel: _cancelText,
                )
              : _content(context),
        ),
      ],
    ),
  );
  Widget _content(BuildContext context) {
    if (_busy) return const Center(child: CupertinoActivityIndicator());
    if (_error != null) {
      return _DictionaryEmpty(
        message: _error!,
        action: '重试',
        onPressed: _search,
      );
    }
    if (_loaded && widget.store.dictionaries.isEmpty) {
      return _DictionaryEmpty(
        message: '导入自己的 MDX/MDD、StarDict 或 MOBI 词典后，即可离线查词。',
        action: '导入词典',
        onPressed: _manage,
      );
    }
    if (_query.text.trim().isEmpty) {
      return const Center(child: AppText('输入一个词语或短语'));
    }
    if (_groups.isEmpty) {
      return _DictionaryEmpty(
        message: '还没有启用的词典',
        action: '管理词典',
        onPressed: _manage,
      );
    }
    final matched = _groups
        .where((group) => group.definitions.isNotEmpty || group.error != null)
        .toList();
    if (matched.isEmpty) {
      return _DictionaryEmpty(
        message: '已查询 ${_groups.length} 部词典，未找到这个词条。',
        action: '管理词典',
        onPressed: _manage,
      );
    }
    return ListView.builder(
      key: const ValueKey('dictionary-aggregate-results'),
      itemCount: matched.length + 1,
      itemBuilder: (context, index) {
        if (index == matched.length) {
          final empty = _groups.length - matched.length;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: AppText(
              empty > 0 ? '另有 $empty 部词典未找到该词条' : '以上结果均来自本地词典',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final group = matched[index];
        final rank = _groups.indexOf(group) + 1;
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ArchiveSection(
                title: group.dictionary.name,
                code:
                    '${rank.toString().padLeft(2, '0')} / ${_formatLabel(group.dictionary.format).toUpperCase()}',
              ),
              const SizedBox(height: 14),
              if (group.error case final error?)
                AppText(
                  error,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    height: 1.5,
                  ),
                ),
              for (final definition in group.definitions) ...[
                if (definition.word != _query.text.trim())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppText(
                      definition.word,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                SelectableText(
                  definition.text.isEmpty ? '该词条没有可显示的文字。' : definition.text,
                  style: const TextStyle(fontSize: 15, height: 1.7),
                ),
                for (final image in definition.images)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Image.memory(
                      image,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const AppText('这张词典图片无法显示'),
                    ),
                  ),
                if (definition.resourceWarning)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: AppText(
                      group.dictionary.format == 'mobi'
                          ? 'MOBI 词典暂以文字显示释义，内嵌图片未显示。'
                          : '部分图片未能读取，请导入或检查同名 MDD 资源包。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (definition.related.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: definition.related
                          .map(
                            (word) => TextButton(
                              onPressed: () {
                                _query.text = word;
                                _search();
                              },
                              child: AppText(word),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One ordered library controls the priority in every reader lookup popup.
class DictionaryManagementSheet extends StatefulWidget {
  const DictionaryManagementSheet({
    super.key,
    required this.store,
    this.reduceMotion = false,
    this.documents,
  });
  final DictionaryStore store;
  final BookDocuments? documents;
  final bool reduceMotion;
  @override
  State<DictionaryManagementSheet> createState() =>
      _DictionaryManagementSheetState();
}

class _DictionaryManagementSheetState extends State<DictionaryManagementSheet> {
  late final _documents = widget.documents ?? BookDocuments();
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _perform(widget.store.load);
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _perform(() async {
    final selected = await _documents.pickDictionaryFiles();
    if (selected.isEmpty) return;
    try {
      final report = await widget.store.importFiles(selected);
      if (mounted) {
        if (report.imported.isNotEmpty) {
          showNovelFeedback(
            context,
            '已保存 ${report.imported.map((item) => item.id).toSet().length} 部词典，可离线查询',
          );
        }
        if (report.errors.isNotEmpty) {
          setState(() => _error = report.errors.take(8).join('\n'));
        }
      }
    } finally {
      await _documents.releaseBooks(selected);
    }
  });
  Future<void> _remove(UserDictionary dictionary) async {
    if (!await confirmNovelAction(
          context,
          title: '移除“${dictionary.name}”？',
          message: '只删除应用词典库中的副本和索引，原始词典文件保留。',
          confirmLabel: '移除词典',
          reduceMotion: widget.reduceMotion,
        ) ||
        !mounted) {
      return;
    }
    await _perform(() => widget.store.remove(dictionary.id));
  }

  Future<void> _rename(UserDictionary dictionary) async {
    var edited = dictionary.name;
    final name = await showJellySheet<String>(
      context: context,
      reduceMotion: widget.reduceMotion,
      maxHeight: 340,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '词典名称', code: 'LOCAL / NAME'),
            const SizedBox(height: 18),
            TextFormField(
              initialValue: dictionary.name,
              autofocus: true,
              maxLength: 160,
              onChanged: (value) => edited = value,
              onFieldSubmitted: (value) => Navigator.pop(sheet, value),
            ),
            const SizedBox(height: 12),
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, edited),
              child: const AppText('保存'),
            ),
          ],
        ),
      ),
    );
    if (mounted && name != null) {
      await _perform(() => widget.store.rename(dictionary.id, name));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: ArchiveSection(
                  title: '词典管理',
                  code: 'LOCAL / DICTIONARIES',
                ),
              ),
              ArchiveIconButton(
                tooltip: '关闭词典管理',
                onPressed: () => Navigator.pop(context),
                icon: const ArchiveIcon(CupertinoIcons.xmark, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const AppText(
            '拖动调整查询优先级。支持 MDX/MDD、StarDict、MOBI 词典或 ZIP，文件会复制到本地词典库。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 12),
          GlassTextButton(
            key: const ValueKey('dictionary-import'),
            onPressed: _busy ? null : _import,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_busy)
                  const CupertinoActivityIndicator()
                else
                  const ArchiveIcon(CupertinoIcons.plus, size: 18),
                const SizedBox(width: 10),
                AppText(_busy ? '正在准备词典…' : '导入词典'),
              ],
            ),
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AppText(
                error,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: widget.store.dictionaries.isEmpty
                ? const Center(
                    child: AppText('尚未导入词典', style: TextStyle(height: 1.6)),
                  )
                : ReorderableListView.builder(
                    key: const ValueKey('dictionary-priority-list'),
                    buildDefaultDragHandles: false,
                    itemCount: widget.store.dictionaries.length,
                    onReorder: (from, to) {
                      if (!_busy) {
                        _perform(() => widget.store.reorder(from, to));
                      }
                    },
                    proxyDecorator: (child, _, _) => Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: child,
                    ),
                    itemBuilder: (context, index) {
                      final item = widget.store.dictionaries[index];
                      return Container(
                        key: ValueKey(item.id),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            ReorderableDragStartListener(
                              index: index,
                              enabled: !_busy,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Semantics(
                                  label: '拖动调整${item.name}的优先级',
                                  child: const ArchiveIcon(
                                    CupertinoIcons.line_horizontal_3,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: InkWell(
                                onTap: _busy ? null : () => _rename(item),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AppText(
                                      item.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    AppText(
                                      '${index + 1} · ${_formatLabel(item.format)} · ${item.source.entries} 词条',
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.5,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    AppText(
                                      '${_size(item.bytes)} · ${item.enabled ? '已启用' : '已停用'}${item.resources.isEmpty ? '' : ' · ${item.resources.length} 个资源包'}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.5,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Semantics(
                              label: '启用${item.name}',
                              child: AppControls.toggle(
                                context,
                                value: item.enabled,
                                onChanged: _busy
                                    ? null
                                    : (value) => _perform(
                                        () => widget.store.setEnabled(
                                          item.id,
                                          value,
                                        ),
                                      ),
                              ),
                            ),
                            ArchiveIconButton(
                              tooltip: '移除${item.name}',
                              onPressed: _busy ? null : () => _remove(item),
                              icon: const ArchiveIcon(
                                CupertinoIcons.trash,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _DictionaryEmpty extends StatelessWidget {
  const _DictionaryEmpty({
    required this.message,
    required this.action,
    required this.onPressed,
  });
  final String message, action;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const ArchiveIcon(CupertinoIcons.book, size: 30),
        const SizedBox(height: 16),
        AppText(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(height: 1.65),
        ),
        const SizedBox(height: 18),
        GlassTextButton(onPressed: onPressed, child: AppText(action)),
      ],
    ),
  );
}

String _size(int bytes) => bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MiB'
    : '${(bytes / 1024).toStringAsFixed(1)} KiB';
String _message(Object error) => error is FormatException
    ? error.message
    : error is UnsupportedError
    ? error.message ?? '暂不支持这个词典格式'
    : '词典操作未完成，请重试';
