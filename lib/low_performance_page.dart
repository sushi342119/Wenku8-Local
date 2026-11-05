import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_state.dart';
import 'performance_preferences.dart';

class LowPerformancePage extends StatefulWidget {
  const LowPerformancePage({super.key, required this.state});
  final LibraryState state;
  @override
  State<LowPerformancePage> createState() => _LowPerformancePageState();
}

class _LowPerformancePageState extends State<LowPerformancePage> {
  bool _saving = false;

  Future<void> _save(PerformancePreferences preferences) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.state.setPerformance(preferences);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '性能设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state.settingsChanges,
    builder: (context, _) {
      final preferences = widget.state.performance;
      return Scaffold(
        body: Atmosphere(
          child: GlassHeaderLayout(
            header: Row(
              children: [
                GlassIconButton(
                  icon: CupertinoIcons.back,
                  label: '返回设置',
                  onPressed: () => Navigator.pop(context),
                ),
                const Expanded(
                  child: ArchiveRouteTitle(
                    title: '自定义效果',
                    code: 'APPEARANCE / CUSTOM',
                  ),
                ),
              ],
            ),
            body: ListView(
              key: const ValueKey('performance-options-scroll'),
              padding: EdgeInsets.fromLTRB(
                24 + MediaQuery.paddingOf(context).left,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24 + MediaQuery.paddingOf(context).right,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                ContentPanel(
                  child: _option(
                    title: '在玻璃档位上进一步限制',
                    description: preferences.enabled
                        ? '已启用：只保留下面开启的效果，其余按“关”处理。'
                        : '关闭时完全按玻璃档位显示；开启后可逐项关闭效果。',
                    value: preferences.enabled,
                    switchKey: 'low-performance-mode',
                    onChanged: _saving
                        ? null
                        : (value) => _save(preferences.withEnabled(value)),
                  ),
                ),
                const SizedBox(height: 24),
                Text('保留的效果', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  '开启的效果越少，图形开销越低。正文、书签、缓存和听书功能保持不变。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                ContentPanel(
                  child: Column(
                    children: [
                      for (final effect in PerformanceEffect.values) ...[
                        if (effect != PerformanceEffect.values.first)
                          const Divider(height: 28),
                        _option(
                          title: effect.label,
                          description: effect.description,
                          value: preferences.allows(effect),
                          switchKey: effect.preferenceKey,
                          onChanged: !preferences.enabled || _saving
                              ? null
                              : (value) => _save(
                                  preferences.withEffect(effect, value),
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                GlassTextButton(
                  key: const ValueKey('performance-light-preset'),
                  onPressed: _saving || !preferences.enabled
                      ? null
                      : () =>
                            _save(const PerformancePreferences(enabled: true)),
                  child: const Text('恢复轻量预设'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _option({
    required String title,
    required String description,
    required bool value,
    required String switchKey,
    required ValueChanged<bool>? onChanged,
  }) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              description,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Semantics(
        label: title,
        child: CupertinoSwitch(
          key: ValueKey(switchKey),
          value: value,
          activeTrackColor: Theme.of(context).colorScheme.primary,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}
