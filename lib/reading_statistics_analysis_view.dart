import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'reading_analysis_charts.dart';
import 'reading_statistics_data.dart';
import 'reading_report_options.dart';

/// The selected-interval analysis. Current inventory stays in the existing panel.
class ReadingStatisticsAnalysisView extends StatelessWidget {
  const ReadingStatisticsAnalysisView({
    super.key,
    required this.data,
    required this.module,
    this.bookFor,
  });
  final ReadingStatisticsData data;
  final ReadingReportModule module;
  final Novel? Function(int id)? bookFor;

  @override
  Widget build(BuildContext context) {
    final children = _AnalysisContent(
      context,
      data,
      bookFor: bookFor,
    ).childrenFor(module);
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      key: ValueKey('statistics-analysis-${module.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _AnalysisContent {
  _AnalysisContent(this.context, this.data, {this.bookFor}) {
    for (final book in [
      ...data.collectionBooks,
      for (final item in a.booksByDuration)
        if (item.book != null) item.book!,
    ]) {
      _metadata.putIfAbsent(book.id, () => []).add(book);
    }
  }
  final BuildContext context;
  final ReadingStatisticsData data;
  final Novel? Function(int id)? bookFor;
  final _metadata = <int, List<Novel>>{};
  ReadingStatisticsAnalysis get a => data.analysis;

  String? titleFor(int id) => _fieldFor(id, (book) => book.title);
  String? genreFor(int id) => _fieldFor(id, (book) => book.genre);
  String titleLineFor(int id) {
    final title = titleFor(id);
    return title == null ? '' : '\n《$title》';
  }

  Novel? coverFor(int id) =>
      _booksFor(id).where((book) => book.title.trim().isNotEmpty).firstOrNull;

  Iterable<Novel> _booksFor(int id) sync* {
    if (bookFor?.call(id) case final book?) yield book;
    yield* _metadata[id] ?? const <Novel>[];
  }

  String? _fieldFor(int id, String Function(Novel) field) {
    for (final book in _booksFor(id)) {
      final value = field(book).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  TextStyle get muted => TextStyle(
    fontSize: 13,
    height: 1.6,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  Widget title(String value) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 14),
    child: AppText(
      value,
      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
    ),
  );
  Widget note(String value) => Padding(
    padding: const EdgeInsets.only(top: 9),
    child: AppText(value, style: muted),
  );
  Widget fact(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: LayoutBuilder(
      builder: (context, constraints) {
        if (MediaQuery.textScalerOf(context).scale(13) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(label, style: muted),
              const SizedBox(height: 4),
              AppText(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: AppText(label, style: muted)),
            const SizedBox(width: 16),
            Flexible(
              child: AppText(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
  String percent(double v) => '${(v * 100).toStringAsFixed(1)}%';
  String change(double v) =>
      '${v >= 0 ? '+' : '−'}${(v.abs() * 100).toStringAsFixed(1)}%';
  String date(DateTime v) =>
      '${v.year}.${v.month.toString().padLeft(2, '0')}.${v.day.toString().padLeft(2, '0')}';
  String clock(DateTime v) =>
      '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
  List<Widget> childrenFor(ReadingReportModule module) {
    final children = <Widget>[];
    final months = a.months.where((m) => m.totalSeconds != null).toList();
    final weekdays = a.weekdaysSeconds.indexed
        .where((entry) => entry.$2 != null)
        .toList();
    final measuredMonths = a.months
        .where((m) => m.measuredMilliseconds > 0)
        .toList();
    final nightBooks =
        a.booksByDuration
            .where((b) => b.nightMilliseconds > 0 && titleFor(b.id) != null)
            .toList()
          ..sort((a, b) => b.nightMilliseconds.compareTo(a.nightMilliseconds));
    switch (module) {
      case ReadingReportModule.rhythm:
        children.addAll([
          if (months.isNotEmpty) ...[
            title('月份之间'),
            note(
              '${months.first.date.year}.${months.first.date.month.toString().padLeft(2, '0')}—${months.last.date.year}.${months.last.date.month.toString().padLeft(2, '0')} · 小时',
            ),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.bars,
              semanticLabel: '月阅读时长，小时',
              data: [
                for (final m in months)
                  ReadingAnalysisDatum(
                    '${m.date.month}',
                    m.totalSeconds! / 3600,
                  ),
              ],
            ),
            for (final m in months)
              fact(
                '${m.date.year}.${m.date.month.toString().padLeft(2, '0')}${m.isComplete ? '' : ' · 部分月份'}',
                '${statisticsDuration(m.totalSeconds!)}${m.changeRatio == null ? '' : ' · ${change(m.changeRatio!)}'}',
              ),
          ],
          if (a.halves.comparable)
            fact(
              '上半年 / 下半年',
              '${statisticsDuration(a.halves.firstSeconds!)} / ${statisticsDuration(a.halves.secondSeconds!)}',
            ),
          if (a.halves.comparable && a.halves.changeRatio != null)
            note('下半年相对上半年 ${change(a.halves.changeRatio!)}'),
          if (weekdays.isNotEmpty) ...[
            title('一周的阅读节律'),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.bars,
              semanticLabel: '各星期累计阅读时长，小时',
              data: [
                for (final entry in weekdays)
                  ReadingAnalysisDatum(_weekdays[entry.$1], entry.$2! / 3600),
              ],
            ),
            note('按已记录的自然日累计 · 单位：小时'),
          ],
          if (a.coverage.hasTimeDetail) ...[
            title('一天里的阅读时刻'),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.radial,
              semanticLabel: '24小时阅读分布，小时',
              height: 275,
              data: [
                for (var i = 0; i < 24; i++)
                  ReadingAnalysisDatum('$i时', a.hourMilliseconds[i] / 3600000),
              ],
            ),
            note('深色时段为夜读 22:00–06:00；时长按发生地自然日拆分。'),
          ],
          if (a.latestReading case final latest?)
            fact(
              '最晚的那一页',
              '${date(latest.at)} ${clock(latest.at)}${titleLineFor(latest.bookId)}',
            ),
          if (a.longestSession case final session?)
            fact(
              '最长一次连续阅读',
              '${_measuredDuration(session.milliseconds)}\n${date(session.start)} ${clock(session.start)}—${date(session.end) == date(session.start) ? '' : '${date(session.end)} '}${clock(session.end)}${titleLineFor(session.bookId)}${session.isClipped ? '\n仅计本区间内时长' : ''}',
            ),
          if (a.sessionLengths.hasData) ...[
            title('一次阅读的长度'),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.horizontal,
              height: a.sessionLengths.buckets.length * 48,
              semanticLabel: '完整阅读会话长度分布，次',
              data: [
                for (final bucket in a.sessionLengths.buckets)
                  ReadingAnalysisDatum(bucket.label, bucket.count.toDouble()),
              ],
            ),
            note(
              '${a.sessionLengths.completeSessionCount} 次完整会话 · ${_measuredDuration(a.sessionLengths.completeMilliseconds)}${a.sessionLengths.excludedClippedSessionCount > 0 ? '；跨出区间的 ${a.sessionLengths.excludedClippedSessionCount} 次会话不参与分组' : ''}',
            ),
          ],
          if (a.coverage.hasTimeDetail) ...[
            title('夜色里的书页'),
            fact(
              '夜读时长 / 已测时段',
              '${_measuredDuration(a.nightMilliseconds)} / ${_measuredDuration(a.measuredMilliseconds)}',
            ),
            fact('夜读占比', percent(a.nightRatio!)),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.nightOverlay,
              semanticLabel: '月时段明细与夜读时长，小时',
              data: [
                for (final m in measuredMonths)
                  ReadingAnalysisDatum(
                    '${m.date.month}',
                    m.measuredMilliseconds / 3600000,
                    secondary: m.nightMilliseconds / 3600000,
                  ),
              ],
            ),
            note('浅色：有时段明细的总时长 · 深色：其中的夜读'),
            if (nightBooks.isNotEmpty) ...[
              title('夜读书目 · 小时'),
              ReadingAnalysisChart(
                kind: ReadingAnalysisChartKind.horizontal,
                height: nightBooks.take(5).length * 46,
                semanticLabel: '夜读书目小时',
                data: [
                  for (final b in nightBooks.take(5))
                    ReadingAnalysisDatum(
                      '${titleFor(b.id)!} · ${percent(b.nightRatio!)}',
                      b.nightMilliseconds / 3600000,
                    ),
                ],
              ),
            ],
            note('夜读比例以已测时段为分母；最晚时刻按 06:00 起的一天排序。'),
          ],
          if (a.coverage.hasTimeDetail && a.marks.items.isNotEmpty)
            fact(
              '夜读时留下',
              '${a.marks.nightBookmarks} 个书签 · ${a.marks.nightExcerpts} 条摘录',
            ),
        ]);
      case ReadingReportModule.books:
        final ranked = a.booksByDuration
            .where((b) => b.seconds != null && titleFor(b.id) != null)
            .toList();
        final namedBookSeconds = ranked.fold<int>(
          0,
          (sum, book) => sum + book.seconds!,
        );
        final books = ranked.take(5).toList();
        final journey = a.booksByDuration
            .where(
              (b) =>
                  titleFor(b.id) != null &&
                  (b.activeMonths.isNotEmpty ||
                      b.firstOpenedAt != null &&
                          _withinRange(b.firstOpenedAt!, a) ||
                      b.completedAt != null && _withinRange(b.completedAt!, a)),
            )
            .take(5)
            .toList();
        children.addAll([
          if (books.isNotEmpty) ...[
            title('时间留给了这些书'),
            note('按本期已记录的单书阅读时长排序'),
            for (final (i, b) in books.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: MediaQuery.textScalerOf(context).scale(30),
                      child: AppText(
                        '${i + 1}'.padLeft(2, '0'),
                        style: const TextStyle(fontSize: 19),
                      ),
                    ),
                    if (coverFor(b.id) case final cover?) ...[
                      NovelCover(cover, width: 47, height: 66),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText(
                            titleFor(b.id)!,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 7),
                          AppText(
                            '${b.seconds == 0 && b.measuredMilliseconds > 0 ? _measuredDuration(b.measuredMilliseconds) : statisticsDuration(b.seconds!)}${b.hasPartialTimeCoverage ? ' · 部分时长' : ''}',
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (books.any((b) => (b.seconds ?? 0) > 0)) ...[
            title('单书时间贡献'),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.share,
              height:
                  45 +
                  (books.length + (ranked.length > books.length ? 1 : 0)) * 26,
              semanticLabel: '单书已测时长贡献百分比',
              data: [
                for (final b in books)
                  ReadingAnalysisDatum(titleFor(b.id)!, b.seconds?.toDouble()),
                if (ranked.length > books.length)
                  ReadingAnalysisDatum(
                    '其余书目',
                    ranked
                        .skip(books.length)
                        .fold<double>(0, (sum, b) => sum + (b.seconds ?? 0)),
                  ),
              ],
            ),
            note('分母：有书名的已测单书时长 ${statisticsDuration(namedBookSeconds)}'),
          ],
          if (a.bookDayDistribution.hasData) ...[
            title('一天读几本'),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.bars,
              semanticLabel: '单日阅读书数分布，天',
              data: [
                for (final bucket in a.bookDayDistribution.buckets)
                  ReadingAnalysisDatum(bucket.label, bucket.days.toDouble()),
              ],
            ),
            note(
              '按 ${a.bookDayDistribution.attributedActiveDays} 个有书目归属的活跃日计，不代表同时阅读。',
            ),
          ],
          if (journey.isNotEmpty) ...[
            title('从初见到合卷'),
            for (var start = 0; start < a.months.length; start += 6)
              _BookJourneySegment(
                books: journey,
                months: a.months.skip(start).take(6).toList(),
                titleFor: (id) => titleFor(id)!,
              ),
            note('色段：该月读过 · 圆：首次翻开 · 菱形：完成\n空段保留中断。'),
            for (final b in journey)
              if (b.firstOpenedAt != null || b.completedAt != null)
                fact(
                  titleFor(b.id)!,
                  [
                    if (b.firstOpenedAt != null) '初见 ${date(b.firstOpenedAt!)}',
                    if (b.completedAt != null)
                      '${b.finished == true ? '完成' : '到达连载末尾'} ${date(b.completedAt!)}',
                  ].join('\n'),
                ),
          ],
        ]);
      case ReadingReportModule.days:
      case ReadingReportModule.calendar:
        children.addAll([
          if (a.coverage.observedDays > 0) ...[
            fact(
              '区间活跃日占比',
              '${percent(a.coverageRatio)} · ${a.activeDays}/${a.coverage.selectedDays} 天',
            ),
            if (a.longestStreak.start case final start?)
              fact(
                '最长连续阅读段',
                '${date(start)}—${date(a.longestStreak.end!)} · ${a.longestStreak.days} 天',
              ),
            note(
              '已记录 ${a.coverage.observedDays}/${a.coverage.selectedDays} 个自然日。',
            ),
          ],
        ]);
      case ReadingReportModule.collection:
        final genreSeconds = <String, int>{};
        for (final book in a.booksByDuration) {
          final genre = genreFor(book.id);
          if (genre == null || book.seconds == null) continue;
          genreSeconds.update(
            genre,
            (seconds) => seconds + book.seconds!,
            ifAbsent: () => book.seconds!,
          );
        }
        final genres = genreSeconds.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final knownGenreSeconds = genres.fold<int>(
          0,
          (sum, genre) => sum + genre.value,
        );
        children.addAll([
          if (knownGenreSeconds > 0) ...[
            title('这段时间的阅读口味'),
            ReadingAnalysisChart(
              kind: ReadingAnalysisChartKind.treemap,
              height: 235,
              semanticLabel: '题材阅读时长占比',
              data: [
                for (final genre in genres)
                  ReadingAnalysisDatum(genre.key, genre.value.toDouble()),
              ],
            ),
            for (final genre in genres)
              fact(
                genre.key,
                '${statisticsDuration(genre.value)} · ${percent(genre.value / knownGenreSeconds)}',
              ),
            note(
              '每书使用当前主分类。分母：有已知题材的已测单书时长 ${statisticsDuration(knownGenreSeconds)}。',
            ),
          ],
        ]);
      case ReadingReportModule.progress:
        children.addAll([
          if (a.monthlyMilestones.hasData) ...[
            title('本期的初见与完成'),
            _MonthlyMilestones(summary: a.monthlyMilestones),
            note('按已知日期归入月份。'),
            if (a.firstOpenedBooks.isNotEmpty)
              fact('有首次翻开记录', '${a.firstOpenedBooks.length} 本'),
            if (a.completedBooks.isNotEmpty)
              fact('有完成日期记录', '${a.completedBooks.length} 本'),
            for (final book
                in a.firstOpenedBooks
                    .where((book) => titleFor(book.id) != null)
                    .take(10))
              fact('初见 · ${date(book.firstOpenedAt!)}', titleFor(book.id)!),
            for (final book
                in a.completedBooks
                    .where((book) => titleFor(book.id) != null)
                    .take(10))
              fact('完成 · ${date(book.completedAt!)}', titleFor(book.id)!),
            note('以上为所选区间事件；当前进度与库存是 ${date(a.snapshotAt)} 的快照。'),
          ],
        ]);
      case ReadingReportModule.excerpts:
        children.addAll([
          if (a.marks.items.isNotEmpty) ...[
            title('本期留下的记号'),
            fact('书签 / 摘录', '${a.marks.bookmarks} 个 / ${a.marks.excerpts} 条'),
            fact(
              '其中夜读时创建',
              '${a.marks.nightBookmarks} 个书签 / ${a.marks.nightExcerpts} 条摘录',
            ),
            for (final b
                in a.marks.byBook
                    .where((book) => titleFor(book.bookId) != null)
                    .take(5))
              fact(
                titleFor(b.bookId)!,
                '${b.bookmarks} 个书签 · ${b.excerpts} 条摘录',
              ),
            note('普通书签与含原文的摘录分别计数；同一条记录可同时属于两类。'),
          ],
        ]);
    }
    return children;
  }
}

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

String _measuredDuration(int milliseconds) =>
    milliseconds > 0 && milliseconds < 60000
    ? '不足 1 分钟'
    : statisticsDuration(milliseconds ~/ 1000);

String _month(DateTime value) =>
    '${value.year}.${value.month.toString().padLeft(2, '0')}';

bool _sameMonth(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month;

bool _withinRange(DateTime date, ReadingStatisticsAnalysis analysis) {
  final day = statisticsCivilDay(date);
  return !day.isBefore(analysis.start) && !day.isAfter(analysis.end);
}

class _BookJourneySegment extends StatelessWidget {
  const _BookJourneySegment({
    required this.books,
    required this.months,
    required this.titleFor,
  });
  final List<StatisticsAnalysisBook> books;
  final List<StatisticsAnalysisMonth> months;
  final String Function(int id) titleFor;

  @override
  Widget build(BuildContext context) {
    bool inSegment(DateTime? date) =>
        date != null && months.any((month) => _sameMonth(date, month.date));
    final visible = books
        .where(
          (book) =>
              book.activeMonths.any(inSegment) ||
              inSegment(book.firstOpenedAt) ||
              book.finished == true && inSegment(book.completedAt),
        )
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 9, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            '${_month(months.first.date)}—${_month(months.last.date)}',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 9),
          Semantics(
            label: '书目月份足迹',
            value: [
              for (final book in visible)
                [
                  titleFor(book.id),
                  for (final month in book.activeMonths.where(inSegment))
                    '${month.year}年${month.month}月读过',
                  if (inSegment(book.firstOpenedAt))
                    '${book.firstOpenedAt!.month}月首次翻开',
                  if (book.finished == true && inSegment(book.completedAt))
                    '${book.completedAt!.month}月完成',
                ].join('，'),
            ].join('；'),
            child: ExcludeSemantics(
              child: ReadingAnalysisChart(
                kind: ReadingAnalysisChartKind.gantt,
                height: 35 + visible.length * 54,
                labels: months.map((month) => '${month.date.month}月').toList(),
                data: [
                  for (final book in visible)
                    ReadingAnalysisDatum(
                      titleFor(book.id),
                      book.seconds?.toDouble(),
                      cells: [
                        for (final month in months)
                          book.activeMonths.any(
                            (date) => _sameMonth(date, month.date),
                          ),
                      ],
                      first: months.indexWhere(
                        (month) =>
                            book.firstOpenedAt != null &&
                            _sameMonth(book.firstOpenedAt!, month.date),
                      ),
                      completed: months.indexWhere(
                        (month) =>
                            book.finished == true &&
                            book.completedAt != null &&
                            _sameMonth(book.completedAt!, month.date),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthlyMilestones extends StatelessWidget {
  const _MonthlyMilestones({required this.summary});
  final StatisticsMonthlyMilestones summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maximum = summary.months
        .expand((month) => [month.openedBooks, month.completedBooks])
        .reduce((a, b) => a > b ? a : b);
    return Column(
      key: const ValueKey('statistics-monthly-milestones'),
      children: [
        for (final month in summary.months.where((month) => month.hasEvents))
          Padding(
            padding: const EdgeInsets.only(bottom: 17),
            child: Semantics(
              label:
                  '${_month(month.date)}，首次翻开${month.openedBooks}本，完成${month.completedBooks}本',
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      _month(month.date),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 7),
                    for (final item in [
                      (
                        '初见',
                        month.openedBooks,
                        scheme.primary.withValues(alpha: .35),
                      ),
                      ('完成', month.completedBooks, scheme.primary),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            SizedBox(
                              width: MediaQuery.textScalerOf(context).scale(32),
                              child: AppText(
                                item.$1,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) => Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width:
                                        constraints.maxWidth *
                                        item.$2 /
                                        maximum,
                                    height: 5,
                                    child: ColoredBox(color: item.$3),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            AppText(
                              '${item.$2}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
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
}
