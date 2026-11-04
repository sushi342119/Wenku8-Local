import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_ui.dart';

@immutable
class ReaderPurificationRule {
  const ReaderPurificationRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = false,
    this.enabled = false,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;
  final bool builtIn;

  ReaderPurificationRule copyWith({
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
  }) => ReaderPurificationRule(
    id: id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    isRegex: isRegex ?? this.isRegex,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
  );

  String apply(String input) {
    if (!enabled || pattern.isEmpty || input.isEmpty) return input;
    if (!isRegex) {
      return input.replaceAll(pattern, replacement);
    }
    try {
      final regExp = RegExp(pattern, multiLine: true);
      return input.replaceAll(regExp, replacement);
    } on FormatException {
      return input;
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'isRegex': isRegex,
    'enabled': enabled,
    'builtIn': builtIn,
  };

  static ReaderPurificationRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final pattern = raw['pattern'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.isEmpty ||
        pattern is! String ||
        pattern.isEmpty) {
      return null;
    }
    return ReaderPurificationRule(
      id: id,
      name: name,
      pattern: pattern,
      replacement: raw['replacement'] is String
          ? raw['replacement'] as String
          : '',
      isRegex: raw['isRegex'] == true,
      enabled: raw['enabled'] == true,
      builtIn: raw['builtIn'] == true,
    );
  }
}

class ReaderPurificationStore extends ChangeNotifier {
  ReaderPurificationStore._();

  static final ReaderPurificationStore shared = ReaderPurificationStore._();
  static const String preferenceKey = 'reader_purification_rules_v1';

  static const List<ReaderPurificationRule> builtInPresets = [
    ReaderPurificationRule(
      id: 'builtin_ocr_ellipsis',
      name: '规范省略号（... → ……）',
      pattern: r'\.{3,}|…{3,}',
      replacement: '……',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_ocr_dash',
      name: '规范破折号（-- / ——）',
      pattern: r'-{2,}|—{3,}',
      replacement: '——',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_trailing_spaces',
      name: '清理段尾多余空格',
      pattern: r'[ \t\u3000]+$',
      replacement: '',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_watermark_credit',
      name: '过滤常见扫图/转载免责声明行',
      pattern: r'^(?:.*(?:仅供个人学习交流|严禁用于商业用途|下载后请于24小时内删除).*)$',
      replacement: '',
      isRegex: true,
      enabled: false,
      builtIn: true,
    ),
  ];

  List<ReaderPurificationRule> _rules = [...builtInPresets];
  bool _loaded = false;

  List<ReaderPurificationRule> get rules => List.unmodifiable(_rules);

  bool get hasEnabledRules => _rules.any((rule) => rule.enabled);

  int get enabledCount => _rules.where((rule) => rule.enabled).length;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final parsed = <ReaderPurificationRule>[
        for (final item in decoded) ?ReaderPurificationRule.fromJson(item),
      ];
      final byId = {for (final r in parsed) r.id: r};
      final merged = <ReaderPurificationRule>[
        for (final preset in builtInPresets)
          preset.copyWith(enabled: byId[preset.id]?.enabled ?? preset.enabled),
        for (final custom in parsed)
          if (!custom.builtIn &&
              !builtInPresets.any((preset) => preset.id == custom.id))
            custom,
      ];
      _rules = merged;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode([for (final r in _rules) r.toJson()]);
      await prefs.setString(preferenceKey, encoded);
    } catch (_) {}
  }

  Future<void> toggleRule(String id, bool enabled) async {
    await ensureLoaded();
    _rules = [
      for (final rule in _rules)
        if (rule.id == id) rule.copyWith(enabled: enabled) else rule,
    ];
    notifyListeners();
    await _persist();
  }

  Future<void> addCustomRule({
    required String name,
    required String pattern,
    required String replacement,
    required bool isRegex,
  }) async {
    await ensureLoaded();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || pattern.isEmpty) return;
    final id = 'custom_${DateTime.now().microsecondsSinceEpoch}';
    _rules = [
      ..._rules,
      ReaderPurificationRule(
        id: id,
        name: trimmedName,
        pattern: pattern,
        replacement: replacement,
        isRegex: isRegex,
        enabled: true,
      ),
    ];
    notifyListeners();
    await _persist();
  }

  Future<void> removeRule(String id) async {
    await ensureLoaded();
    _rules = [
      for (final rule in _rules)
        if (rule.id != id || rule.builtIn) rule,
    ];
    notifyListeners();
    await _persist();
  }

  String purifyParagraph(String text) {
    if (!hasEnabledRules || text.isEmpty) return text;
    final trimmed = text.trim();
    if (trimmed == '[插图]' || trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return text;
    }
    var current = text;
    for (final rule in _rules) {
      if (rule.enabled) {
        current = rule.apply(current);
      }
    }
    return current;
  }
}

