import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'library_state.dart';
import 'ui_preferences.dart';

/// The three visible controls own appearance; retired overrides are migrated
/// by LibraryState before settings are loaded or restored from a backup.
class AppearancePerformancePanel extends StatefulWidget {
  const AppearancePerformancePanel({super.key, required this.state});
  final LibraryState state;

  @override
  State<AppearancePerformancePanel> createState() =>
      _AppearancePerformancePanelState();
}

class _AppearancePerformancePanelState
    extends State<AppearancePerformancePanel> {
  bool _expanded = false;
  LibraryState get state => widget.state;

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) showNovelFeedback(context, '设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.settingsChanges,
    builder: (context, _) => _buildPanel(context),
  );

  Widget _buildPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glass = state.resolvedGlass;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return ContentPanel(
      key: const ValueKey('settings-appearance-performance'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              key: const ValueKey('appearance-performance-toggle'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '外观与性能',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '玻璃：${glass.automatic ? '自动·' : ''}${glass.tier.label}'
                            ' · 动效：${state.motionLevel.label}'
                            ' · 选书：${state.randomPickPace.label}',
                            key: const ValueKey(
                              'appearance-performance-summary',
                            ),
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 20),
            const Text('玻璃效果', style: TextStyle(fontWeight: FontWeight.w600)),
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
            const SizedBox(height: 12),
            const Text('动效', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            AppControls.segments<MotionLevel>(
              context,
              key: const ValueKey('motion-level-picker'),
              groupValue: state.motionLevel,
              children: {
                for (final level in MotionLevel.values)
                  level: Text(level.label),
              },
              onValueChanged: (level) {
                if (level != null) _save(() => state.setMotionLevel(level));
              },
            ),
            const SizedBox(height: 12),
            const Text('随机选书', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            AppControls.segments<RandomPickPace>(
              context,
              key: const ValueKey('random-pick-pace-picker'),
              groupValue: state.randomPickPace,
              children: {
                for (final pace in RandomPickPace.values)
                  pace: Text(pace.label),
              },
              onValueChanged: (pace) {
                if (pace != null) _save(() => state.setRandomPickPace(pace));
              },
            ),
          ],
        ],
      ),
    );
  }
}
