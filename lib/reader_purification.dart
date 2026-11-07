import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_interactions.dart';
import 'app_ui.dart';

const _quoteChars = {0x0022, 0x201C, 0x201D}; // " “ ”
const _sentenceEndChars = '。！？!?…~～';
const _openingContextChars = '，：,:—\n\t 　（(【[《<';
const _closingFollowChars = '，。！？!?；;、）】]》>\n\t 　';
const _speechVerbs = '问说喊唱叫骂道着答笑叹想念应劝吼哭哼';

/// Repairs straight quotes `"` and mis-ordered Chinese curly quotes `“”` into
/// properly paired `“...”` using surrounding punctuation and dialogue verbs
/// (inspired by legado-E's `ContentHelp.reSegment`).
String repairReaderQuotes(String input) {
  if (input.isEmpty) return input;
  var hasQuote = false;
  for (var i = 0; i < input.length; i++) {
    if (_quoteChars.contains(input.codeUnitAt(i))) {
      hasQuote = true;
      break;
    }
  }
  if (!hasQuote) return input;

  final buffer = StringBuilder();
  var open = false;
  for (var i = 0; i < input.length; i++) {
    final unit = input.codeUnitAt(i);
    if (!_quoteChars.contains(unit)) {
      buffer.writeCharCode(unit);
      continue;
    }
    final prev = i > 0 ? input[i - 1] : '\n';
    final next = i + 1 < input.length ? input[i + 1] : '\n';

    bool? forceOpen;
    if (i == 0 || prev == '\n' || '：:（(【['.contains(prev)) {
      forceOpen = true;
    } else if (i == input.length - 1 || next == '\n') {
      forceOpen = false;
    } else if (_sentenceEndChars.contains(prev) &&
        (_closingFollowChars.contains(next) || _speechVerbs.contains(next))) {
      forceOpen = false;
    } else if (_openingContextChars.contains(prev) && !open) {
      forceOpen = true;
    }

    final useOpen = forceOpen ?? !open;
    buffer.write(useOpen ? '“' : '”');
    open = useOpen;
  }
  return buffer.toString();
}

class StringBuilder {
  final StringBuffer _buf = StringBuffer();
  void write(String s) => _buf.write(s);
  void writeCharCode(int code) => _buf.writeCharCode(code);
  @override
  String toString() => _buf.toString();
}

/// Splits an overly dense wall-of-text paragraph at clear dialogue and
/// sentence-group boundaries while keeping normal paragraphs intact.
String reSegmentDialogueText(String input) {
  if (input.length < 160 || input.contains('\n')) return input;
  final out = StringBuffer();
  var sinceBreak = 0;
  var quoteDepth = 0;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    out.write(ch);
    sinceBreak++;
    if (ch == '“' || ch == '「' || ch == '『') {
      quoteDepth++;
    } else if (ch == '”' || ch == '」' || ch == '』') {
      if (quoteDepth > 0) quoteDepth--;
      if (quoteDepth == 0 && i + 1 < input.length) {
        final prev = i > 0 ? input[i - 1] : '';
        final next = input[i + 1];
        // Break after a complete spoken sentence `"..."` when the next token
        // starts a new quote or when the segment is already long.
        if (_sentenceEndChars.contains(prev) &&
            (next == '“' ||
                next == '「' ||
                (sinceBreak >= 90 && !_closingFollowChars.contains(next) && !_speechVerbs.contains(next)))) {
          out.write('\n　　');
          sinceBreak = 0;
        }
      }
    } else if (quoteDepth == 0 &&
        sinceBreak >= 140 &&
        _sentenceEndChars.contains(ch) &&
        i + 1 < input.length) {
      final next = input[i + 1];
      if (next != '”' &&
          next != '」' &&
          next != '』' &&
          !_sentenceEndChars.contains(next) &&
          !_closingFollowChars.contains(next)) {
        out.write('\n　　');
        sinceBreak = 0;
      }
    }
  }
  return out.toString();
}

