import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'app_ui.dart';
import 'app_interactions.dart';
import 'library_state.dart';

/// The whole settings row is tappable; its actual glass selector is the menu's
/// source. Labels and controls share the same responsive layout in the reader.
class GlassSettingMenu<T> extends StatefulWidget {
  const GlassSettingMenu({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.reduceMotion,
    this.semanticLabel,
  });
  final IconData icon;
  final String label;
  final String? semanticLabel;
  final T value;
  final Map<T, String> options;
  final FutureOr<void> Function(T) onChanged;
  final bool reduceMotion;
  @override
  State<GlassSettingMenu<T>> createState() => _GlassSettingMenuState<T>();
}

class _GlassSettingMenuState<T> extends State<GlassSettingMenu<T>> {
  final _anchor = GlobalKey();
  bool _saving = false;
  Future<void> _open() async {
    if (_saving) return;
    final source = _anchor.currentContext;
    if (source == null) return;
    final selected = await showGlassMenu<T>(
      context: source,
      reduceMotion: widget.reduceMotion,
      builder: (menu) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, entry) in widget.options.entries.indexed)
              GlassMenuItem(
                order: index,
                label: entry.value,
                selected: entry.key == widget.value,
                onPressed: () => Navigator.pop(menu, entry.key),
              ),
          ],
        ),
      ),
    );
    if (mounted && selected != null && selected != widget.value) {
      setState(() => _saving = true);
      try {
        await widget.onChanged(selected);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = ArchivePart(
      start: .18,
      end: .84,
      child: Row(
        children: [
          ArchiveIcon(widget.icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: AppText(
              widget.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    final selector = GlassMenuAnchor(
      child: Builder(
        key: _anchor,
        builder: (context) => LiquidGlass(
          radius: 20,
          elevated: false,
          semanticLabel: widget.semanticLabel ?? '选择${widget.label}',
          onTap: _saving ? null : _open,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: ArchivePart(
            start: .24,
            end: .88,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: AppText(
                    widget.options[widget.value] ?? '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 7),
                const ArchiveIcon(CupertinoIcons.chevron_down, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
    return JellyTapSurface(
      onTap: _saving ? null : _open,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          return constraints.maxWidth < 160 * scale + 70
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    label,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: selector),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 12),
                    // Short values use only their natural width instead of
                    // reserving two thirds of the row and wrapping its label.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .55,
                      ),
                      child: selector,
                    ),
                  ],
                );
        },
      ),
    );
  }
}

class LanguageSettingMenu extends StatelessWidget {
  const LanguageSettingMenu({super.key, required this.state});
  final LibraryState state;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.settingsChanges,
    builder: (context, _) => GlassSettingMenu<AppLanguage>(
      icon: CupertinoIcons.globe,
      label: '语言',
      value: state.language,
      options: {
        for (final language in AppLanguage.values) language: language.label,
      },
      reduceMotion: state.reduceMotion,
      onChanged: (value) async {
        try {
          await state.setLanguage(value);
        } catch (_) {
          if (context.mounted) showNovelFeedback(context, '语言设置保存失败，请重试');
        }
      },
    ),
  );
}
