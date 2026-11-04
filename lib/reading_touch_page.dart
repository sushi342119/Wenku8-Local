import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'reading_touch_store.dart';

class ReadingTouchFingerprintEntry extends StatelessWidget {
  const ReadingTouchFingerprintEntry({super.key, this.reduceMotion = false});
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => FeatureEntry(
    key: const ValueKey('statistics-touch-fingerprint'),
    title: '触摸指纹',
    subtitle: '看看阅读时，指尖最常落在哪里',
    icon: CupertinoIcons.hand_draw,
    onTap: () => pushNovelPage<void>(
      context,
      const ReadingTouchPage(),
      reduceMotion: reduceMotion,
    ),
  );
}

class ReadingTouchPage extends StatelessWidget {
  const ReadingTouchPage({super.key, this.store});
  final ReadingTouchStore? store;

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '触摸指纹',
    code: 'READING / TOUCH MAP',
    child: ReadingTouchContent(store: store),
  );
}

/// The same controls and data view inside the statistics Dock or its own route.
class ReadingTouchContent extends StatefulWidget {
  const ReadingTouchContent({
    super.key,
    this.store,
    this.padding,
    this.controller,
  });
  final ReadingTouchStore? store;
  final EdgeInsets? padding;
  final ScrollController? controller;

  @override
  State<ReadingTouchContent> createState() => _ReadingTouchContentState();
}

class _ReadingTouchContentState extends State<ReadingTouchContent> {
  ReadingTouchStore get _store => widget.store ?? ReadingTouchStore.shared;
  ReadingTouchOrientation _orientation = ReadingTouchOrientation.portrait;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded().then((_) {
      if (!mounted) return;
      final snapshot = _store.snapshot;
      if (snapshot.portrait.total == 0 && snapshot.landscape.total > 0) {
        setState(() => _orientation = ReadingTouchOrientation.landscape);
      }
    });
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _busy = true);
    final success = await _store.setEnabled(value);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!success) showNovelFeedback(context, '设置未能保存，可重试');
  }

  Future<void> _clear() async {
    final confirmed = await confirmNovelAction(
      context,
      title: '清空触摸指纹？',
      message: '竖屏和横屏的触碰次数都会清空，阅读记录不受影响。',
      confirmLabel: '清空',
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final success = await _store.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!success) showNovelFeedback(context, '清空结果未能保存，请重试');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final snapshot = _store.snapshot;
      final grid = snapshot.grid(_orientation);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 712),
          child: ListView(
            controller: widget.controller,
            padding: widget.padding ?? featurePadding(context),
            children: [
              _TouchRecordingSettings(
                store: _store,
                busy: _busy,
                onChanged: _setEnabled,
              ),
              if (_store.error case final error?) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ArchiveIcon(
                      CupertinoIcons.info_circle,
                      size: 18,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppText(
                        error,
                        style: TextStyle(color: scheme.error, height: 1.5),
                      ),
                    ),
                    if (!_store.unreadable)
                      GlassTextButton(
                        compact: true,
                        onPressed: _busy ? null : _store.flush,
                        child: const AppText('重试'),
                      ),
                  ],
                ),
              ],
              if (snapshot.total > 0) ...[
                const SizedBox(height: 30),
                const ArchiveSection(
                  title: '指尖落点',
                  code: 'READING / FINGERPRINT',
                ),
                const SizedBox(height: 16),
                _TouchTotals(snapshot: snapshot),
                const SizedBox(height: 22),
                AppControls.segments<ReadingTouchOrientation>(
                  context,
                  key: const ValueKey('touch-orientation'),
                  groupValue: _orientation,
                  children: const {
                    ReadingTouchOrientation.portrait: AppText('竖屏'),
                    ReadingTouchOrientation.landscape: AppText('横屏'),
                  },
                  onValueChanged: (value) {
                    if (value != null) setState(() => _orientation = value);
                  },
                ),
                if (grid.total > 0) ...[
                  const SizedBox(height: 24),
                  _TouchPattern(grid: grid),
                ],
              ],
              if (snapshot.total > 0 || _store.unreadable) ...[
                const SizedBox(height: 24),
                GlassTextButton(
                  key: const ValueKey('touch-clear'),
                  onPressed: _busy || !_store.loaded ? null : _clear,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ArchiveIcon(CupertinoIcons.trash, size: 17),
                      const SizedBox(width: 8),
                      AppText(_store.unreadable ? '清空损坏记录' : '清空触摸记录'),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
    },
  );
}