/// Removes a leading duplicate chapter title from the first paragraph of a
/// chapter when the body repeats the heading verbatim.
String dedupLeadingChapterTitle(String paragraph, String? chapterTitle) {
  if (chapterTitle == null || chapterTitle.trim().isEmpty) return paragraph;
  final cleanTitle = chapterTitle.trim();
  final trimmed = paragraph.trimLeft();
  if (trimmed.isEmpty) return paragraph;
  if (trimmed == cleanTitle) return '';
  final escaped = RegExp.escape(cleanTitle);
  final match = RegExp(
    '^[$escaped\\s\\p{P}]*$escaped(?:[\\s　]*\\n|[\\s　]{2,})',
    unicode: true,
  ).firstMatch(trimmed);
  if (match != null) {
    final rest = trimmed.substring(match.end).trimLeft();
    return rest.isEmpty ? paragraph : rest;
  }
  return paragraph;
}

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
    this.scopeBookId,
    this.scopeBookTitle,
    this.applyToTitle = false,
  });

  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;
  final bool builtIn;
  final int? scopeBookId;
  final String? scopeBookTitle;
  final bool applyToTitle;

  bool appliesToBook(int? bookId) =>
      scopeBookId == null || (bookId != null && scopeBookId == bookId);

  ReaderPurificationRule copyWith({
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
    int? scopeBookId,
    bool clearScopeBook = false,
    String? scopeBookTitle,
    bool? applyToTitle,
  }) => ReaderPurificationRule(
    id: id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    isRegex: isRegex ?? this.isRegex,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
    scopeBookId: clearScopeBook ? null : (scopeBookId ?? this.scopeBookId),
    scopeBookTitle: clearScopeBook
        ? null
        : (scopeBookTitle ?? this.scopeBookTitle),
    applyToTitle: applyToTitle ?? this.applyToTitle,
  );

  static final Map<String, RegExp> _regExpCache = {};

  static RegExp? _compile(String pattern) {
    try {
      var regExp = _regExpCache[pattern];
      if (regExp == null) {
        if (_regExpCache.length >= 128) {
          _regExpCache.remove(_regExpCache.keys.first);
        }
        regExp = RegExp(pattern, multiLine: true);
        _regExpCache[pattern] = regExp;
      }
      return regExp;
    } on FormatException {
      return null;
    }
  }

  bool matches(String input) {
    if (!enabled || pattern.isEmpty || input.isEmpty) return false;
    if (id == 'builtin_smart_quotes') {
      return repairReaderQuotes(input) != input;
    }
    if (id == 'builtin_dialogue_resegment') {
      return reSegmentDialogueText(input) != input;
    }
    if (!isRegex) return input.contains(pattern);
    final regExp = _compile(pattern);
    return regExp != null && regExp.hasMatch(input);
  }

  String apply(String input) {
    if (!enabled || input.isEmpty) return input;
    if (id == 'builtin_smart_quotes') {
      return repairReaderQuotes(input);
    }
    if (id == 'builtin_dialogue_resegment') {
      return reSegmentDialogueText(input);
    }
    if (pattern.isEmpty) return input;
    if (!isRegex) {
      return input.replaceAll(pattern, replacement);
    }
    final regExp = _compile(pattern);
    if (regExp == null) return input;
    return input.replaceAll(regExp, replacement);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'isRegex': isRegex,
    'enabled': enabled,
    'builtIn': builtIn,
    if (scopeBookId != null) 'scopeBookId': scopeBookId,
    if (scopeBookTitle != null && scopeBookTitle!.isNotEmpty)
      'scopeBookTitle': scopeBookTitle,
    if (applyToTitle) 'applyToTitle': true,
  };

  static ReaderPurificationRule? fromJson(
    Object? raw, {
    int? defaultBookId,
    String? defaultBookTitle,
  }) {
    if (raw is! Map) return null;
    final name = (raw['name'] as String?)?.trim();
    final pattern = raw['pattern'] as String?;
    if (name == null || name.isEmpty || pattern == null || pattern.isEmpty) {
      return null;
    }
    final rawId = raw['id'];
    final id = (rawId is String && rawId.isNotEmpty)
        ? rawId
        : 'custom_${DateTime.now().microsecondsSinceEpoch}_${name.hashCode.abs()}';
    final scopeId = (raw['scopeBookId'] as num?)?.toInt() ?? defaultBookId;
    final scopeTitle =
        (raw['scopeBookTitle'] as String?) ??
        (raw['scope'] as String?) ??
        (scopeId != null ? defaultBookTitle : null);
    final enabled = raw.containsKey('enabled')
        ? raw['enabled'] == true
        : (raw['isEnabled'] != false);
    final applyTitle =
        raw['applyToTitle'] == true || raw['scopeTitle'] == true;
    return ReaderPurificationRule(
      id: id,
      name: name,
      pattern: pattern,
      replacement: raw['replacement'] is String
          ? raw['replacement'] as String
          : '',
      isRegex: raw['isRegex'] == true,
      enabled: enabled,
      builtIn: raw['builtIn'] == true,
      scopeBookId: scopeId,
      scopeBookTitle: scopeTitle,
      applyToTitle: applyTitle,
    );
  }
}

