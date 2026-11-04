import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reading_export_theme.dart';
import 'reading_report_range.dart';
import 'reading_visual_theme.dart';

enum ReadingReportTemplate {
  archive(ReadingVisualTheme.archive),
  shelf(ReadingVisualTheme.shelf),
  editorial(ReadingVisualTheme.editorial),
  constellation(ReadingVisualTheme.constellation),
  signal(ReadingVisualTheme.signal),
  score(ReadingVisualTheme.score),
  ink(ReadingVisualTheme.ink),
  festival(ReadingVisualTheme.festival);

  const ReadingReportTemplate(this.theme);
  final ReadingVisualTheme theme;
  String get label => readingExportTheme(theme).label;
  String get description => readingExportTheme(theme).description;
}

enum ReadingReportPalette {
  pine('原色'),
  vermilion('朱砂'),
  blue('靛蓝'),
  plum('紫雾');

  const ReadingReportPalette(this.label);
  final String label;
}

enum ReadingReportModule {
  rhythm('阅读节律'),
  days('阅读足迹'),
  calendar('阅读日历'),
  books('相伴书单'),
  progress('阅读进度'),
  collection('藏书构成'),
  excerpts('摘录与书签');

  const ReadingReportModule(this.label);
  final String label;

  // Statistics already includes the date summary beside its calendar.
  static List<ReadingReportModule> get statisticsValues =>
      values.where((module) => module != days).toList(growable: false);
}

/// Independent presentation preferences; no reading record is changed.
class ReadingReportOptions {
  const ReadingReportOptions({
    this.template = ReadingReportTemplate.archive,
    this.palette = ReadingReportPalette.pine,
    this.period = 30,
    this.from,
    this.until,
    this.title = '阅读报告',
    this.nickname = '',
    this.note = '把时间留给书页。',
    this.modules = const {
      ReadingReportModule.rhythm,
      ReadingReportModule.days,
      ReadingReportModule.calendar,
      ReadingReportModule.books,
      ReadingReportModule.progress,
      ReadingReportModule.collection,
      ReadingReportModule.excerpts,
    },
    this.bookLimit = 5,
    this.hideBookTitles = false,
    this.hideAuthorNames = false,
    this.signature = true,
    this.includeNotes = false,
  });
  static const preferenceKey = 'reading_report_options_v1';
  final ReadingReportTemplate template;
  final ReadingReportPalette palette;
  final int period, bookLimit;
  final DateTime? from, until;
  final String title, nickname, note;
  final Set<ReadingReportModule> modules;
  final bool hideBookTitles, hideAuthorNames, signature, includeNotes;

  /// Stable saved selection order; the report contents follow painted positions.
  List<ReadingReportModule> get orderedModules => [
    for (final module in ReadingReportModule.values)
      if (modules.contains(module)) module,
  ];

  ReadingReportRange get range =>
      ReadingReportRange(period: period, from: from, until: until);
  int daysAt(DateTime now) => range.daysAt(now);
  DateTime endAt(DateTime now) => range.endAt(now);

  ReadingReportOptions copyWith({
    ReadingReportTemplate? template,
    ReadingReportPalette? palette,
    int? period,
    DateTime? from,
    DateTime? until,
    bool clearDates = false,
    String? title,
    String? nickname,
    String? note,
    Set<ReadingReportModule>? modules,
    int? bookLimit,
    bool? hideBookTitles,
    bool? hideAuthorNames,
    bool? signature,
    bool? includeNotes,
  }) => ReadingReportOptions(
    template: template ?? this.template,
    palette: palette ?? this.palette,
    period: period ?? this.period,
    from: clearDates ? null : from ?? this.from,
    until: clearDates ? null : until ?? this.until,
    title: title ?? this.title,
    nickname: nickname ?? this.nickname,
    note: note ?? this.note,
    modules: Set.unmodifiable(modules ?? this.modules),
    bookLimit: bookLimit ?? this.bookLimit,
    hideBookTitles: hideBookTitles ?? this.hideBookTitles,
    hideAuthorNames: hideAuthorNames ?? this.hideAuthorNames,
    signature: signature ?? this.signature,
    includeNotes: includeNotes ?? this.includeNotes,
  );

  Map<String, Object?> toJson() => {
    'contentsVersion': 2,
    'template': template.name,
    'palette': palette.name,
    'period': period,
    'from': from?.toIso8601String(),
    'until': until?.toIso8601String(),
    'title': title,
    'nickname': nickname,
    'note': note,
    'modules': modules.map((value) => value.name).toList(),
    'bookLimit': bookLimit,
    'hideBookTitles': hideBookTitles,
    'hideAuthorNames': hideAuthorNames,
    'signature': signature,
    'includeNotes': includeNotes,
  };

  factory ReadingReportOptions.fromJson(Map<String, dynamic> value) {
    const defaults = ReadingReportOptions();
    String text(String key, String fallback, int maximum) =>
        value[key] is String
        ? (value[key] as String).characters.take(maximum).toString()
        : fallback;
    var from = DateTime.tryParse('${value['from']}');
    var until = DateTime.tryParse('${value['until']}');
    if (from == null || until == null || until.isBefore(from)) {
      from = null;
      until = null;
    }
    return ReadingReportOptions(
      template: ReadingReportTemplate.values.firstWhere(
        (item) =>
            item.name ==
            ReadingVisualTheme.fromId(
              value['template'] is String ? value['template'] as String : null,
            ).id,
      ),
      palette:
          ReadingReportPalette.values
              .where((item) => item.name == value['palette'])
              .firstOrNull ??
          defaults.palette,
      period: const [7, 30, 90, 365].contains(value['period'])
          ? value['period'] as int
          : defaults.period,
      from: from,
      until: until,
      title: text('title', defaults.title, 36),
      nickname: text('nickname', '', 24),
      note: text('note', defaults.note, 80),
      modules: value['modules'] is List
          ? {
              ...ReadingReportModule.values
                  .where(
                    (item) => (value['modules'] as List).contains(item.name),
                  )
                  .toSet(),
              // The old calendar switch controlled date summaries, not a grid.
              if (value['contentsVersion'] != 2 &&
                  (value['modules'] as List).contains('calendar'))
                ReadingReportModule.days,
            }
          : defaults.modules,
      bookLimit: const [3, 5, 10, 20].contains(value['bookLimit'])
          ? value['bookLimit'] as int
          : defaults.bookLimit,
      hideBookTitles: value['hideBookTitles'] == true,
      hideAuthorNames: value['hideAuthorNames'] == true,
      signature: value['signature'] != false,
      includeNotes: value['includeNotes'] == true,
    );
  }

  static Future<ReadingReportOptions> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      preferenceKey,
    );
    if (raw == null) return const ReadingReportOptions();
    try {
      return ReadingReportOptions.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on FormatException {
      return const ReadingReportOptions();
    } on TypeError {
      return const ReadingReportOptions();
    }
  }

  Future<void> save() async => (await SharedPreferences.getInstance())
      .setString(preferenceKey, jsonEncode(toJson()));
}
