import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'reader_content.dart';

class ReaderMatch {
  const ReaderMatch(this.paragraph, this.start, this.end);
  final int paragraph;
  final int start;
  final int end;
}

class ReaderFindResult {
  const ReaderFindResult(this.matches, {this.truncated = false});
  final List<ReaderMatch> matches;
  final bool truncated;
}

ReaderFindResult _searchParagraphs(
  ({List<String> paragraphs, String query}) input,
) {
  final pattern = RegExp(
    RegExp.escape(input.query),
    caseSensitive: false,
    unicode: true,
  );
  final matches = <ReaderMatch>[];
  for (var index = 0; index < input.paragraphs.length; index++) {
    if (readerIllustrationUrl(input.paragraphs[index]) != null) continue;
    for (final match in pattern.allMatches(input.paragraphs[index])) {
      if (matches.length == 500) {
        return ReaderFindResult(List.unmodifiable(matches), truncated: true);
      }
      matches.add(ReaderMatch(index, match.start, match.end));
    }
  }
  return ReaderFindResult(List.unmodifiable(matches));
}

Future<ReaderFindResult> findInReader(
  ReaderContent content,
  String query,
) async {
  final term = query.trim();
  if (term.isEmpty || term.length > 120) return const ReaderFindResult([]);
  final input = (paragraphs: content.paragraphs, query: term);
  final length = content.paragraphs.fold<int>(
    0,
    (sum, text) => sum + text.length,
  );
  return length > 64 * 1024
      ? compute(_searchParagraphs, input)
      : _searchParagraphs(input);
}

class ReaderFindPanel extends StatefulWidget {
  const ReaderFindPanel({super.key, required this.content});
  final ReaderContent content;
  @override
  State<ReaderFindPanel> createState() => _ReaderFindPanelState();
}

class _ReaderFindPanelState extends State<ReaderFindPanel> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  bool _searching = false;
  ReaderFindResult _result = const ReaderFindResult([]);

  @override
  void initState() {
    super.initState();
    _query.addListener(_edited);
  }

  void _edited() {
    _debounce?.cancel();
    _generation++;
    if (!_query.value.composing.isCollapsed) return;
    if (_query.text.trim().isEmpty) {
      setState(() {
        _searching = false;
        _result = const ReaderFindResult([]);
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 180), _search);
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final generation = ++_generation;
    final result = await findInReader(widget.content, _query.text);
    if (mounted && generation == _generation) {
      setState(() {
        _result = result;
        _searching = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: math.min(520, MediaQuery.sizeOf(context).height * .64),
    child: CustomScrollView(
      key: const ValueKey('reader-find-scroll'),
      primary: false,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 8, 14, 8),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                const Expanded(
                  child: ArchiveSection(
                    title: '章内查找',
                    code: 'READER / TEXT QUERY',
                  ),
                ),
                GlassIconButton(
                  icon: CupertinoIcons.xmark,
                  label: '关闭章内查找',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CupertinoSearchTextField(
                  key: const ValueKey('reader-find-field'),
                  controller: _query,
                  borderRadius: BorderRadius.circular(
                    ArchiveDesign.panelRadius,
                  ),
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  placeholder: '查找当前章节文字',
                  onSubmitted: (_) => _search(),
                ),
                const SizedBox(height: 12),
                Text(
                  _searching
                      ? '正在查找…'
                      : _query.text.trim().isEmpty
                      ? '仅查找已加载的本章正文，点按结果跳到原文。'
                      : _query.text.trim().length > 120
                      ? '查找文字请控制在 120 字以内'
                      : _result.matches.isEmpty
                      ? '本章没有匹配文字'
                      : _result.truncated
                      ? '显示前 500 处匹配，请缩短查找范围'
                      : '${_result.matches.length} 处匹配',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!_searching)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            sliver: SliverList.builder(
              itemCount: _result.matches.length,
              itemBuilder: (context, index) {
                final match = _result.matches[index];
                final text = widget.content.paragraphs[match.paragraph];
                final start = math.max(0, match.start - 24);
                final end = math.min(text.length, match.end + 56);
                return JellyTapSurface(
                  key: ValueKey('reader-find-result-$index'),
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    Navigator.pop(context, match);
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
                          '第 ${match.paragraph + 1} 段 · ${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    '${start > 0 ? '…' : ''}${text.substring(start, match.start)}',
                              ),
                              TextSpan(
                                text: text.substring(match.start, match.end),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text:
                                    '${text.substring(match.end, end)}${end < text.length ? '…' : ''}',
                              ),
                            ],
                          ),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
}

/// Updating a match touches only the currently materialized lazy paragraphs.
/// Background tint changes no font metrics, line breaks, or glow/shadow layers.
class ReaderHighlightText extends StatelessWidget {
  const ReaderHighlightText({
    super.key,
    required this.index,
    required this.text,
    required this.match,
    required this.style,
  });
  final int index;
  final String text;
  final ValueListenable<ReaderMatch?> match;
  final TextStyle style;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ReaderMatch?>(
    valueListenable: match,
    builder: (context, selected, _) {
      if (selected == null ||
          selected.paragraph != index ||
          selected.end > text.length) {
        return Text(text, key: ValueKey('paragraph-$index'), style: style);
      }
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: text.substring(0, selected.start)),
            TextSpan(
              text: text.substring(selected.start, selected.end),
              style: TextStyle(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .14),
              ),
            ),
            TextSpan(text: text.substring(selected.end)),
          ],
        ),
        key: ValueKey('paragraph-$index'),
        style: style,
      );
    },
  );
}