class ReaderPurificationStore extends ChangeNotifier {
  ReaderPurificationStore._();

  static final ReaderPurificationStore shared = ReaderPurificationStore._();
  static const String preferenceKey = 'reader_purification_rules_v1';
  static const String editsPreferenceKey = 'reader_paragraph_edits_v1';

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
    ReaderPurificationRule(
      id: 'builtin_smart_quotes',
      name: '智能修复直引号与弯引号配对（"" → “”）',
      pattern: '__smart_quotes__',
      replacement: '“…”',
      isRegex: false,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_dialogue_resegment',
      name: '粘连长段按对话与句群智能重分段',
      pattern: '__dialogue_resegment__',
      replacement: '分段',
      isRegex: false,
      enabled: false,
      builtIn: true,
    ),
    ReaderPurificationRule(
      id: 'builtin_dedup_chapter_title',
      name: '自动移除正文首段重复章节名',
      pattern: '__dedup_chapter_title__',
      replacement: '',
      isRegex: false,
      enabled: false,
      builtIn: true,
    ),
  ];

  List<ReaderPurificationRule> _rules = [...builtInPresets];
  Map<String, String> _paragraphEdits = {};
  bool _loaded = false;

  List<ReaderPurificationRule> get rules => List.unmodifiable(_rules);

  bool get hasEnabledRules =>
      _rules.any((rule) => rule.enabled) || _paragraphEdits.isNotEmpty;

  int get enabledCount => _rules.where((rule) => rule.enabled).length;

  @visibleForTesting
  void resetForTesting() {
    _rules = [...builtInPresets];
    _paragraphEdits = {};
    _loaded = false;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawEdits = prefs.getString(editsPreferenceKey);
      if (rawEdits != null && rawEdits.isNotEmpty) {
        final decodedEdits = jsonDecode(rawEdits);
        if (decodedEdits is Map) {
          _paragraphEdits = {
            for (final entry in decodedEdits.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          };
        }
      }
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

  Future<void> _persistEdits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_paragraphEdits.isEmpty) {
        await prefs.remove(editsPreferenceKey);
      } else {
        await prefs.setString(editsPreferenceKey, jsonEncode(_paragraphEdits));
      }
    } catch (_) {}
  }

  static String _editKey(int bookId, int chapterIndex, int paragraphIndex) =>
      '$bookId:$chapterIndex:$paragraphIndex';

  String? paragraphEditFor(int bookId, int chapterIndex, int paragraphIndex) =>
      _paragraphEdits[_editKey(bookId, chapterIndex, paragraphIndex)];

  bool hasEditsForChapter(int bookId, int chapterIndex) {
    final prefix = '$bookId:$chapterIndex:';
    return _paragraphEdits.keys.any((k) => k.startsWith(prefix));
  }

  Future<void> setParagraphEdit({
    required int bookId,
    required int chapterIndex,
    required int paragraphIndex,
    required String editedText,
  }) async {
    await ensureLoaded();
    final key = _editKey(bookId, chapterIndex, paragraphIndex);
    _paragraphEdits = {..._paragraphEdits, key: editedText};
    notifyListeners();
    await _persistEdits();
  }

  Future<void> clearParagraphEdit({
    required int bookId,
    required int chapterIndex,
    required int paragraphIndex,
  }) async {
    await ensureLoaded();
    final key = _editKey(bookId, chapterIndex, paragraphIndex);
    if (!_paragraphEdits.containsKey(key)) return;
    final next = Map<String, String>.of(_paragraphEdits)..remove(key);
    _paragraphEdits = next;
    notifyListeners();
    await _persistEdits();
  }

  Future<void> clearChapterEdits(int bookId, int chapterIndex) async {
    await ensureLoaded();
    final prefix = '$bookId:$chapterIndex:';
    final next = Map<String, String>.of(_paragraphEdits)
      ..removeWhere((key, _) => key.startsWith(prefix));
    if (next.length == _paragraphEdits.length) return;
    _paragraphEdits = next;
    notifyListeners();
    await _persistEdits();
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
    int? scopeBookId,
    String? scopeBookTitle,
    bool applyToTitle = false,
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
        scopeBookId: scopeBookId,
        scopeBookTitle: scopeBookTitle,
        applyToTitle: applyToTitle,
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

  /// Exports custom rules as a shareable token (`shuyu://purification?data=...`)
  /// or JSON array compatible with Legado's `replaceRule`.
  String exportRulesShareToken({int? bookId}) {
    final exported = [
      for (final rule in _rules)
        if (!rule.builtIn && (bookId == null || rule.appliesToBook(bookId)))
          rule.toJson(),
    ];
    final jsonStr = jsonEncode(exported);
    final encoded = base64Url.encode(utf8.encode(jsonStr));
    return 'shuyu://purification?data=$encoded';
  }

  /// Imports rules from a Shuyu share token or a JSON array (including Legado's
  /// `replaceRule.json` format). Returns the number of imported rules.
  Future<int> importRulesFromText(
    String rawText, {
    int? defaultBookId,
    String? defaultBookTitle,
  }) async {
    await ensureLoaded();
    var payload = rawText.trim();
    if (payload.isEmpty) return 0;
    final tokenMatch = RegExp(
      r'shuyu://purification\?data=([A-Za-z0-9_\-=]+)',
    ).firstMatch(payload);
    if (tokenMatch != null) {
      payload = utf8.decode(
        base64Url.decode(base64Url.normalize(tokenMatch.group(1)!)),
      );
    }
    final decoded = jsonDecode(payload);
    final items = decoded is List
        ? decoded
        : (decoded is Map ? [decoded] : const <Object?>[]);
    final existingPatterns = {
      for (final r in _rules) '${r.pattern}|${r.replacement}|${r.scopeBookId}',
    };
    final added = <ReaderPurificationRule>[];
    var seq = 0;
    for (final item in items) {
      final parsed = ReaderPurificationRule.fromJson(
        item,
        defaultBookId: defaultBookId,
        defaultBookTitle: defaultBookTitle,
      );
      if (parsed == null || parsed.builtIn) continue;
      final sig =
          '${parsed.pattern}|${parsed.replacement}|${parsed.scopeBookId}';
      if (!existingPatterns.add(sig)) continue;
      seq++;
      added.add(
        ReaderPurificationRule(
          id: 'custom_${DateTime.now().microsecondsSinceEpoch}_$seq',
          name: parsed.name,
          pattern: parsed.pattern,
          replacement: parsed.replacement,
          isRegex: parsed.isRegex,
          enabled: parsed.enabled,
          scopeBookId: parsed.scopeBookId,
          scopeBookTitle: parsed.scopeBookTitle,
          applyToTitle: parsed.applyToTitle,
        ),
      );
    }
    if (added.isNotEmpty) {
      _rules = [..._rules, ...added];
      notifyListeners();
      await _persist();
    }
    return added.length;
  }

  /// Returns the enabled rules that actually match the given chapter content
  /// or chapter title, allowing the reader to inspect and toggle active rules.
  List<ReaderPurificationRule> effectiveRulesForChapter(
    Iterable<String> paragraphs, {
    int? bookId,
    String? chapterTitle,
  }) {
    final active = <ReaderPurificationRule>[];
    final paragraphList = paragraphs.toList(growable: false);
    for (final rule in _rules) {
      if (!rule.enabled || !rule.appliesToBook(bookId)) continue;
      if (rule.id == 'builtin_dedup_chapter_title') {
        if (paragraphList.isNotEmpty &&
            dedupLeadingChapterTitle(paragraphList.first, chapterTitle) !=
                paragraphList.first) {
          active.add(rule);
        }
        continue;
      }
      if (rule.applyToTitle &&
          chapterTitle != null &&
          rule.matches(chapterTitle)) {
        active.add(rule);
        continue;
      }
      for (final p in paragraphList) {
        if (rule.matches(p)) {
          active.add(rule);
          break;
        }
      }
    }
    return active;
  }

  String purifyTitle(String title, {int? bookId}) {
    if (!hasEnabledRules || title.isEmpty) return title;
    var current = title;
    for (final rule in _rules) {
      if (rule.enabled && rule.applyToTitle && rule.appliesToBook(bookId)) {
        current = rule.apply(current);
      }
    }
    return current;
  }

  String purifyParagraph(
    String text, {
    int? bookId,
    int? chapterIndex,
    int? paragraphIndex,
    String? chapterTitle,
    bool isFirstParagraph = false,
  }) {
    if (bookId != null && chapterIndex != null && paragraphIndex != null) {
      final edited = paragraphEditFor(bookId, chapterIndex, paragraphIndex);
      if (edited != null) return edited;
    }
    if (!hasEnabledRules || text.isEmpty) return text;
    final trimmed = text.trim();
    if (trimmed == '[插图]' ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      return text;
    }
    var current = text;
    for (final rule in _rules) {
      if (!rule.enabled || !rule.appliesToBook(bookId)) continue;
      if (rule.id == 'builtin_dedup_chapter_title') {
        if (isFirstParagraph && chapterTitle != null) {
          current = dedupLeadingChapterTitle(current, chapterTitle);
        }
        continue;
      }
      current = rule.apply(current);
    }
    return current;
  }
}

