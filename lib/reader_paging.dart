import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_window_insets.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'reader_pagination.dart';
import 'reader_preferences.dart';
import 'reader_text.dart';
import 'reader_vertical_text.dart';

/// P3 bridge (design 2026-11 §4 阅读手势, decision 6): tap zones, volume-key
/// paging and the page body for the existing paged / vertical engine.

enum ReaderTapAction { toggle, previous, next }

/// Centre 40 % toggles controls. With [ReaderPreferences.tapPaging] on, the
/// outer 30 % columns page:
/// * 常规: left = previous, right = next;
/// * 右手 / 左手: the thumb-side column is split, upper half previous and
///   lower half next; the far column always goes next;
/// * [ReaderPreferences.tapBothSidesNext]: both columns go next.
ReaderTapAction readerTapAction(
  Offset position,
  Size size,
  ReaderPreferences prefs,
) {
  if (!prefs.tapPaging || size.width <= 0) return ReaderTapAction.toggle;
  final x = position.dx / size.width;
  final side = x < .3 ? -1 : (x > .7 ? 1 : 0);
  if (side == 0) return ReaderTapAction.toggle;
  if (prefs.tapBothSidesNext) return ReaderTapAction.next;
  final upper = size.height > 0 && position.dy < size.height / 2;
  return switch (prefs.tapLayout) {
    ReaderTapLayout.standard =>
      side < 0 ? ReaderTapAction.previous : ReaderTapAction.next,
    ReaderTapLayout.rightHand when side > 0 =>
      upper ? ReaderTapAction.previous : ReaderTapAction.next,
    ReaderTapLayout.leftHand when side < 0 =>
      upper ? ReaderTapAction.previous : ReaderTapAction.next,
    _ => ReaderTapAction.next,
  };
}

/// Enables volume-key paging on Android while mounted and the preference is
/// on. Reuses the existing native `ReaderControlsPlugin` (`apply` / `page`);
/// brightness stays on the system value and the status bar is not touched.
class ReaderVolumePaging extends StatefulWidget {
  const ReaderVolumePaging({
    super.key,
    required this.enabled,
    required this.onPage,
    required this.child,
  });
  final bool enabled;
  final ValueChanged<int> onPage;
  final Widget child;

  @override
  State<ReaderVolumePaging> createState() => _ReaderVolumePagingState();
}

class _ReaderVolumePagingState extends State<ReaderVolumePaging> {
  bool _applied = false;
  bool _handler = false;

  bool get _active => widget.enabled && LocalPlatform.volumePaging;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ReaderVolumePaging oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  void _sync() {
    final active = _active;
    if (active && !_handler) {
      _handler = true;
      AppWindowInsets.channel.setMethodCallHandler((call) async {
        if (call.method == 'page' && call.arguments is int && mounted) {
          widget.onPage(call.arguments as int);
        }
        return null;
      });
    } else if (!active && _handler) {
      _handler = false;
      AppWindowInsets.channel.setMethodCallHandler(null);
    }
    if (active == _applied) return;
    _applied = active;
    unawaited(_apply(active));
  }

  static Future<void> _apply(bool volumePaging) async {
    try {
      await AppWindowInsets.channel.invokeMethod<void>('apply', {
        'volumePaging': volumePaging,
        'brightness': -1.0,
        'hideStatusBar': false,
      });
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  @override
  void dispose() {
    if (_handler) AppWindowInsets.channel.setMethodCallHandler(null);
    if (_applied) unawaited(_apply(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One page of the paged engine. Horizontal fragments are re-laid at their
/// measured width with the same span builder pagination used, so line breaks
/// match; vertical pages draw with the existing [ReaderVerticalText].
Widget readerPageBody(ReaderLeaf page, TextStyle style) {
  if (page.vertical) return ReaderVerticalText(page: page, style: style);
  return Stack(
    clipBehavior: Clip.hardEdge,
    children: [
      for (final fragment in page.fragments)
        if (!fragment.image && !fragment.rule && fragment.text.isNotEmpty)
          Positioned.fromRect(
            rect: fragment.rect,
            child: ClipRect(
              child: Text.rich(
                readerParagraphSpan(
                  children: [TextSpan(text: fragment.text)],
                  style: style,
                  indent: fragment.indent,
                ),
                softWrap: true,
              ),
            ),
          ),
    ],
  );
}

/// 阅读方式 / 点击翻页 / 音量键翻页 in the TXT reader settings. Same
/// `readerPreferences` record as every other reader setting.
class ReaderPagingSettings extends StatelessWidget {
  const ReaderPagingSettings({super.key, required this.state});
  final LibraryState state;

  Future<void> _save(BuildContext context, ReaderPreferences next) async {
    try {
      await state.setReaderPreferences(next);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '阅读设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = state.readerPreferences;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    Widget toggle(String title, String note, bool value, Key key,
            ValueChanged<bool>? onChanged) =>
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(note, style: muted),
                  ],
                ),
              ),
              CupertinoSwitch(
                key: key,
                value: value,
                activeTrackColor: scheme.primary,
                onChanged: onChanged,
              ),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('阅读方式', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<ReaderMode>(
            key: const ValueKey('reader-mode-control'),
            groupValue: prefs.mode,
            children: {
              for (final mode in ReaderMode.values) mode: Text(mode.label),
            },
            onValueChanged: (mode) {
              if (mode != null && mode != prefs.mode) {
                _save(context, prefs.copyWith(mode: mode));
              }
            },
          ),
          if (prefs.mode.paginated)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('翻页模式下，查找定位、听书跟随与划线显示请切回上下滚动使用。',
                  style: muted),
            ),
          toggle(
            '点击翻页',
            '左右各 30% 区域翻屏，中间区域切换控件',
            prefs.tapPaging,
            const ValueKey('reader-tap-paging'),
            (value) => _save(context, prefs.copyWith(tapPaging: value)),
          ),
          if (prefs.tapPaging) ...[
            const SizedBox(height: 8),
            CupertinoSlidingSegmentedControl<ReaderTapLayout>(
              key: const ValueKey('reader-tap-layout'),
              groupValue: prefs.tapLayout,
              children: {
                for (final layout in ReaderTapLayout.values)
                  layout: Text(layout.label),
              },
              onValueChanged: (layout) {
                if (layout != null) {
                  _save(context, prefs.copyWith(tapLayout: layout));
                }
              },
            ),
          ],
          toggle(
            '音量键翻页',
            LocalPlatform.volumePaging ? '音量+ 上一屏，音量− 下一屏' : '当前平台不支持音量键翻页',
            prefs.volumePaging,
            const ValueKey('reader-volume-paging'),
            LocalPlatform.volumePaging
                ? (value) => _save(context, prefs.copyWith(volumePaging: value))
                : null,
          ),
        ],
      ),
    );
  }
}
