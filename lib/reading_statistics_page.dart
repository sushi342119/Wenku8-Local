import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'bookmark_library_page.dart';
import 'catalog.dart';
import 'dock_layout.dart';
import 'feature_pages.dart';
import 'glass_dock.dart';
import 'library_state.dart';
import 'offline_repository.dart';
import 'performance_preferences.dart';
import 'reading_statistics_charts.dart';
import 'reading_statistics_data.dart';
import 'reading_statistics_analysis_view.dart';
import 'reading_report_options.dart';
import 'reading_report_page.dart';
import 'reading_report_range.dart';
import 'reading_moments_ui.dart';
import 'reading_touch_page.dart';

enum _StatisticsCategory {
  overview('总览', CupertinoIcons.square_grid_2x2),
  rhythm('节律', CupertinoIcons.waveform),
  books('书目', CupertinoIcons.book),
  marks('记号', CupertinoIcons.bookmark),
  touch('触摸', CupertinoIcons.hand_draw);

  const _StatisticsCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({
    super.key,
    required this.state,
    required this.repository,
    this.now,
  });
  final LibraryState state;
  final NovelRepository repository;
  final DateTime? now;
  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage>
    with WidgetsBindingObserver {
  late Listenable _changes;
  late ReadingStatisticsData _data;
  ReadingReportRange _range = const ReadingReportRange();
  DateTime get _now => widget.now ?? DateTime.now();
  int get _period => _range.daysAt(_now);
  int _selected = 29;
  DateTime? _calendarSelection;
  _StatisticsCategory _category = _StatisticsCategory.overview;
  final _scrolls = {
    for (final category in _StatisticsCategory.values)
      category: ScrollController(),
  };
  final _revealedSections = <String>{};
  Set<ReadingReportModule> _modules = ReadingReportModule.statisticsValues
      .toSet();
  static const _modulesKey = 'reading_statistics_modules_v1';
  static const _rangeKey = 'reading_statistics_range_v1';

  Widget _section(String id, WidgetBuilder builder) => _StatisticsSection(
    key: ValueKey('statistics-section-$id'),
    seen: _revealedSections.contains(id),
    onSeen: () => _revealedSections.add(id),
    reduceMotion: widget.state.reduceMotion,
    builder: builder,
  );

  bool get _hasDays => _data.observedDays > 0;
  bool get _hasBreadth =>
      _data.bookCounts.any((value) => value != null && value > 0);
  bool get _hasBookAnalysis =>
      _data.analysis.booksByDuration.any(
        (book) =>
            book.seconds != null ||
            book.activeMonths.isNotEmpty ||
            (book.firstOpenedAt != null && _withinRange(book.firstOpenedAt!)) ||
            (book.completedAt != null && _withinRange(book.completedAt!)),
      ) ||
      _data.analysis.bookDayDistribution.hasData;
  bool _withinRange(DateTime value) {
    final day = statisticsCivilDay(value);
    return !day.isBefore(_data.analysis.start) &&
        !day.isAfter(_data.analysis.end);
  }

  bool get _hasProgress =>
      _data.readingBooks > 0 ||
      _data.analysis.firstOpenedBooks.isNotEmpty ||
      _data.analysis.completedBooks.isNotEmpty;
  bool get _hasCollection => _data.onlineBooks + _data.localBooks > 0;
  bool get _hasMarks =>
      _data.bookmarks + _data.underlines > 0 ||
      _data.analysis.marks.items.isNotEmpty;

  List<_StatisticsCategory> get _categories => [
    _StatisticsCategory.overview,
    if ((_modules.contains(ReadingReportModule.rhythm) &&
            (_hasDays ||
                _data.analysis.coverage.hasTimeDetail ||
                _data.analysis.longestSession != null)) ||
        (_modules.contains(ReadingReportModule.calendar) && _hasDays))
      _StatisticsCategory.rhythm,
    if ((_modules.contains(ReadingReportModule.books) &&
            (_hasBreadth || _hasBookAnalysis)) ||
        (_modules.contains(ReadingReportModule.progress) && _hasProgress) ||
        (_modules.contains(ReadingReportModule.collection) && _hasCollection))
      _StatisticsCategory.books,
    if ((_modules.contains(ReadingReportModule.excerpts) && _hasMarks) ||
        widget.state.readingMoments.moments.isNotEmpty)
      _StatisticsCategory.marks,
    // Collection controls remain reachable before the first sample.
    _StatisticsCategory.touch,
  ];

  void _reconcileCategory() {
    if (!_categories.contains(_category)) {
      _category = _StatisticsCategory.overview;
    }
  }

  void _selectCategory(_StatisticsCategory value) {
    if (_category != value) setState(() => _category = value);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bind();
    _loadModules();
  }

  Future<void> _loadModules() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getStringList(_modulesKey);
    final rangeRecord = preferences.getString(_rangeKey);
    ReadingReportRange? restored;
    if (rangeRecord != null) {
      try {
        restored = ReadingReportRange.fromJson(
          jsonDecode(rangeRecord) as Map<String, dynamic>,
        );
      } on FormatException {
        restored = null;
      } on TypeError {
        restored = null;
      }
    }
    if (restored != null && mounted) {
      setState(() {
        _range = restored!;
        _selected = _period - 1;
        _snapshot();
      });
    }
    if (raw != null && mounted) {
      setState(() {
        _modules = ReadingReportModule.statisticsValues
            .where((value) => raw.contains(value.name))
            .toSet();
        _reconcileCategory();
      });
    }
  }

