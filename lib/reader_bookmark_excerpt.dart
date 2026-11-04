import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'library_state.dart';
import 'reader_mark_style.dart';

/// Shared quote/thought hierarchy for reader and library bookmark rows.
/// The surrounding page keeps ownership of its panel, metadata and actions.
class ReaderBookmarkExcerpt extends StatelessWidget {
  const ReaderBookmarkExcerpt({
    super.key,
    required this.mark,
    this.quoteMaxLines = 5,
    this.noteMaxLines = 3,
    this.compact = false,
  });

  final ReaderBookmark mark;
  final int quoteMaxLines, noteMaxLines;
  final bool compact;

  Widget _quote(BuildContext context) {
    final theme = Theme.of(context);
    final ink = readerMarkInk(
      mark.annotation.color,
      theme.colorScheme.onSurface,
      dark: theme.brightness == Brightness.dark,
    );
    return DecoratedBox(
      key: ValueKey('bookmark-quote-${mark.id}'),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: ink.withValues(alpha: .64), width: 2),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(left: compact ? 10 : 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: AppText(
                    compact ? '摘录' : '原文摘录',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AppText(
                      mark.kindLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: ink),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 4 : 8),
            AppText(
              mark.quote,
              maxLines: quoteMaxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 15 : 16,
                height: compact ? 1.5 : 1.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thought(BuildContext context) => compact
      ? Padding(
          key: ValueKey('bookmark-note-${mark.id}'),
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                '批注',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.8,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppText(
                  mark.note,
                  maxLines: noteMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ],
          ),
        )
      : Padding(
          key: ValueKey('bookmark-note-${mark.id}'),
          padding: const EdgeInsets.only(left: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppText(
                '个人批注',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 7),
              AppText(
                mark.note,
                maxLines: noteMaxLines,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 1.75),
              ),
            ],
          ),
        );

  @override
  Widget build(BuildContext context) => mark.quote.isEmpty && mark.note.isEmpty
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mark.quote.isNotEmpty) _quote(context),
            if (mark.quote.isNotEmpty && mark.note.isNotEmpty)
              SizedBox(height: compact ? 8 : 20),
            if (mark.note.isNotEmpty) _thought(context),
          ],
        );
}
