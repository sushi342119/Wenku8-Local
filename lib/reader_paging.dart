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

enum ReaderTapAction {
  toggle,
  previous,
  next,
  previousChapter,
  nextChapter,
  toggleListening,
  addBookmark,
  none,
}

/// Centre 40 % toggles controls. With [ReaderPreferences.tapPaging] on, the
/// outer 30 % columns page:
/// * 常规: left = previous, right = next;
/// * 右手 / 左手: the thumb-side column is split, upper half previous and
///   lower half next; the far column always goes next;
/// * 九宫格: maps the 3x3 grid cell to [ReaderPreferences.effectiveTapGrid];
/// * [ReaderPreferences.tapBothSidesNext]: both columns go next;
/// * [ReaderPreferences.edgeDeadZone]: ignores taps within the curved-screen
///   dead-zone width on left and right edges.
ReaderTapAction readerTapAction(
  Offset position,
  Size size,
  ReaderPreferences prefs,
) {
  if (size.width <= 0) return ReaderTapAction.toggle;
  if (prefs.edgeDeadZone > 0 &&
      (position.dx < prefs.edgeDeadZone ||
          position.dx > size.width - prefs.edgeDeadZone)) {
    return ReaderTapAction.none;
  }
  if (!prefs.tapPaging) return ReaderTapAction.toggle;
  if (prefs.tapLayout == ReaderTapLayout.custom) {
    final col = (position.dx / size.width * 3).floor().clamp(0, 2);
    final row = size.height <= 0
        ? 1
        : (position.dy / size.height * 3).floor().clamp(0, 2);
    final zone = prefs.effectiveTapGrid[row * 3 + col];
    return switch (zone) {
      ReaderTapZoneAction.nextPage => ReaderTapAction.next,
      ReaderTapZoneAction.prevPage =>
        prefs.tapBothSidesNext ? ReaderTapAction.next : ReaderTapAction.previous,
      ReaderTapZoneAction.toggleMenu => ReaderTapAction.toggle,
      ReaderTapZoneAction.nextChapter => ReaderTapAction.nextChapter,
      ReaderTapZoneAction.prevChapter => ReaderTapAction.previousChapter,
      ReaderTapZoneAction.toggleListening => ReaderTapAction.toggleListening,
      ReaderTapZoneAction.addBookmark => ReaderTapAction.addBookmark,
      ReaderTapZoneAction.none => ReaderTapAction.none,
    };
  }
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
Widget readerPageBody(
  ReaderLeaf page,
  TextStyle style, {
  bool compressPunctuation = true,
}) {
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
                  compressPunctuation: compressPunctuation,
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

  void _cycleTapZone(BuildContext context, ReaderPreferences prefs, int cell) {
    final grid = List<ReaderTapZoneAction>.of(prefs.effectiveTapGrid);
    final current = grid[cell];
    final nextIndex =
        (ReaderTapZoneAction.values.indexOf(current) + 1) %
        ReaderTapZoneAction.values.length;
    grid[cell] = ReaderTapZoneAction.values[nextIndex];
    _save(context, prefs.copyWith(tapGrid: grid));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = state.readerPreferences;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    Widget toggle(
      String title,
      String note,
      bool value,
      Key key,
      ValueChanged<bool>? onChanged,
    ) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
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
          if (prefs.mode.paginated) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '翻页模式下，查找定位、听书跟随与划线显示请切回上下滚动使用。',
                style: muted,
              ),
            ),
            const SizedBox(height: 12),
            const Text('自动翻页', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            CupertinoSlidingSegmentedControl<ReaderAutoPageMode>(
              key: const ValueKey('reader-auto-page-mode'),
              groupValue: prefs.autoPageMode,
              children: {
                for (final mode in ReaderAutoPageMode.values)
                  mode: Text(mode.label),
              },
              onValueChanged: (mode) {
                if (mode != null) {
                  _save(context, prefs.copyWith(autoPageMode: mode));
                }
              },
            ),
            if (prefs.autoPageMode != ReaderAutoPageMode.off) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('推进速度', style: muted),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('reader-auto-page-speed'),
                      value: prefs.autoScrollSpeed.clamp(8.0, 80.0),
                      min: 8,
                      max: 80,
                      onChanged: (v) =>
                          _save(context, prefs.copyWith(autoScrollSpeed: v)),
                    ),
                  ),
                  Text(
                    '${(360 / prefs.autoScrollSpeed).round()}s/页',
                    style: muted,
                  ),
                ],
              ),
            ],
          ],
          toggle(
            '点击翻页',
            '左右各 30% 区域翻屏，中间区域切换控件，或自定义九宫格',
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
            if (prefs.tapLayout == ReaderTapLayout.custom) ...[
              const SizedBox(height: 8),
              Text('轻触下方九宫格方块即可切换该区域的点击动作：', style: muted),
              const SizedBox(height: 6),
              GridView.builder(
                key: const ValueKey('reader-tap-grid-editor'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 9,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 2.2,
                ),
                itemBuilder: (context, index) {
                  final zone = prefs.effectiveTapGrid[index];
                  return InkWell(
                    key: ValueKey('reader-tap-grid-cell-$index'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _cycleTapZone(context, prefs, index),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.55,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        zone.label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '曲面屏防误触边缘屏蔽',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        prefs.edgeDeadZone <= 0
                            ? '关闭（全宽响应点击）'
                            : '左右边缘各屏蔽 ${prefs.edgeDeadZone.round()} px',
                        style: muted,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: Slider(
                    key: const ValueKey('reader-edge-dead-zone-slider'),
                    value: prefs.edgeDeadZone.clamp(0.0, 48.0),
                    min: 0,
                    max: 48,
                    divisions: 12,
                    onChanged: (v) =>
                        _save(context, prefs.copyWith(edgeDeadZone: v)),
                  ),
                ),
              ],
            ),
          ),
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
