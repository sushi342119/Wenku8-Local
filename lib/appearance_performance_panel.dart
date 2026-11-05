import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_state.dart';
import 'low_performance_page.dart';
import 'ui_preferences.dart';

/// "外观与性能": the four glass tiers and the motion level are the first
/// controls. The v1.7.1 sliders sit under "高级" and the five low-performance
/// switches under "自定义"; both keep their original preference keys.
class AppearancePerformancePanel extends StatefulWidget {
  const AppearancePerformancePanel({super.key, required this.state});
  final LibraryState state;

  @override
  State<AppearancePerformancePanel> createState() =>
      _AppearancePerformancePanelState();
}

class _AppearancePerformancePanelState
    extends State<AppearancePerformancePanel> {
  bool _advancedOpen = false;
  LibraryState get state => widget.state;

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) showNovelFeedback(context, '设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(
      fontSize: 12,
      height: 1.45,
      color: scheme.onSurfaceVariant,
    );
    final glass = state.resolvedGlass;
    final custom = state.performance.enabled;
    final sourceText = glass.automatic
        ? '自动选择：${glass.tier.label}'
              '（${state.deviceProfile.lowEnd ? '检测为低内存或 Android 10 及以下' : '按本机性能'}）'
        : '手动选择：${glass.tier.label}';
    return ContentPanel(
      key: const ValueKey('settings-appearance-performance'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('玻璃效果', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(sourceText, key: const ValueKey('glass-tier-source'), style: muted),
          const SizedBox(height: 8),
          AppControls.segments<GlassTier>(
            context,
            key: const ValueKey('glass-tier-picker'),
            groupValue: glass.tier,
            children: {
              for (final tier in GlassTier.values) tier: Text(tier.label),
            },
            onValueChanged: (tier) {
              if (tier != null) _save(() => state.setGlassTier(tier));
            },
          ),
          if (!glass.automatic)
            Align(
              alignment: Alignment.centerLeft,
              child: GlassTextButton(
                key: const ValueKey('glass-tier-auto'),
                compact: true,
                onPressed: () => _save(() => state.setGlassTier(null)),
                child: const Text('恢复自动选择'),
              ),
            ),
          Text(
            '阅读页不受此档位影响：控件隐藏时不做模糊，显示时最多 σ4。',
            style: muted,
          ),
          const Divider(height: 28),
          const Text('动效', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('轻：缩短后的时长；标准：v1.7.1 时长；关：只保留 100ms 淡入淡出。', style: muted),
          const SizedBox(height: 8),
          AppControls.segments<MotionLevel>(
            context,
            key: const ValueKey('motion-level-picker'),
            groupValue: state.motionLevel,
            children: {
              for (final level in MotionLevel.values) level: Text(level.label),
            },
            onValueChanged: (level) {
              if (level != null) _save(() => state.setMotionLevel(level));
            },
          ),
          const SizedBox(height: 12),
          const Text('随机选书', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('快速 900ms（洗牌 400 + 翻牌 500）；仪式 2400ms。', style: muted),
          const SizedBox(height: 8),
          AppControls.segments<RandomPickPace>(
            context,
            key: const ValueKey('random-pick-pace-picker'),
            groupValue: state.randomPickPace,
            children: {
              for (final pace in RandomPickPace.values) pace: Text(pace.label),
            },
            onValueChanged: (pace) {
              if (pace != null) _save(() => state.setRandomPickPace(pace));
            },
          ),
          const Divider(height: 28),
          _row(
            context,
            key: const ValueKey('settings-performance'),
            icon: CupertinoIcons.slider_horizontal_3,
            title: '自定义',
            subtitle: custom
                ? '已限制部分效果，在档位基础上进一步关闭'
                : '按效果逐项关闭（折射、模糊、边缘模糊、动效、立体书架）',
            onTap: () => pushNovelPage<void>(
              context,
              LowPerformancePage(state: state),
              reduceMotion: state.reduceMotion,
            ),
          ),
          const Divider(height: 18),
          _row(
            context,
            key: const ValueKey('glass-advanced-toggle'),
            icon: _advancedOpen
                ? CupertinoIcons.chevron_up
                : CupertinoIcons.chevron_down,
            title: '高级',
            subtitle: state.glassAdvanced
                ? '正在使用自定模糊度与不透明度'
                : '手动调节模糊度与不透明度（会覆盖档位值）',
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
          ),
          if (_advancedOpen) ..._advanced(context, muted),
        ],
      ),
    );
  }

  List<Widget> _advanced(BuildContext context, TextStyle muted) => [
    const SizedBox(height: 8),
    _label(context, '模糊度', '${state.glassBlur.round()}'),
    CupertinoSlider(
      key: const ValueKey('glass-blur-slider'),
      value: state.glassBlur,
      min: 0,
      max: 24,
      divisions: 24,
      activeColor: Theme.of(context).colorScheme.primary,
      onChanged: (value) => state.setGlassBlur(value, persist: false),
      onChangeEnd: state.setGlassBlur,
    ),
    const SizedBox(height: 8),
    _label(
      context,
      '不透明度',
      '${(state.glassOpacity * 100).round()}%',
    ),
    CupertinoSlider(
      key: const ValueKey('glass-opacity-slider'),
      value: state.glassOpacity,
      min: 0,
      max: 1,
      divisions: 100,
      activeColor: Theme.of(context).colorScheme.primary,
      onChanged: (value) => state.setGlassOpacity(value, persist: false),
      onChangeEnd: state.setGlassOpacity,
    ),
    if (state.resolvedGlass.tier == GlassTier.off)
      Text('当前档位为“关”，滑杆数值保留但不生效。', style: muted),
    Align(
      alignment: Alignment.centerLeft,
      child: GlassTextButton(
        key: const ValueKey('glass-advanced-reset'),
        compact: true,
        onPressed: state.glassAdvanced
            ? () => _save(() => state.setGlassAdvanced(false))
            : null,
        child: const Text('恢复档位默认值'),
      ),
    ),
  ];

  Widget _label(BuildContext context, String title, String value) => Row(
    children: [
      Expanded(
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      Text(
        value,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  Widget _row(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Semantics(
    button: true,
    child: InkWell(
      key: key,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