  Future<void> _configure() => showJellySheet<void>(
    context: context,
    reduceMotion: widget.state.reduceMotion,
    builder: (context) => StatefulBuilder(
      builder: (context, updateSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '我的统计视图', code: 'DASHBOARD / MODULES'),
            const SizedBox(height: 18),
            for (final module in ReadingReportModule.statisticsValues)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: AppText(
                        module == ReadingReportModule.books
                            ? '阅读广度与相伴书单'
                            : module.label,
                      ),
                    ),
                    const SizedBox(width: 14),
                    AppControls.toggle(
                      context,
                      key: ValueKey('statistics-module-${module.name}'),
                      value: _modules.contains(module),
                      onChanged: (enabled) async {
                        setState(() {
                          enabled
                              ? _modules.add(module)
                              : _modules.remove(module);
                          _reconcileCategory();
                        });
                        updateSheet(() {});
                        try {
                          await (await SharedPreferences.getInstance())
                              .setStringList(
                                _modulesKey,
                                _modules.map((value) => value.name).toList(),
                              );
                        } catch (_) {
                          if (context.mounted) {
                            showNovelFeedback(context, '视图设置未能保存，请重试');
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  void _report() => pushNovelPage<void>(
    context,
    ReadingReportPage(
      state: widget.state,
      repository: widget.repository,
      now: widget.now,
      initialRange: _range,
    ),
    reduceMotion: widget.state.reduceMotion,
  );

  void _bind() {
    _changes = Listenable.merge([
      widget.state.historyChanges,
      widget.state.bookmarkChanges,
      widget.state.shelfViewChanges,
      widget.state.readingActivity,
      widget.state.readingMoments,
      ?widget.state.localLibrary,
    ])..addListener(_refresh);
    _snapshot();
  }

  void _snapshot() {
    _data = ReadingStatisticsData(
      state: widget.state,
      repository: widget.repository,
      now: _range.endAt(_now),
      snapshotAt: _now,
      period: _period,
    );
    _selected = _selected.clamp(0, _period - 1);
    _reconcileCategory();
  }

  void _refresh() {
    if (mounted) setState(_snapshot);
  }

  @override
  void didUpdateWidget(covariant ReadingStatisticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.repository != widget.repository) {
      _changes.removeListener(_refresh);
      _bind();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _changes.removeListener(_refresh);
    for (final scroll in _scrolls.values) {
      scroll.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _changePeriod(int? value) {
    if (value == null || (!_range.custom && value == _range.period)) return;
    setState(() {
      _range = ReadingReportRange(period: value);
      _selected = value - 1;
      _calendarSelection = null;
      _snapshot();
    });
    _saveRange();
  }

  Future<void> _saveRange() async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _rangeKey,
        jsonEncode(_range.toJson()),
      );
    } catch (_) {
      if (mounted) showNovelFeedback(context, '日期区间未能保存，请重试');
    }
  }

  Future<void> _customRange() async {
    final result = await pickReadingReportRange(
      context,
      now: _now,
      range: _range,
    );
    if (result == null || !mounted) return;
    setState(() {
      _range = ReadingReportRange(
        period: _range.period,
        from: result.start,
        until: result.end,
      );
      _selected = _period - 1;
      _calendarSelection = null;
      _snapshot();
    });
    await _saveRange();
  }

  String get _rangeCaption => _range.custom
      ? '${_range.from!.year}.${_range.from!.month}.${_range.from!.day} — ${_range.until!.year}.${_range.until!.month}.${_range.until!.day}'
      : '近 $_period 天';

  Future<void> _chooseRange() async {
    final selection = await showJellySheet<int>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '统计日期', code: 'READING / DATE RANGE'),
            if (_range.custom) ...[
              const SizedBox(height: 12),
              AppText(_rangeCaption, style: _muted(sheet)),
            ],
            const SizedBox(height: 14),
            for (final (index, period) in const [7, 30, 90, 365].indexed)
              GlassMenuItem(
                key: ValueKey('statistics-period-$period'),
                order: index,
                label: '近 $period 天',
                selected: !_range.custom && _range.period == period,
                onPressed: () => Navigator.pop(sheet, period),
              ),
            GlassMenuItem(
              key: const ValueKey('statistics-custom-range'),
              order: 4,
              label: '自定义日期',
              selected: _range.custom,
              onPressed: () => Navigator.pop(sheet, 0),
            ),
          ],
        ),
      ),
    );
    if (!mounted || selection == null) return;
    if (selection == 0) {
      await _customRange();
    } else {
      _changePeriod(selection);
    }
  }

  double _toolsHeight(BuildContext context) =>
      (28 +
              MediaQuery.textScalerOf(context).scale(14) *
                  (_range.custom && _category != _StatisticsCategory.touch
                      ? 2.8
                      : 1.4))
          .clamp(56.0, double.infinity)
          .toDouble();

  @override
  Widget build(BuildContext context) => PerformanceScope(
    preferences: PerformanceScope.of(context),
    explicitReduceMotion:
        widget.state.reduceMotion || PerformanceScope.reduceMotionOf(context),
    child: ArchiveFeaturePage(
      title: '统计',
      code: 'PERSONAL / READING RECORDS',
      actions: [
        GlassIconButton(
          key: const ValueKey('statistics-make-report'),
          icon: CupertinoIcons.doc_text,
          label: '制作图片报告',
          onPressed: _report,
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final categories = _categories;
          final wide = constraints.maxWidth >= 800;
          final laneWidth =
              ((constraints.maxWidth -
                          24 -
                          MediaQuery.paddingOf(context).horizontal -
                          DockLayout.horizontalInset * 2) /
                      categories.length)
                  .clamp(48.0, DockLayout.itemWidth)
                  .toDouble();
          final toolsHeight = _toolsHeight(context);
          final footerHeight = toolsHeight + 8 + DockLayout.heightOf(context);
          final padding = featurePadding(context).copyWith(
            bottom: DockLayout.scrollPaddingOf(context) + toolsHeight + 8,
          );
          return Stack(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: _category == _StatisticsCategory.touch
                      ? ReadingTouchContent(
                          key: const ValueKey('statistics-content-touch'),
                          controller: _scrolls[_category],
                          padding: padding,
                        )
                      : ListView(
                          key: PageStorageKey('statistics-${_category.name}'),
                          controller: _scrolls[_category],
                          cacheExtent: 0,
                          padding: padding,
                          children: _categorySections(context, wide: wide),
                        ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: DockUnderlay(contentHeight: footerHeight),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    12 + MediaQuery.paddingOf(context).left,
                    0,
                    12 + MediaQuery.paddingOf(context).right,
                    DockLayout.bottomPaddingOf(context),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: _bottomTools(context),
                      ),
                      const SizedBox(height: 8),
                      GlassDock(
                        key: const ValueKey('statistics-dock'),
                        itemWidth: laneWidth,
                        selectedIndex: categories.indexOf(_category),
                        reduceMotion: widget.state.reduceMotion,
                        onSelected: (index) =>
                            _selectCategory(categories[index]),
                        onReselected: (_) {
                          final scroll = _scrolls[_category]!;
                          if (scroll.hasClients) {
                            if (widget.state.reduceMotion ||
                                PerformanceScope.reduceMotionOf(context)) {
                              scroll.jumpTo(0);
                            } else {
                              scroll.animateTo(
                                0,
                                duration: NovelMotion.enter,
                                curve: NovelMotion.ease,
                              );
                            }
                          }
                        },
                        items: [
                          for (final category in categories)
                            GlassDockItem(
                              category.icon,
                              category.label,
                              id: 'statistics-category-${category.name}',
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _bottomTools(BuildContext context) => ConstrainedBox(
    key: const ValueKey('statistics-bottom-tools'),
    constraints: const BoxConstraints(minHeight: 56),
    child: Row(
      children: [
        Expanded(
          child: _category == _StatisticsCategory.touch
              ? const Row(
                  key: ValueKey('statistics-touch-context'),
                  children: [
                    ArchiveIcon(CupertinoIcons.hand_draw, size: 17),
                    SizedBox(width: 8),
                    AppText(
                      '本机累计',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                )
              : Semantics(
                  label: '统计日期 $_rangeCaption',
                  child: GlassTextButton(
                    key: const ValueKey('statistics-range-button'),
                    compact: true,
                    onPressed: _chooseRange,
                    child: Row(
                      children: [
                        const ArchiveIcon(CupertinoIcons.clock, size: 17),
                        const SizedBox(width: 8),
                        Expanded(
                          child: AppText(
                            _rangeCaption,
                            key: const ValueKey('statistics-range-caption'),
                            maxLines: 2,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const ArchiveIcon(
                          CupertinoIcons.chevron_down,
                          size: 12,
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Semantics(
          label: '自定义统计视图',
          child: GlassTextButton(
            key: const ValueKey('statistics-configure'),
            compact: true,
            onPressed: _configure,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ArchiveIcon(CupertinoIcons.slider_horizontal_3, size: 17),
                SizedBox(width: 6),
                AppText('视图'),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  List<Widget> _categorySections(BuildContext context, {required bool wide}) {
    final sections = <Widget>[];
    void add(String id, WidgetBuilder builder) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 34));
      sections.add(_section(id, builder));
    }

    switch (_category) {
      case _StatisticsCategory.overview:
        add('overview', _overview);
      case _StatisticsCategory.rhythm:
        if (_modules.contains(ReadingReportModule.rhythm)) {
          add('rhythm', (context) => _rhythm(context, wide: wide));
        }
        if (_modules.contains(ReadingReportModule.calendar) && _hasDays) {
          add('calendar', _calendar);
        }
      case _StatisticsCategory.books:
        if (_modules.contains(ReadingReportModule.books) &&
            (_hasBreadth || _hasBookAnalysis)) {
          add('breadth', _breadth);
        }
        if (_modules.contains(ReadingReportModule.progress) && _hasProgress) {
          add('progress', _progress);
        }
        if (_modules.contains(ReadingReportModule.collection) &&
            _hasCollection) {
          add('collection', (context) => _collection(context, wide: wide));
        }
      case _StatisticsCategory.marks:
        if (_modules.contains(ReadingReportModule.excerpts) && _hasMarks) {
          add('excerpts', _excerpts);
        }
        if (widget.state.readingMoments.moments.isNotEmpty) {
          add('moments', (_) => _momentsEntry());
        }
      case _StatisticsCategory.touch:
        break;
    }
    return sections;
  }

  Widget _momentsEntry() => FeatureEntry(
    key: const ValueKey('statistics-reading-moments'),
    title: '阅读纪念',
    subtitle: '每一次相伴，都值得留存',
    icon: CupertinoIcons.bookmark_fill,
    onTap: () => showReadingMomentsHistory(
      context,
      store: widget.state.readingMoments,
      reduceMotion: widget.state.reduceMotion,
    ),
  );

  Widget _overview(BuildContext context) {
    final data = _data;
    final hasContent =
        _hasDays ||
        _hasProgress ||
        _hasCollection ||
        _hasMarks ||
        data.analysis.coverage.hasTimeDetail ||
        widget.state.readingMoments.moments.isNotEmpty;
    if (!hasContent) {
      return Padding(
        key: const ValueKey('statistics-empty'),
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ArchiveIcon(CupertinoIcons.book, size: 32),
            const SizedBox(height: 20),
            AppText(
              '下一次翻页，从这里开始',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            AppText(
              '阅读、收藏或留下记号后，再来看看自己的阅读轨迹。',
              style: _muted(context).copyWith(fontSize: 14, height: 1.7),
            ),
            const SizedBox(height: 20),
            GlassTextButton(
              compact: true,
              onPressed: () => Navigator.maybePop(context),
              child: const AppText('返回阅读'),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读总览', code: 'READING / AT A GLANCE'),
        const SizedBox(height: 20),
        if (_hasDays || data.analysis.coverage.hasTimeDetail) ...[
          AppText(
            _hasDays ? '所选区间 · 阅读时长' : '已测时段 · 阅读时长',
            style: _muted(context),
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _Number(
              statisticsDuration(
                _hasDays ? data.periodSeconds : data.analysis.measuredSeconds,
              ),
              size: 38,
            ),
          ),
          const SizedBox(height: 24),
          if (_hasDays)
            _Metrics([
              _Metric('活跃天数', '${data.activeDays}', '天'),
              if (_hasBreadth) _Metric('读过的书', '${data.periodBooks}', '本'),
              _Metric('日均阅读', '${data.averageSeconds ~/ 60}', '分钟'),
            ]),
          if (_hasDays) ...[const SizedBox(height: 24), _insight(context)],
        ],
        if (_hasCollection || _hasProgress || _hasMarks) ...[
          const SizedBox(height: 30),
          AppText(
            '当前文库 · ${_now.year}.${_now.month}.${_now.day}',
            style: _muted(context),
          ),
          const SizedBox(height: 16),
          _Metrics([
            if (_hasCollection)
              _Metric('藏书', '${data.onlineBooks + data.localBooks}', '本'),
            if (_hasProgress) _Metric('有阅读记录', '${data.readingBooks}', '本'),
            if (_hasMarks)
              _Metric('保存的记号', '${data.bookmarks + data.underlines}', '条'),
          ]),
        ],
        if (widget.state.readingMoments.moments.isNotEmpty) ...[
          const SizedBox(height: 28),
          _momentsEntry(),
        ],
      ],
    );
  }

  Widget _rhythm(BuildContext context, {required bool wide}) {
    final data = _data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读节律', code: 'READING / RHYTHM'),
        if (_hasDays) ...[
          const SizedBox(height: 22),
          ReadingRhythmChart(
            entrance: ArchiveMotionScope.maybeOf(context)?.animation,
            reduceMotion: widget.state.reduceMotion,
            dates: data.dates,
            minutes: data.minutes,
            averageMinutes: data.averageMinutes,
            selectedIndex: _selected,
            onSelected: (value) => setState(() => _selected = value),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppText(
                  statisticsDate(data.dates[_selected]),
                  style: _muted(context),
                ),
              ),
              if (data.seconds[_selected] case final seconds?)
                Flexible(
                  child: AppText(
                    statisticsDuration(seconds),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
        ReadingStatisticsAnalysisView(
          bookFor: _knownBook,
          data: data,
          module: ReadingReportModule.rhythm,
        ),
      ],
    );
  }

  Widget _insight(BuildContext context) {
    final data = _data;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      key: const ValueKey('statistics-period-insight'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .055),
        border: Border(left: BorderSide(color: accent, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppText(
                  data.peakDate == null
                      ? '让下一次翻页成为起点'
                      : '${statisticsDate(data.peakDate!)}，是这段时间最投入的一天',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.6,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ReadingActivityRing(
                ratio: data.activeRatio,
                size: 56,
                reduceMotion: widget.state.reduceMotion,
              ),
            ],
          ),
          const SizedBox(height: 7),
          AppText(
            data.activeRatio == null
                ? '尚未开始记录'
                : '活跃占比 ${(data.activeRatio! * 100).round()}%  ·  ${data.activeDays == 0 ? '暂无活跃日' : '活跃日平均 ${statisticsDuration(data.activeAverageSeconds)}'}${data.peakDate == null ? '' : '  ·  峰值 ${statisticsDuration(data.peakSeconds)}'}',
            style: _muted(context).copyWith(height: 1.7),
          ),
          if (data.hasCompleteComparison) ...[
            const SizedBox(height: 6),
            AppText(
              '上一个 $_period 天：${statisticsDuration(data.previousPeriodSeconds)}${data.previousPeriodSeconds == 0 ? '' : '  ·  本期${data.periodSeconds >= data.previousPeriodSeconds ? '增加' : '减少'} ${statisticsDuration((data.periodSeconds - data.previousPeriodSeconds).abs())}'}',
              style: _muted(context).copyWith(height: 1.6),
            ),
          ],
        ],
      ),
    );
  }

  Widget _breadth(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const ArchiveSection(title: '阅读的广度', code: '02 / BOOKS ALONG THE WAY'),
      if (_hasBreadth) ...[
        const SizedBox(height: 14),
        AppText('每天读过的书 · 本', style: _muted(context)),
        const SizedBox(height: 12),
        ReadingBookBreadthChart(dates: _data.dates, counts: _data.bookCounts),
      ],
      ReadingStatisticsAnalysisView(
        bookFor: _knownBook,
        data: _data,
        module: ReadingReportModule.books,
      ),
    ],
  );

  Widget _calendar(BuildContext context) {
    final data = _data;
    final selected = _calendarSelection ?? data.today;
    final index = data.dates.indexOf(selected);
    final seconds = index < 0 ? null : data.seconds[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '阅读日历', code: '02 / CONSISTENCY'),
        const SizedBox(height: 20),
        _Metrics([
          _Metric('截至区间末连续', '${data.currentStreak}', '天'),
          _Metric('区间最长连续', '${data.analysis.longestStreak.days}', '天'),
        ]),
        const SizedBox(height: 22),
        ReadingActivityCalendar(
          entrance: ArchiveMotionScope.maybeOf(context)?.animation,
          reduceMotion: widget.state.reduceMotion,
          dates: data.dates,
          seconds: data.seconds,
          selectedDate: selected,
          onSelected: (date) => setState(() => _calendarSelection = date),
        ),
        const SizedBox(height: 12),
        if (seconds != null)
          AppText(
            '${statisticsDate(selected)} · ${statisticsDuration(seconds)}',
            style: _muted(context),
          ),
        ReadingStatisticsAnalysisView(
          bookFor: _knownBook,
          data: data,
          module: ReadingReportModule.calendar,
        ),
      ],
    );
  }

  List<({String quote, String? title, String chapter})> _savedExcerpts() {
    final entries = libraryBookmarks(
      widget.state,
      books: widget.state.localLibrary,
    );
    return [
      for (final entry in entries)
        if (entry.bookmark.quote.trim().isNotEmpty)
          (
            quote: entry.bookmark.quote.trim(),
            title: _knownTitle(_knownBook(entry.novelId)),
            chapter: entry.bookmark.chapterTitle.trim(),
          ),
    ];
  }

  Novel? _knownBook(int id) {
    final repository = widget.repository;
    final offline = repository is OfflineNovelRepository ? repository : null;
    return widget.state.localLibrary?.novelFor(id) ??
        widget.state.cachedNovel(id) ??
        offline?.cache.book(id)?.novel;
  }

  String? _knownTitle(Novel? book) {
    final title = book?.title.trim();
    return title == null || title.isEmpty ? null : title;
  }

  Widget _excerpts(BuildContext context) {
    final excerpts = _savedExcerpts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '书页回声', code: 'CURRENT / SAVED EXCERPTS'),
        const SizedBox(height: 18),
        AppText(
          '当前保存 · ${_now.year}.${_now.month}.${_now.day}',
          style: _muted(context),
        ),
        const SizedBox(height: 14),
        _Metrics([
          _Metric('书签', '${_data.bookmarks}', '条'),
          _Metric('划线', '${_data.underlines}', '条'),
        ]),
        const SizedBox(height: 16),
        GlassTextButton(
          compact: true,
          onPressed: () => pushNovelPage<void>(
            context,
            BookmarkLibraryPage(
              state: widget.state,
              repository: widget.repository,
            ),
            reduceMotion: widget.state.reduceMotion,
          ),
          child: const AppText('查看书签与划线'),
        ),
        ReadingStatisticsAnalysisView(
          bookFor: _knownBook,
          data: _data,
          module: ReadingReportModule.excerpts,
        ),
        if (excerpts.isNotEmpty) ...[
          const SizedBox(height: 22),
          AppText('保存的引用 · 全部记录', style: _muted(context)),
          const SizedBox(height: 18),
        ],
        for (final excerpt in excerpts.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 20, left: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      excerpt.quote,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, height: 1.8),
                    ),
                    if (excerpt.title != null || excerpt.chapter.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: AppText(
                          [
                            if (excerpt.title != null) '《${excerpt.title}》',
                            if (excerpt.chapter.isNotEmpty) excerpt.chapter,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: _muted(context),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final data = _data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '书页足迹', code: '03 / READING & EXCERPTS'),
        if (data.readingBooks > 0) ...[
          const SizedBox(height: 20),
          AppText(
            '当前阅读进度 · ${_now.year}.${_now.month}.${_now.day}',
            style: _muted(context),
          ),
          const SizedBox(height: 16),
          _Metrics([
            _Metric('有阅读记录', '${data.readingBooks}', '本'),
            _Metric('进度到末尾', '${data.finishedBooks}', '本'),
          ]),
        ],
        if (data.progressBands.any((count) => count > 0)) ...[
          const SizedBox(height: 22),
          _statisticsArrival(
            context,
            start: .18,
            end: .7,
            child: AppText('当前阅读进度', style: _label),
          ),
          const SizedBox(height: 8),
          ReadingProgressBands(
            bands: data.progressBands,
            reduceMotion: widget.state.reduceMotion,
          ),
          const SizedBox(height: 10),
          AppText('按当前已读取目录的章节进度估算。', style: _muted(context)),
        ],
        ReadingStatisticsAnalysisView(
          bookFor: _knownBook,
          data: data,
          module: ReadingReportModule.progress,
        ),
      ],
    );
  }

  Widget _collection(BuildContext context, {required bool wide}) {
    final data = _data;
    final scheme = Theme.of(context).colorScheme;
    final total = data.onlineBooks + data.localBooks;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Metrics([
          _Metric('在线书架', '${data.onlineBooks}', '本'),
          _Metric('本地书籍', '${data.localBooks}', '本'),
          if (data.authorCount > 0) _Metric('已知作者', '${data.authorCount}', '位'),
        ], columns: 3),
        const SizedBox(height: 20),
        ArchivePart(
          start: .18,
          end: .88,
          child: ExcludeSemantics(
            child: Row(
              children: total == 0
                  ? [
                      Expanded(
                        child: Container(
                          height: 5,
                          color: scheme.outlineVariant,
                        ),
                      ),
                    ]
                  : [
                      if (data.onlineBooks > 0)
                        Expanded(
                          flex: data.onlineBooks,
                          child: Container(height: 5, color: scheme.onSurface),
                        ),
                      if (data.onlineBooks > 0 && data.localBooks > 0)
                        const SizedBox(width: 3),
                      if (data.localBooks > 0)
                        Expanded(
                          flex: data.localBooks,
                          child: Container(
                            height: 5,
                            color: scheme.onSurface.withValues(alpha: .3),
                          ),
                        ),
                    ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        AppText('共 $total 本藏书', style: _muted(context)),
      ],
    );
    final authors = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statisticsArrival(
          context,
          start: .12,
          end: .68,
          child: AppText('藏书最多的作者', style: _label),
        ),
        const SizedBox(height: 12),
        if (data.authors.isNotEmpty)
          for (var index = 0; index < data.authors.length; index++)
            ArchivePart(
              start: .12 + index * .045,
              end: .7 + index * .045,
              travel: const Offset(0, 5),
              child: _RankLine(
                label: data.authors[index].name,
                value: data.authors[index].books,
                maximum: data.authors.first.books,
                unit: '本',
              ),
            ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ArchiveSection(title: '我的藏书', code: '04 / COLLECTION'),
        const SizedBox(height: 20),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: summary),
              if (data.authors.isNotEmpty) ...[
                const SizedBox(width: 40),
                Expanded(child: authors),
              ],
            ],
          )
        else ...[
          summary,
          if (data.authors.isNotEmpty) ...[const SizedBox(height: 28), authors],
        ],
        ReadingStatisticsAnalysisView(
          bookFor: _knownBook,
          data: data,
          module: ReadingReportModule.collection,
        ),
      ],
    );
  }
}

const _label = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
TextStyle _muted(BuildContext context) => TextStyle(
  fontSize: 12,
  height: 1.4,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);

Widget _statisticsArrival(
  BuildContext context, {
  required Widget child,
  required double start,
  required double end,
}) {
  final scope = ArchiveMotionScope.maybeOf(context);
  if (scope == null ||
      !scope.enabled ||
      MediaQuery.disableAnimationsOf(context)) {
    return child;
  }
  final progress = scope.animation.drive(
    CurveTween(curve: Interval(start, end, curve: Curves.easeOutCubic)),
  );
  return FadeTransition(
    opacity: progress,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, .12),
        end: Offset.zero,
      ).animate(progress),
      child: RepaintBoundary(child: child),
    ),
  );
}

class _Number extends StatelessWidget {
  const _Number(this.value, {this.size = 29});
  final String value;
  final double size;
  @override
  Widget build(BuildContext context) => AppText(
    value,
    style: TextStyle(
      fontSize: size,
      height: 1.1,
      fontWeight: FontWeight.w500,
      letterSpacing: -1,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.unit);
  final String label, value, unit;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label $value $unit',
    excludeSemantics: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(label, style: _muted(context)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 5,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _ChangingValue(value: value, child: _Number(value)),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: AppText(unit, style: _muted(context)),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Metrics extends StatelessWidget {
  const _Metrics(this.children, {this.columns = 2});
  final List<Widget> children;
  final int columns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaled = MediaQuery.textScalerOf(context).scale(12) > 17;
      final count = scaled ? 2 : columns;
      final width = (constraints.maxWidth - 14 * (count - 1)) / count;
      return Wrap(
        spacing: 14,
        runSpacing: 20,
        children: [
          for (var index = 0; index < children.length; index++)
            SizedBox(
              width: width,
              child: _statisticsArrival(
                context,
                start: .1 + index * .06,
                end: .66 + index * .06,
                child: children[index],
              ),
            ),
        ],
      );
    },
  );
}

class _RankLine extends StatelessWidget {
  const _RankLine({
    required this.label,
    required this.value,
    required this.maximum,
    required this.unit,
  });
  final String label, unit;
  final int value, maximum;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppText(label, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 12),
              AppText('$value $unit', style: _muted(context)),
            ],
          ),
          const SizedBox(height: 7),
          ExcludeSemantics(
            child: LinearProgressIndicator(
              value: maximum <= 0 ? 0 : value / maximum,
              minHeight: 2,
              color: scheme.onSurface.withValues(alpha: .72),
              backgroundColor: scheme.outlineVariant.withValues(alpha: .55),
            ),
          ),
        ],
      ),
    );
  }
}

/// All foreground parts in a section share one short-lived clock. Revisiting a
/// scrolled-out section shows its settled state, rather than replaying a show.
class _StatisticsSection extends StatefulWidget {
  const _StatisticsSection({
    super.key,
    required this.seen,
    required this.onSeen,
    required this.reduceMotion,
    required this.builder,
  });
  final bool seen, reduceMotion;
  final VoidCallback onSeen;
  final WidgetBuilder builder;

  @override
  State<_StatisticsSection> createState() => _StatisticsSectionState();
}

class _StatisticsSectionState extends State<_StatisticsSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  bool _started = false;
  bool get _reduced =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      if (widget.seen || _reduced) {
        _clock.value = 1;
      } else {
        _clock.forward();
      }
      widget.onSeen();
    } else if (_reduced) {
      _clock.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant _StatisticsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reduced) _clock.value = 1;
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArchiveMotionScope(
    animation: _clock,
    enabled: !_reduced,
    child: Builder(builder: widget.builder),
  );
}

/// Actual values exchange softly; no counting through invented measurements.
class _ChangingValue extends StatelessWidget {
  const _ChangingValue({required this.value, required this.child});
  final Object value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        ArchiveMotionScope.maybeOf(context)?.enabled == false;
    if (reduced) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [
          for (final child in previous) ExcludeSemantics(child: child),
          ?current,
        ],
      ),
      transitionBuilder: (child, progress) => FadeTransition(
        opacity: progress,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, .13),
            end: Offset.zero,
          ).animate(progress),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(value), child: child),
    );
  }
}