class _TouchRecordingSettings extends StatelessWidget {
  const _TouchRecordingSettings({
    required this.store,
    required this.busy,
    required this.onChanged,
  });
  final ReadingTouchStore store;
  final bool busy;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final status = store.unreadable
        ? '记录暂不可用'
        : !store.loaded
        ? '正在读取'
        : store.enabled
        ? '记录已开启'
        : '记录已暂停';
    return ContentPanel(
      key: const ValueKey('touch-settings'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      status,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    AppText(
                      '正文触碰起点 · 本机累计',
                      style: TextStyle(color: muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Semantics(
                label: '记录触摸指纹',
                child: AppControls.toggle(
                  context,
                  key: const ValueKey('touch-recording-switch'),
                  value: store.enabled,
                  onChanged: busy || !store.loaded || store.unreadable
                      ? null
                      : onChanged,
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          AppText(
            '不受日期筛选，不保存轨迹、书名或正文，不随文库备份与同步。',
            style: TextStyle(color: muted, fontSize: 13, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _TouchTotals extends StatelessWidget {
  const _TouchTotals({required this.snapshot});
  final ReadingTouchSnapshot snapshot;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      final compact =
          constraints.maxWidth < 300 ||
          MediaQuery.textScalerOf(context).scale(14) > 18;
      final counter = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            key: const ValueKey('touch-total-fit'),
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: AppText(
              _number(snapshot.total),
              key: const ValueKey('touch-total'),
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                fontSize: 46,
                height: 1.05,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          AppText('累计触碰', style: TextStyle(color: muted)),
        ],
      );
      final started = snapshot.startedAt?.toLocal();
      final date = started == null
          ? null
          : AppText(
              '始于 ${started.year}.${started.month.toString().padLeft(2, '0')}.${started.day.toString().padLeft(2, '0')}',
              key: const ValueKey('touch-started-at'),
              style: TextStyle(color: muted, fontSize: 12),
            );
      return compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                counter,
                if (date != null) ...[const SizedBox(height: 8), date],
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: counter),
                if (date != null) ...[const SizedBox(width: 20), date],
              ],
            );
    },
  );
}

class _TouchPattern extends StatelessWidget {
  const _TouchPattern({required this.grid});
  final ReadingTouchGrid grid;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final map = _TouchHeatmap(grid: grid);
      final facts = _TouchFacts(grid: grid);
      if (constraints.maxWidth >= 600) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: grid.orientation == ReadingTouchOrientation.portrait
                  ? 230
                  : 320,
              child: map,
            ),
            const SizedBox(width: 36),
            Expanded(child: facts),
          ],
        );
      }
      return Column(children: [map, const SizedBox(height: 24), facts]);
    },
  );
}

class _TouchHeatmap extends StatelessWidget {
  const _TouchHeatmap({required this.grid});
  final ReadingTouchGrid grid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.primary;
    return Column(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: grid.orientation == ReadingTouchOrientation.portrait
                  ? 230
                  : 440,
            ),
            child: AspectRatio(
              aspectRatio: grid.columns / grid.rows,
              child: Semantics(
                image: true,
                label:
                    '${grid.orientation == ReadingTouchOrientation.portrait ? '竖屏' : '横屏'}触碰热图，${grid.total}次，${grid.busiestZone}区域最多',
                child: CustomPaint(
                  key: const ValueKey('touch-heatmap'),
                  painter: ReadingTouchHeatmapPainter(
                    grid: grid,
                    paper: scheme.surfaceContainerLow,
                    empty: scheme.onSurface.withValues(alpha: .045),
                    ink: ink,
                    border: scheme.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppText(
              '少',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            for (var i = 0; i < 5; i++)
              Container(
                width: 15,
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: Color.lerp(
                    scheme.surfaceContainerLow,
                    ink,
                    .12 + .2 * i,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            AppText(
              '多',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _TouchFacts extends StatelessWidget {
  const _TouchFacts({required this.grid});
  final ReadingTouchGrid grid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = grid.orientation == ReadingTouchOrientation.portrait
        ? '竖屏'
        : '横屏';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(
          '常驻${grid.busiestZone}',
          key: const ValueKey('touch-direction-facts'),
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        AppText(
          '$title ${_number(grid.total)} 次 · 覆盖 ${grid.occupied} / ${grid.cells.length} 格',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 22),
        _SideDistribution(grid: grid, ink: scheme.primary),
        const SizedBox(height: 18),
        AppText(
          '点击、滑动、长按都只计一次起点。颜色表示当前方向的相对频次。',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 13,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

String _number(int value) => value.toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+$)'),
  (match) => '${match[1]},',
);

class _SideDistribution extends StatelessWidget {
  const _SideDistribution({required this.grid, required this.ink});
  final ReadingTouchGrid grid;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final left = grid.left * 100 / grid.total;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            AppText('左半屏 ${left.round()}%'),
            AppText('右半屏 ${(100 - left).round()}%'),
          ],
        ),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: grid.left / grid.total,
            minHeight: 7,
            color: ink,
            backgroundColor: ink.withValues(alpha: .22),
          ),
        ),
      ],
    );
  }
}

class ReadingTouchHeatmapPainter extends CustomPainter {
  const ReadingTouchHeatmapPainter({
    required this.grid,
    required this.paper,
    required this.empty,
    required this.ink,
    required this.border,
  });
  final ReadingTouchGrid grid;
  final Color paper, empty, ink, border;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(22)),
      Paint()..color = paper,
    );
    final area = bounds.deflate(12);
    final cellWidth = area.width / grid.columns;
    final cellHeight = area.height / grid.rows;
    final peak = grid.peak;
    final scale = peak > 0 ? math.log(peak + 1) : 1.0;
    final paint = Paint();
    for (var i = 0; i < grid.cells.length; i++) {
      final count = grid.cells[i];
      paint.color = count == 0
          ? empty
          : Color.lerp(paper, ink, .15 + .85 * math.log(count + 1) / scale)!;
      final rect = Rect.fromLTWH(
        area.left + i % grid.columns * cellWidth,
        area.top + i ~/ grid.columns * cellHeight,
        cellWidth,
        cellHeight,
      ).deflate(1.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2.5)),
        paint,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds.deflate(.5), const Radius.circular(22)),
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant ReadingTouchHeatmapPainter oldDelegate) =>
      oldDelegate.grid != grid ||
      oldDelegate.paper != paper ||
      oldDelegate.ink != ink ||
      oldDelegate.empty != empty ||
      oldDelegate.border != border;
}