Future<void> showReaderPurificationSheet({
  required BuildContext context,
  bool reduceMotion = false,
  int? bookId,
  String? bookTitle,
  int? chapterIndex,
  String? chapterTitle,
  List<String>? chapterParagraphs,
  int? initialParagraphIndex,
  String? initialPattern,
}) async {
  await ReaderPurificationStore.shared.ensureLoaded();
  if (!context.mounted) return;
  await showJellySheet<void>(
    context: context,
    reduceMotion: reduceMotion,
    builder: (sheetContext) => _ReaderPurificationSheet(
      reduceMotion: reduceMotion,
      bookId: bookId,
      bookTitle: bookTitle,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      chapterParagraphs: chapterParagraphs,
      initialParagraphIndex: initialParagraphIndex,
      initialPattern: initialPattern,
    ),
  );
}

class _ReaderPurificationSheet extends StatefulWidget {
  const _ReaderPurificationSheet({
    required this.reduceMotion,
    this.bookId,
    this.bookTitle,
    this.chapterIndex,
    this.chapterTitle,
    this.chapterParagraphs,
    this.initialParagraphIndex,
    this.initialPattern,
  });

  final bool reduceMotion;
  final int? bookId;
  final String? bookTitle;
  final int? chapterIndex;
  final String? chapterTitle;
  final List<String>? chapterParagraphs;
  final int? initialParagraphIndex;
  final String? initialPattern;