Future<void> showReaderPurificationSheet({
  required BuildContext context,
  bool reduceMotion = false,
}) async {
  await ReaderPurificationStore.shared.ensureLoaded();
  if (!context.mounted) return;
  await showJellySheet<void>(
    context: context,
    reduceMotion: reduceMotion,
    builder: (sheetContext) => _ReaderPurificationSheet(
      reduceMotion: reduceMotion,
    ),
  );
}

class _ReaderPurificationSheet extends StatefulWidget {
  const _ReaderPurificationSheet({required this.reduceMotion});
  final bool reduceMotion;

  @override
  State<_ReaderPurificationSheet> createState() =>
      _ReaderPurificationSheetState();
}

class _ReaderPurificationSheetState extends State<_ReaderPurificationSheet> {
  final _nameCtrl = TextEditingController();
  final _patternCtrl = TextEditingController();
  final _replacementCtrl = TextEditingController();
  bool _isRegex = false;
  bool _adding = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitCustomRule() async {
    final name = _nameCtrl.text.trim();
    final pattern = _patternCtrl.text;
    final replacement = _replacementCtrl.text;
    if (name.isEmpty || pattern.isEmpty) {
      setState(() => _error = '请填写规则名称与匹配内容');
      return;
    }
    if (_isRegex) {
      try {
        RegExp(pattern, multiLine: true);
      } on FormatException catch (e) {
        setState(() => _error = '正则表达式语法有误：${e.message}');
        return;
      }
    }
    await ReaderPurificationStore.shared.addCustomRule(
      name: name,
      pattern: pattern,
      replacement: replacement,
      isRegex: _isRegex,
    );
    if (!mounted) return;
    setState(() {
      _nameCtrl.clear();
      _patternCtrl.clear();
      _replacementCtrl.clear();
      _isRegex = false;
      _adding = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = ReaderPurificationStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final rules = store.rules;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '正文替换与净化规则',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    GlassTextButton(
                      key: const ValueKey('purification-toggle-add'),
                      onPressed: () => setState(() {
                        _adding = !_adding;
                        _error = null;
                      }),
                      child: Text(_adding ? '收起新建' : '新增规则'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '支持轻小说常用标点净化与自定义正则替换，仅在阅读渲染时生效，不修改原书文件。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_adding) ...[
                  const SizedBox(height: 14),
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            labelText: '规则名称（如：修正人名译名）',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _patternCtrl,
                          decoration: const InputDecoration(
                            labelText: '查找内容 / 正则表达式',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _replacementCtrl,
                          decoration: const InputDecoration(
                            labelText: '替换为（留空表示删除匹配内容）',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Expanded(child: Text('使用正则表达式')),
                            Switch.adaptive(
                              value: _isRegex,
                              onChanged: (v) => setState(() => _isRegex = v),
                            ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            _error!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        GlassTextButton(
                          key: const ValueKey('purification-save-rule'),
                          onPressed: _submitCustomRule,
                          child: const Text('保存并启用规则'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: rules.length,
                    separatorBuilder: (_, _) => const Divider(height: 16),
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      return Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        rule.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    ArchiveCode(
                                      rule.builtIn
                                          ? 'PRESET'
                                          : rule.isRegex
                                          ? 'REGEX'
                                          : 'TEXT',
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${rule.pattern} → ${rule.replacement.isEmpty ? "（删除）" : rule.replacement}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!rule.builtIn)
                            IconButton(
                              icon: const Icon(CupertinoIcons.delete, size: 18),
                              tooltip: '删除规则',
                              onPressed: () => store.removeRule(rule.id),
                            ),
                          Switch.adaptive(
                            value: rule.enabled,
                            onChanged: (v) => store.toggleRule(rule.id, v),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
