import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'chapter_splitter.dart' show TxtTocRulePreset;
import 'offline_cache.dart';

/// A bounded, lazy chapter picker using the existing glass drawer. The current
/// chapter is the scroll origin, so locating it never lays out earlier rows.
class ReaderCatalogue extends StatefulWidget {
  const ReaderCatalogue({
    super.key,
    required this.novel,
    required this.currentChapter,
    this.cache,
    this.onConfigureTocRule,
  });
  final Novel novel;
  final int currentChapter;
  final OfflineCacheStore? cache;
  final Future<Novel?> Function(String? customPattern, int maxChapterChars)?
  onConfigureTocRule;

  @override
  State<ReaderCatalogue> createState() => _ReaderCatalogueState();
}

class _ReaderCatalogueState extends State<ReaderCatalogue> {
  final _search = TextEditingController();
  final _customRegex = TextEditingController();
  final _scroll = ScrollController();
  final _center = GlobalKey();
  late Novel _novel = widget.novel;
  late List<int> _matches = _filter('');
  bool _configuringRule = false;
  bool _applyingRule = false;
  TxtTocRulePreset _selectedPreset = TxtTocRulePreset.auto;
  bool _subdivideOversized = false;
  String? _ruleError;

  List<int> _filter(String query) {
    final chapters = _novel.chapters;
    final text = query.trim().toLowerCase();
    if (text.isEmpty) return List.generate(chapters.length, (index) => index);
    final number = int.tryParse(text);
    if (number != null) {
      return number > 0 && number <= chapters.length ? [number - 1] : [];
    }
    return [
      for (var index = 0; index < chapters.length; index++)
        if (chapters[index].title.toLowerCase().contains(text) ||
            chapters[index].volume.toLowerCase().contains(text))
          index,
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

  Future<void> _applyTocRule() async {
    final callback = widget.onConfigureTocRule;
    if (callback == null || _applyingRule) return;
    final custom = _customRegex.text.trim();
    if (custom.isNotEmpty) {
      try {
        RegExp(custom, multiLine: true);
      } on FormatException catch (e) {
        setState(() => _ruleError = '正则表达式语法有误：${e.message}');
        return;
      }
    }
    setState(() {
      _applyingRule = true;
      _ruleError = null;
    });
    try {
      final pattern = custom.isNotEmpty ? custom : _selectedPreset.pattern;
      final updated = await callback(
        pattern,
        _subdivideOversized ? 12000 : 0,
      );
      if (!mounted) return;
      setState(() {
        if (updated != null) {
          _novel = updated;
          _matches = _filter(_search.text);
        }
        _configuringRule = false;
      });
      if (updated != null) {
        showNovelFeedback(context, '已按新规则切分为 ${updated.chapters.length} 章');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _ruleError = '重新切分目录失败，请检查规则后重试');
      }
    } finally {
      if (mounted) setState(() => _applyingRule = false);
    }
  }

  @override
  void didUpdateWidget(ReaderCatalogue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.novel.chapters, widget.novel.chapters)) {
      _novel = widget.novel;
      _matches = _filter(_search.text);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _customRegex.dispose();
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
            if (widget.onConfigureTocRule != null)
              GlassIconButton(
                key: const ValueKey('reader-catalogue-toc-rule'),
                icon: CupertinoIcons.slider_horizontal_3,
                label: 'TXT 分章规则',
                onPressed: () => setState(() {
                  _configuringRule = !_configuringRule;
                  _ruleError = null;
                }),
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
        if (_configuringRule && widget.onConfigureTocRule != null) ...[
          const SizedBox(height: 8),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'TXT 目录切分规则',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in TxtTocRulePreset.values)
                      ChoiceChip(
                        label: Text(
                          preset.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected:
                            _customRegex.text.trim().isEmpty &&
                            _selectedPreset == preset,
                        onSelected: (_) => setState(() {
                          _selectedPreset = preset;
                          _customRegex.clear();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('reader-catalogue-custom-regex'),
                  controller: _customRegex,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '自定义章节标题正则（选填，留空使用上方预设）',
                    isDense: true,
                  ),
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '超长章节自动分节（> 1.2 万字）',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    Switch.adaptive(
                      key: const ValueKey('reader-catalogue-subdivide-long'),
                      value: _subdivideOversized,
                      onChanged: (v) => setState(() => _subdivideOversized = v),
                    ),
                  ],
                ),
                if (_ruleError != null)
                  Text(
                    _ruleError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: GlassTextButton(
                    key: const ValueKey('reader-catalogue-apply-toc-rule'),
                    onPressed: _applyingRule ? null : _applyTocRule,
                    child: Text(_applyingRule ? '正在切分…' : '重新切分目录'),
                  ),
                ),
              ],
            ),
          ),
        ],
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
              ? '共 ${_novel.chapters.length} 章 · 当前第 ${widget.currentChapter + 1} 章'
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
    final chapter = _novel.chapters[index];
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (chapter.volume.isNotEmpty)
                      Text(chapter.volume, style: const TextStyle(fontSize: 11)),
                    Text(chapter.title, style: const TextStyle(fontSize: 14, height: 1.45)),
                  ],
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