  @override
  State<_ReaderPurificationSheet> createState() =>
      _ReaderPurificationSheetState();
}

class _ReaderPurificationSheetState extends State<_ReaderPurificationSheet> {
  final _nameCtrl = TextEditingController();
  final _patternCtrl = TextEditingController();
  final _replacementCtrl = TextEditingController();
  final _editParagraphCtrl = TextEditingController();
  bool _isRegex = false;
  bool _onlyCurrentBook = false;
  bool _applyToTitle = false;
  bool _adding = false;
  bool _onlyEffective = false;
  bool _editingParagraph = false;
  int _selectedParagraphIndex = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPattern?.trim() ?? '';
    if (initial.isNotEmpty) {
      _adding = true;
      _patternCtrl.text = initial;
      final preview = initial.length > 10
          ? '${initial.substring(0, 10)}…'
          : initial;
      _nameCtrl.text = '替换「$preview」';
      _onlyCurrentBook = widget.bookId != null;
    }
    final paragraphs = widget.chapterParagraphs;
    if (paragraphs != null && paragraphs.isNotEmpty) {
      _selectedParagraphIndex = (widget.initialParagraphIndex ?? 0).clamp(
        0,
        paragraphs.length - 1,
      );
      _syncParagraphEditorText();
    }
  }

  void _syncParagraphEditorText() {
    final paragraphs = widget.chapterParagraphs;
    if (paragraphs == null || paragraphs.isEmpty) return;
    final idx = _selectedParagraphIndex.clamp(0, paragraphs.length - 1);
    final bookId = widget.bookId;
    final chapterIndex = widget.chapterIndex;
    final override = (bookId != null && chapterIndex != null)
        ? ReaderPurificationStore.shared.paragraphEditFor(
            bookId,
            chapterIndex,
            idx,
          )
        : null;
    _editParagraphCtrl.text = override ?? paragraphs[idx];
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    _editParagraphCtrl.dispose();
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
      scopeBookId: _onlyCurrentBook ? widget.bookId : null,
      scopeBookTitle: _onlyCurrentBook ? widget.bookTitle : null,
      applyToTitle: _applyToTitle,
    );
    if (!mounted) return;
    setState(() {
      _nameCtrl.clear();
      _patternCtrl.clear();
      _replacementCtrl.clear();
      _isRegex = false;
      _applyToTitle = false;
      _adding = false;
      _error = null;
    });
  }

  Future<void> _saveParagraphEdit() async {
    final bookId = widget.bookId;
    final chapterIndex = widget.chapterIndex;
    final paragraphs = widget.chapterParagraphs;
    if (bookId == null ||
        chapterIndex == null ||
        paragraphs == null ||
        paragraphs.isEmpty) {
      return;
    }
    final idx = _selectedParagraphIndex.clamp(0, paragraphs.length - 1);
    final updated = _editParagraphCtrl.text;
    if (updated == paragraphs[idx]) {
      await ReaderPurificationStore.shared.clearParagraphEdit(
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: idx,
      );
    } else {
      await ReaderPurificationStore.shared.setParagraphEdit(
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: idx,
        editedText: updated,
      );
    }
    if (!mounted) return;
    showNovelFeedback(context, '已保存本段纠错修改');
  }

  Future<void> _exportRules() async {
    final token = ReaderPurificationStore.shared.exportRulesShareToken();
    await Clipboard.setData(ClipboardData(text: token));
    if (!mounted) return;
    showNovelFeedback(context, '已复制净化规则分享口令到剪贴板');
  }

  Future<void> _importRules() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      if (mounted) showNovelFeedback(context, '剪贴板为空，请先复制净化规则口令或 JSON');
      return;
    }
    try {
      final count = await ReaderPurificationStore.shared.importRulesFromText(
        raw,
        defaultBookId: _onlyCurrentBook ? widget.bookId : null,
        defaultBookTitle: _onlyCurrentBook ? widget.bookTitle : null,
      );
      if (!mounted) return;
      showNovelFeedback(
        context,
        count > 0 ? '成功导入 $count 条净化规则' : '未发现可导入的新规则',
      );
    } catch (_) {
      if (mounted) {
        showNovelFeedback(context, '规则格式无法识别，支持书屿口令或阅读 Legado JSON');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ReaderPurificationStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final effectiveRules = widget.chapterParagraphs != null
            ? store.effectiveRulesForChapter(
                widget.chapterParagraphs!,
                bookId: widget.bookId,
                chapterTitle: widget.chapterTitle,
              )
            : const <ReaderPurificationRule>[];
        final effectiveIds = {for (final r in effectiveRules) r.id};
        final allRules = store.rules;
        final rules = _onlyEffective
            ? allRules.where((r) => effectiveIds.contains(r.id)).toList()
            : allRules;
        final canEditChapter =
            widget.bookId != null &&
            widget.chapterIndex != null &&
            widget.chapterParagraphs != null &&
            widget.chapterParagraphs!.isNotEmpty;

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
                    if (canEditChapter) ...[
                      GlassTextButton(
                        key: const ValueKey('purification-toggle-edit'),
                        onPressed: () => setState(() {
                          _editingParagraph = !_editingParagraph;
                          if (_editingParagraph) {
                            _adding = false;
                            _syncParagraphEditorText();
                          }
                        }),
                        child: Text(_editingParagraph ? '收起纠错' : '段落纠错'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    GlassTextButton(
                      key: const ValueKey('purification-toggle-add'),
                      onPressed: () => setState(() {
                        _adding = !_adding;
                        if (_adding) _editingParagraph = false;
                        _error = null;
                      }),
                      child: Text(_adding ? '收起新建' : '新增规则'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '支持智能引号配对修复、对话重分段、按书绑定替换与章节纠错，兼容阅读 Legado 规则导入。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (widget.chapterParagraphs != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterChip(
                        key: const ValueKey('purification-filter-effective'),
                        label: Text('本章已命中 (${effectiveRules.length})'),
                        selected: _onlyEffective,
                        onSelected: (v) => setState(() => _onlyEffective = v),
                      ),
                      GlassTextButton(
                        key: const ValueKey('purification-import-clipboard'),
                        onPressed: _importRules,
                        child: const Text('剪贴板导入'),
                      ),
                      GlassTextButton(
                        key: const ValueKey('purification-export-clipboard'),
                        onPressed: _exportRules,
                        child: const Text('导出分享口令'),
                      ),
                    ],
                  ),
                ] else ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      GlassTextButton(
                        key: const ValueKey('purification-import-clipboard'),
                        onPressed: _importRules,
                        child: const Text('从剪贴板导入规则/口令'),
                      ),
                      GlassTextButton(
                        key: const ValueKey('purification-export-clipboard'),
                        onPressed: _exportRules,
                        child: const Text('导出规则口令'),
                      ),
                    ],
                  ),
                ],
                if (_editingParagraph && canEditChapter) ...[
                  const SizedBox(height: 14),
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '段落纠错（第 ${_selectedParagraphIndex + 1} / ${widget.chapterParagraphs!.length} 段）',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                CupertinoIcons.chevron_left,
                                size: 18,
                              ),
                              tooltip: '上一段',
                              onPressed: _selectedParagraphIndex > 0
                                  ? () => setState(() {
                                      _selectedParagraphIndex--;
                                      _syncParagraphEditorText();
                                    })
                                  : null,
                            ),
                            IconButton(
                              icon: const Icon(
                                CupertinoIcons.chevron_right,
                                size: 18,
                              ),
                              tooltip: '下一段',
                              onPressed:
                                  _selectedParagraphIndex + 1 <
                                      widget.chapterParagraphs!.length
                                  ? () => setState(() {
                                      _selectedParagraphIndex++;
                                      _syncParagraphEditorText();
                                    })
                                  : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const ValueKey('purification-paragraph-editor'),
                          controller: _editParagraphCtrl,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: '直接修正当前段落错别字或排版',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (store.paragraphEditFor(
                                  widget.bookId!,
                                  widget.chapterIndex!,
                                  _selectedParagraphIndex,
                                ) !=
                                null)
                              GlassTextButton(
                                onPressed: () async {
                                  await store.clearParagraphEdit(
                                    bookId: widget.bookId!,
                                    chapterIndex: widget.chapterIndex!,
                                    paragraphIndex: _selectedParagraphIndex,
                                  );
                                  if (!mounted) return;
                                  setState(_syncParagraphEditorText);
                                },
                                child: const Text('还原原文'),
                              ),
                            const SizedBox(width: 8),
                            GlassTextButton(
                              key: const ValueKey(
                                'purification-save-paragraph',
                              ),
                              onPressed: _saveParagraphEdit,
                              child: const Text('保存段落修改'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
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
                        if (widget.bookId != null)
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '仅对《${widget.bookTitle ?? "当前书籍"}》生效',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Switch.adaptive(
                                key: const ValueKey(
                                  'purification-scope-current-book',
                                ),
                                value: _onlyCurrentBook,
                                onChanged: (v) =>
                                    setState(() => _onlyCurrentBook = v),
                              ),
                            ],
                          ),
                        Row(
                          children: [
                            const Expanded(child: Text('同时净化章节标题')),
                            Switch.adaptive(
                              key: const ValueKey('purification-apply-title'),
                              value: _applyToTitle,
                              onChanged: (v) =>
                                  setState(() => _applyToTitle = v),
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
                  child: rules.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              _onlyEffective ? '本章正文暂未触发任何净化规则' : '暂无净化规则',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: rules.length,
                          separatorBuilder: (_, _) => const Divider(height: 16),
                          itemBuilder: (context, index) {
                            final rule = rules[index];
                            final isHit = effectiveIds.contains(rule.id);
                            return Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            rule.name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          ArchiveCode(
                                            rule.builtIn
                                                ? 'PRESET'
                                                : rule.isRegex
                                                ? 'REGEX'
                                                : 'TEXT',
                                          ),
                                          if (rule.scopeBookId != null)
                                            ArchiveCode(
                                              '仅《${rule.scopeBookTitle ?? rule.scopeBookId}》',
                                            ),
                                          if (isHit)
                                            const ArchiveCode('本章命中'),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        rule.builtIn &&
                                                rule.pattern.startsWith('__')
                                            ? '内置智能排版算法（阅读渲染时实时处理）'
                                            : '${rule.pattern} → ${rule.replacement.isEmpty ? "（删除）" : rule.replacement}',
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
                                    icon: const Icon(
                                      CupertinoIcons.delete,
                                      size: 18,
                                    ),
                                    tooltip: '删除规则',
                                    onPressed: () => store.removeRule(rule.id),
                                  ),
                                Switch.adaptive(
                                  value: rule.enabled,
                                  onChanged: (v) =>
                                      store.toggleRule(rule.id, v),
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
