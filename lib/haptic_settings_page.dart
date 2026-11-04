import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'haptic_preferences.dart';
import 'library_state.dart';

/// App-level tactile controls, with one tactile preview per saved change.
class HapticSettingsPage extends StatefulWidget {
  const HapticSettingsPage({super.key, required this.state});

  final LibraryState state;

  @override
  State<HapticSettingsPage> createState() => _HapticSettingsPageState();
}

class _HapticSettingsPageState extends State<HapticSettingsPage>
    with WidgetsBindingObserver {
  bool _saving = false;
  Map<Object?, Object?>? _capabilities;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCapabilities();
  }

  void _loadCapabilities() {
    AppHaptics.capabilities().then((value) {
      if (mounted) setState(() => _capabilities = value);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadCapabilities();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _canAdjustStrength => _capabilities?['hasAmplitudeControl'] != false;

  bool get _canPreview =>
      _capabilities?['hasVibrator'] != false &&
      _capabilities?['hapticFeedbackEnabled'] != false;

  Future<void> _save(
    HapticPreferences preferences, {
    HapticCategory? preview,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.state.setHaptics(preferences);
      if (mounted && preview != null) _preview(preview);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '振动设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _preview(HapticCategory category) =>
      AppHaptics.preview(context, switch (category) {
        HapticCategory.controls => HapticCue.action,
        HapticCategory.shelf => HapticCue.shelfStep,
        HapticCategory.reading => HapticCue.pageTurn,
        HapticCategory.adjustment => HapticCue.detent,
        HapticCategory.longPress => HapticCue.longPress,
        HapticCategory.boundary => HapticCue.boundary,
        HapticCategory.result => HapticCue.success,
      }, preferences: widget.state.haptics);

  HapticCategory? _firstEnabled(HapticPreferences preferences) {
    for (final category in HapticCategory.values) {
      if (preferences.levelFor(category) != null) return category;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state.settingsChanges,
    builder: (context, _) {
      final preferences = widget.state.haptics;
      final padding = MediaQuery.paddingOf(context);
      return Scaffold(
        body: Atmosphere(
          child: GlassHeaderLayout(
            header: ArchiveHeaderBar(
              leading: GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回性能与动效',
                onPressed: () => Navigator.pop(context),
              ),
              title: const ArchiveRouteTitle(
                title: '振动反馈',
                code: 'SYSTEM / HAPTICS',
              ),
            ),
            body: ListView(
              key: const ValueKey('haptic-settings-scroll'),
              padding: EdgeInsets.fromLTRB(
                24 + padding.left,
                padding.top + FrostedHeader.toolbarHeight + 20,
                24 + padding.right,
                padding.bottom + 32,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 712),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ContentPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _toggleRow(
                                title: '振动反馈',
                                description: '关闭后保留各项设置',
                                switchKey: 'haptic-global-enabled',
                                value: preferences.enabled,
                                onChanged: _saving
                                    ? null
                                    : (enabled) {
                                        final next = preferences.withEnabled(
                                          enabled,
                                        );
                                        return _save(
                                          next,
                                          preview: enabled
                                              ? _firstEnabled(next)
                                              : null,
                                        );
                                      },
                              ),
                              const Divider(height: 28),
                              Row(
                                children: [
                                  const Expanded(child: AppText('全部强度')),
                                  if (preferences.uniformStrength == null)
                                    AppText('已分别设置', style: _supportingStyle),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _allStrengthPicker(preferences),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _capabilityNote,
                        const SizedBox(height: 24),
                        AppText(
                          '按交互调整',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        ContentPanel(
                          child: Column(
                            children: [
                              for (final category in HapticCategory.values) ...[
                                if (category != HapticCategory.values.first)
                                  const Divider(height: 32),
                                _category(category, preferences),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  TextStyle get _supportingStyle => TextStyle(
    fontSize: 13,
    height: 1.45,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  Widget get _capabilityNote {
    final caps = _capabilities;
    if (caps == null) {
      return AppText('实际强度随设备和系统设置调整。', style: _supportingStyle);
    }
    if (caps['hasVibrator'] == false) {
      return AppText('此设备没有可用的振动马达。', style: _supportingStyle);
    }
    if (caps['hapticFeedbackEnabled'] == false) {
      return AppText('系统已关闭触摸反馈；请在系统设置中开启后再试振。', style: _supportingStyle);
    }
    if (caps['hasAmplitudeControl'] == false) {
      return AppText('此设备使用系统固定强度，可开关反馈和试振。', style: _supportingStyle);
    }
    if (caps['hasAmplitudeControl'] != true) {
      return AppText(
        caps['supportsIntensityRequest'] == true
            ? '强度偏好交由系统执行，部分设备可能使用固定强度。'
            : '实际强度随设备和系统设置调整。',
        style: _supportingStyle,
      );
    }
    return AppText('设备支持振幅控制；实际强度仍受系统设置和硬件调校影响。', style: _supportingStyle);
  }

  Widget _allStrengthPicker(HapticPreferences preferences) => Row(
    key: const ValueKey('haptic-all-strength'),
    children: [
      for (final strength in HapticStrength.values) ...[
        if (strength != HapticStrength.values.first) const SizedBox(width: 8),
        Expanded(
          child: GlassTextButton(
            compact: true,
            selected: preferences.uniformStrength == strength,
            haptic: null,
            onPressed: !preferences.enabled || _saving || !_canAdjustStrength
                ? null
                : () {
                    if (preferences.uniformStrength == strength) return;
                    final next = preferences.withStrength(strength);
                    _save(next, preview: _firstEnabled(next));
                  },
            child: AppText(strength.label),
          ),
        ),
      ],
    ],
  );

  Widget _category(HapticCategory category, HapticPreferences preferences) {
    final setting = preferences.forCategory(category);
    final active = preferences.enabled && setting.enabled && !_saving;
    final systemStrength =
        defaultTargetPlatform == TargetPlatform.iOS &&
        category == HapticCategory.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toggleRow(
          title: category.label,
          description: category.description,
          switchKey: 'haptic-${category.name}-enabled',
          value: setting.enabled,
          onChanged: !preferences.enabled || _saving
              ? null
              : (enabled) => _save(
                  preferences.withCategoryEnabled(category, enabled),
                  preview: enabled ? category : null,
                ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: systemStrength
                  ? AppText('强度由系统控制', style: _supportingStyle)
                  : _strengthPicker(
                      pickerKey: 'haptic-${category.name}-strength',
                      value: setting.strength,
                      enabled: active && _canAdjustStrength,
                      onChanged: (strength) => _save(
                        preferences.withCategoryStrength(category, strength),
                        preview: category,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            GlassTextButton(
              key: ValueKey('haptic-${category.name}-preview'),
              compact: true,
              haptic: null,
              onPressed: active && _canPreview
                  ? () => _preview(category)
                  : null,
              child: const AppText('试振'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _strengthPicker({
    required String pickerKey,
    required HapticStrength? value,
    required bool enabled,
    required ValueChanged<HapticStrength> onChanged,
  }) => AppControls.segments<HapticStrength>(
    context,
    key: ValueKey(pickerKey),
    groupValue: value,
    haptics: false,
    disabledChildren: enabled ? const {} : HapticStrength.values.toSet(),
    children: {
      for (final strength in HapticStrength.values)
        strength: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: AppText(strength.label),
        ),
    },
    onValueChanged: (strength) {
      if (enabled && strength != null && strength != value) onChanged(strength);
    },
  );

  Widget _toggleRow({
    required String title,
    required String description,
    required String switchKey,
    required bool value,
    required Future<void> Function(bool)? onChanged,
  }) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            AppText(description, style: _supportingStyle),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Semantics(
        label: title,
        child: AppControls.toggle(
          context,
          key: ValueKey(switchKey),
          value: value,
          onChanged: onChanged,
          haptics: false,
        ),
      ),
    ],
  );
}
