import 'dart:math' as math;

import 'catalog.dart';
import 'reading_activity.dart';
import 'reading_report_dimensions.dart';

export 'reading_report_dimensions.dart';

/// Calendar components, not a UTC instant. Do not call toLocal() on this value.
DateTime statisticsCivilDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _month(DateTime value) => DateTime.utc(value.year, value.month);
int _dayNumber(DateTime value) =>
    statisticsCivilDay(value).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;
bool _night(int hour) => hour >= 22 || hour < 6;

/// One immutable analysis of the selected calendar range. Legacy daily totals
/// remain useful, but never become invented hours, book time or sessions.
class ReadingStatisticsAnalysis {
  factory ReadingStatisticsAnalysis({
    required ReadingActivityStore activity,
    required DateTime start,
    required DateTime end,
    required DateTime snapshotAt,
    Novel? Function(int id)? bookFor,
    Iterable<StatisticsMarkRecord> marks = const [],
    Iterable<StatisticsCompletionRecord> completions = const [],
  }) {
    start = statisticsCivilDay(start);
    end = statisticsCivilDay(end);
    if (end.isBefore(start)) throw ArgumentError('Reversed statistics range');
    final startNumber = _dayNumber(start), endNumber = _dayNumber(end);
    bool selected(DateTime value) {
      final number = _dayNumber(value);
      return number >= startNumber && number <= endNumber;
    }

    final recordedDays = activity.days;
    // Daily keys already preserve their recording-zone date. The legacy
    // startedAt timestamp has no offset and may fall on another date after travel.
    final trackedDay = recordedDays.isEmpty
        ? null
        : recordedDays
              .map((day) => statisticsCivilDay(day.date))
              .reduce((a, b) => a.isBefore(b) ? a : b);
    final dayByNumber = {
      for (final day in recordedDays) _dayNumber(day.date): day,
    };
    final days = <StatisticsAnalysisDay>[];
    final monthBuilders = <DateTime, _MonthBuilder>{};
    final weekdayTotals = List.filled(7, 0);
    final weekdayObserved = List.filled(7, 0);
    final bookDates = <int, List<DateTime>>{};
    var total = 0, active = 0, observed = 0;
    var run = 0, longest = 0;
    DateTime? runStart, longestStart, longestEnd;
    for (var number = startNumber; number <= endNumber; number++) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        number * Duration.millisecondsPerDay,
        isUtc: true,
      );
      final recorded = trackedDay != null && !date.isBefore(trackedDay);
      final source = dayByNumber[number];
      final seconds = recorded ? source?.seconds ?? 0 : null;
      final value = StatisticsAnalysisDay(date: date, seconds: seconds);
      days.add(value);
      final month = monthBuilders.putIfAbsent(_month(date), _MonthBuilder.new);
      month.selectedDays++;
      if (seconds != null) {
        total += seconds;
        observed++;
        month.observedDays++;
        month.seconds += seconds;
        weekdayObserved[date.weekday - 1]++;
        weekdayTotals[date.weekday - 1] += seconds;
      }
      if ((seconds ?? 0) > 0) {
        active++;
        if (run == 0) runStart = date;
        run++;
        if (run > longest) {
          longest = run;
          longestStart = runStart;
          longestEnd = date;
        }
        for (final id in source!.bookIds) {
          bookDates.putIfAbsent(id, () => []).add(date);
        }
      } else {
        run = 0;
      }
    }

    final hourMilliseconds = List.filled(24, 0);
    final weekHourMilliseconds = List.generate(7, (_) => List.filled(24, 0));
    final measuredBookMilliseconds = <int, int>{};
    final nightBookMilliseconds = <int, int>{};
    final detailDates = <DateTime>{};
    var measuredMilliseconds = 0, nightMilliseconds = 0, hourEntries = 0;
    StatisticsReadingEvent? latest;
    int lateRank(ReadingActivityInstant instant) {
      final at = instant.localDateTime;
      return ((at.hour + 18) % 24) * Duration.millisecondsPerHour +
          at.minute * Duration.millisecondsPerMinute +
          at.second * Duration.millisecondsPerSecond +
          at.millisecond;
    }

    for (final hour in activity.hours) {
      if (!selected(hour.date) || hour.milliseconds <= 0) continue;
      final date = statisticsCivilDay(hour.date);
      detailDates.add(date);
      measuredMilliseconds += hour.milliseconds;
      hourEntries++;
      hourMilliseconds[hour.hour] += hour.milliseconds;
      weekHourMilliseconds[date.weekday - 1][hour.hour] += hour.milliseconds;
      measuredBookMilliseconds.update(
        hour.bookId,
        (value) => value + hour.milliseconds,
        ifAbsent: () => hour.milliseconds,
      );
      final month = monthBuilders[_month(date)]!;
      month.measuredMilliseconds += hour.milliseconds;
      if (_night(hour.hour)) {
        nightMilliseconds += hour.milliseconds;
        month.nightMilliseconds += hour.milliseconds;
        nightBookMilliseconds.update(
          hour.bookId,
          (value) => value + hour.milliseconds,
          ifAbsent: () => hour.milliseconds,
        );
      }
      final instant = hour.latestReadingAt;
      if (latest == null ||
          lateRank(instant) > lateRank(latest.instant) ||
          lateRank(instant) == lateRank(latest.instant) &&
              instant.epochMilliseconds > latest.instant.epochMilliseconds) {
        latest = StatisticsReadingEvent(
          instant: instant,
          bookId: hour.bookId,
          title: bookFor?.call(hour.bookId)?.title ?? '书名待读取',
        );
      }
    }

    final completionRecords = completions.toList(growable: false);
    final completionByBook = <int, StatisticsCompletionRecord>{};
    for (final completion in completionRecords) {
      // A completion after the selected range must not leak into a past report.
      final at = completion.at;
      if (at == null || _dayNumber(at) > endNumber) continue;
      final previous = completionByBook[completion.bookId];
      if (previous == null ||
          completion.finished && !previous.finished ||
          completion.finished == previous.finished &&
              at.isBefore(previous.at!)) {
        completionByBook[completion.bookId] = completion;
      }
    }
    final openedIds = {
      for (final day in recordedDays)
        if (selected(day.date)) ...day.bookIds,
      ...measuredBookMilliseconds.keys,
      for (final entry in activity.firstOpenedAt.entries)
        if (selected(entry.value.date)) entry.key,
    };
    final ids = {
      ...openedIds,
      for (final entry in completionByBook.entries)
        if (selected(entry.value.at!)) entry.key,
    };
    final perBookDays = <int, Map<int, int>>{};
    final allocatedByDay = <int, int>{};
    for (final id in ids) {
      final measured = <int, int>{};
      for (final day in activity.daysForBook(id)) {
        if (!selected(day.date)) continue;
        final dayNumber = _dayNumber(day.date);
        measured[dayNumber] = day.seconds;
        allocatedByDay.update(
          dayNumber,
          (value) => value + day.seconds,
          ifAbsent: () => day.seconds,
        );
      }
      perBookDays[id] = measured;
    }
    final books = <StatisticsAnalysisBook>[];
    for (final id in ids) {
      final book = bookFor?.call(id);
      final knownDates = bookDates[id] ?? const <DateTime>[];
      final measured = perBookDays[id]!;
      final firstOpen = activity.firstOpenedAt[id];
      final completion = completionByBook[id];
      final allKnownDates =
          recordedDays
              .where(
                (day) =>
                    day.bookIds.contains(id) &&
                    _dayNumber(day.date) <= endNumber,
              )
              .map((day) => statisticsCivilDay(day.date))
              .toList()
            ..sort();
      books.add(
        StatisticsAnalysisBook(
          id: id,
          title: book?.title ?? completion?.title ?? '书名待读取',
          book: book,
          seconds: measured.isEmpty
              ? null
              : measured.values.fold<int>(0, (a, b) => a + b),
          measuredMilliseconds: measuredBookMilliseconds[id] ?? 0,
          nightMilliseconds: nightBookMilliseconds[id] ?? 0,
          activeDates: knownDates,
          firstOpenedAt:
              firstOpen != null && _dayNumber(firstOpen.date) <= endNumber
              ? firstOpen.localDateTime
              : null,
          firstKnownAt: allKnownDates.firstOrNull,
          completedAt: completion?.at,
          finished: completion?.finished,
          hasPartialTimeCoverage: knownDates.any((date) {
            final number = _dayNumber(date);
            return !measured.containsKey(number) ||
                allocatedByDay[number] != dayByNumber[number]?.seconds;
          }),
        ),
      );
    }
    books.sort((a, b) {
      final duration = (b.seconds ?? -1).compareTo(a.seconds ?? -1);
      return duration != 0 ? duration : a.id.compareTo(b.id);
    });
    final bookById = {for (final book in books) book.id: book};

    final sessions = <StatisticsSession>[];
    for (final record in activity.sessions) {
      final milliseconds = record.dayMilliseconds.entries
          .where((entry) => selected(entry.key))
          .fold<int>(0, (sum, entry) => sum + entry.value);
      if (milliseconds <= 0) continue;
      final sessionStart = record.startedAt.localDateTime;
      final sessionEnd = record.endedAt.localDateTime;
      final exclusiveEnd = end.add(const Duration(days: 1));
      sessions.add(
        StatisticsSession(
          id: record.id,
          bookId: record.bookId,
          title:
              bookById[record.bookId]?.title ??
              bookFor?.call(record.bookId)?.title ??
              '书名待读取',
          start: sessionStart.isBefore(start) ? start : sessionStart,
          end: sessionEnd.isAfter(exclusiveEnd) ? exclusiveEnd : sessionEnd,
          milliseconds: milliseconds,
          isClipped: milliseconds != record.milliseconds,
        ),
      );
    }
    sessions.sort((a, b) {
      final duration = b.milliseconds.compareTo(a.milliseconds);
      return duration != 0 ? duration : a.start.compareTo(b.start);
    });
    final sessionCounts = List.filled(
      StatisticsSessionLengthBand.values.length,
      0,
    );
    final sessionMilliseconds = List.filled(
      StatisticsSessionLengthBand.values.length,
      0,
    );
    var completeSessionCount = 0,
        completeSessionMilliseconds = 0,
        clippedSessionCount = 0,
        clippedSessionMilliseconds = 0;
    for (final session in sessions) {
      if (session.isClipped) {
        clippedSessionCount++;
        clippedSessionMilliseconds += session.milliseconds;
        continue;
      }
      final band = StatisticsSessionLengthBand.values.firstWhere(
        (band) => band.contains(session.milliseconds),
      );
      sessionCounts[band.index]++;
      sessionMilliseconds[band.index] += session.milliseconds;
      completeSessionCount++;
      completeSessionMilliseconds += session.milliseconds;
    }

    final bookDayCounts = List.filled(StatisticsBookDayBand.values.length, 0);
    var attributedActiveDays = 0, unattributedActiveDays = 0;
    for (final day in recordedDays) {
      if (!selected(day.date) ||
          day.seconds <= 0 &&
              !detailDates.contains(statisticsCivilDay(day.date))) {
        continue;
      }
      if (day.bookIds.isEmpty) {
        unattributedActiveDays++;
        continue;
      }
      final band = StatisticsBookDayBand.values.firstWhere(
        (band) => band.contains(day.bookIds.length),
      );
      bookDayCounts[band.index]++;
      attributedActiveDays++;
    }

    final months = <StatisticsAnalysisMonth>[];
    for (final entry in monthBuilders.entries) {
      final value = entry.value;
      final calendarDays = DateTime.utc(
        entry.key.year,
        entry.key.month + 1,
        0,
      ).day;
      final complete =
          value.selectedDays == calendarDays &&
          value.observedDays == calendarDays;
      final previous = months.lastOrNull;
      final comparable =
          complete &&
          previous?.isComplete == true &&
          (previous?.totalSeconds ?? 0) > 0;
      months.add(
        StatisticsAnalysisMonth(
          date: entry.key,
          totalSeconds: value.observedDays == 0 ? null : value.seconds,
          measuredMilliseconds: value.measuredMilliseconds,
          nightMilliseconds: value.nightMilliseconds,
          selectedDays: value.selectedDays,
          observedDays: value.observedDays,
          isComplete: complete,
          changeRatio: comparable
              ? (value.seconds - previous!.totalSeconds!) /
                    previous.totalSeconds!
              : null,
        ),
      );
    }

    final genreBuilders = <String, _GenreBuilder>{};
    var bookMeasuredSeconds = 0;
    for (final book in books) {
      if (book.seconds == null) continue;
      bookMeasuredSeconds += book.seconds!;
      final raw = book.book?.genre.trim() ?? '';
      final genre = genreBuilders.putIfAbsent(
        raw.isEmpty ? '未分类' : raw,
        _GenreBuilder.new,
      );
      genre.seconds += book.seconds!;
      genre.bookIds.add(book.id);
    }
    final genres =
        [
          for (final entry in genreBuilders.entries)
            StatisticsAnalysisGenre(
              label: entry.key,
              seconds: entry.value.seconds,
              ratio: bookMeasuredSeconds == 0
                  ? 0
                  : entry.value.seconds / bookMeasuredSeconds,
              bookIds: entry.value.bookIds,
            ),
        ]..sort((a, b) {
          final duration = b.seconds.compareTo(a.seconds);
          return duration != 0 ? duration : a.label.compareTo(b.label);
        });
    final markAnalysis = StatisticsMarks.from(marks, selected: selected);
    final firstOpenedBooks =
        books
            .where(
              (book) =>
                  book.firstOpenedAt != null && selected(book.firstOpenedAt!),
            )
            .toList()
          ..sort((a, b) => a.firstOpenedAt!.compareTo(b.firstOpenedAt!));
    final reachedEndBooks =
        books
            .where(
              (book) => book.completedAt != null && selected(book.completedAt!),
            )
            .toList()
          ..sort((a, b) => a.completedAt!.compareTo(b.completedAt!));
    final completedBooks = reachedEndBooks
        .where((book) => book.finished == true)
        .toList(growable: false);
    final openedMilestones = <DateTime, int>{};
    final completedMilestones = <DateTime, int>{};
    for (final book in firstOpenedBooks) {
      openedMilestones.update(
        _month(book.firstOpenedAt!),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    for (final book in completedBooks) {
      completedMilestones.update(
        _month(book.completedAt!),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final unknownCompletionDates = completionRecords
        .where((record) => record.at == null)
        .length;
    return ReadingStatisticsAnalysis._(
      start: start,
      end: end,
      snapshotAt: snapshotAt,
      totalSeconds: total,
      activeDays: active,
      periodBooks: bookDates.length,
      days: List.unmodifiable(days),
      months: List.unmodifiable(months),
      weekdaysSeconds: List.unmodifiable([
        for (var i = 0; i < 7; i++)
          weekdayObserved[i] == 0 ? null : weekdayTotals[i],
      ]),
      hourMilliseconds: List.unmodifiable(hourMilliseconds),
      weekHourMatrix: StatisticsWeekHourMatrix(
        milliseconds: weekHourMilliseconds,
        measuredMilliseconds: measuredMilliseconds,
        hourEntries: hourEntries,
        days: detailDates.length,
      ),
      sessionLengths: StatisticsSessionLengthDistribution(
        buckets: [
          for (final band in StatisticsSessionLengthBand.values)
            StatisticsSessionLengthBucket(
              band: band,
              count: sessionCounts[band.index],
              milliseconds: sessionMilliseconds[band.index],
            ),
        ],
        completeSessionCount: completeSessionCount,
        completeMilliseconds: completeSessionMilliseconds,
        excludedClippedSessionCount: clippedSessionCount,
        excludedClippedMilliseconds: clippedSessionMilliseconds,
      ),
      bookDayDistribution: StatisticsBookDayDistribution(
        buckets: [
          for (final band in StatisticsBookDayBand.values)
            StatisticsBookDayBucket(
              band: band,
              days: bookDayCounts[band.index],
            ),
        ],
        attributedActiveDays: attributedActiveDays,
        unattributedActiveDays: unattributedActiveDays,
      ),
      monthlyMilestones: StatisticsMonthlyMilestones(
        months: [
          for (final month in months)
            StatisticsMonthMilestone(
              date: month.date,
              openedBooks: openedMilestones[month.date] ?? 0,
              completedBooks: completedMilestones[month.date] ?? 0,
            ),
        ],
        datedOpenedBooks: firstOpenedBooks.length,
        datedCompletedBooks: completedBooks.length,
        undatedOpenedBooks: books
            .where(
              (book) =>
                  openedIds.contains(book.id) && book.firstOpenedAt == null,
            )
            .length,
        undatedCompletionRecords: unknownCompletionDates,
        reachedEndOnlyBooks: reachedEndBooks.length - completedBooks.length,
      ),
      measuredMilliseconds: measuredMilliseconds,
      nightMilliseconds: nightMilliseconds,
      latestReading: latest,
      longestSession: sessions.firstOrNull,
      booksByDuration: List.unmodifiable(books),
      genres: List.unmodifiable(genres),
      firstOpenedBooks: List.unmodifiable(firstOpenedBooks),
      openedBooks: List.unmodifiable(
        books.where((book) => openedIds.contains(book.id)),
      ),
      completedBooks: List.unmodifiable(completedBooks),
      reachedEndBooks: List.unmodifiable(reachedEndBooks),
      unknownCompletionDates: unknownCompletionDates,
      marks: markAnalysis,
      longestStreak: StatisticsStreak(
        days: longest,
        start: longestStart,
        end: longestEnd,
      ),
      halves: StatisticsHalfYears.from(days, start: start, end: end),
      coverage: StatisticsCoverage(
        trackedSince: trackedDay,
        detailedSince: activity.detailStartedAt?.localDateTime,
        selectedDays: days.length,
        observedDays: observed,
        detailedDays: detailDates.length,
        totalSeconds: total,
        measuredMilliseconds: measuredMilliseconds,
        bookMeasuredSeconds: bookMeasuredSeconds,
      ),
    );
  }

  ReadingStatisticsAnalysis._({
    required this.start,
    required this.end,
    required this.snapshotAt,
    required this.totalSeconds,
    required this.activeDays,
    required this.periodBooks,
    required this.days,
    required this.months,
    required this.weekdaysSeconds,
    required this.hourMilliseconds,
    required this.weekHourMatrix,
    required this.sessionLengths,
    required this.bookDayDistribution,
    required this.monthlyMilestones,
    required this.measuredMilliseconds,
    required this.nightMilliseconds,
    required this.latestReading,
    required this.longestSession,
    required this.booksByDuration,
    required this.genres,
    required this.firstOpenedBooks,
    required this.openedBooks,
    required this.completedBooks,
    required this.reachedEndBooks,
    required this.unknownCompletionDates,
    required this.marks,
    required this.longestStreak,
    required this.halves,
    required this.coverage,
  });

  static const nightDefinition = '本地 22:00–06:00；按自然日和月份拆分';
  static const genreDefinition = '按已测书籍阅读时长；每本书使用当前主分类，缺失归入未分类';
  final DateTime start, end, snapshotAt;
  final int totalSeconds, activeDays, periodBooks;
  final List<StatisticsAnalysisDay> days;
  final List<StatisticsAnalysisMonth> months;
  final List<int?> weekdaysSeconds;
  final List<int> hourMilliseconds;
  final StatisticsWeekHourMatrix weekHourMatrix;
  final StatisticsSessionLengthDistribution sessionLengths;
  final StatisticsBookDayDistribution bookDayDistribution;
  final StatisticsMonthlyMilestones monthlyMilestones;
  final int measuredMilliseconds, nightMilliseconds;
  int get measuredSeconds => measuredMilliseconds ~/ 1000;
  int get nightSeconds => nightMilliseconds ~/ 1000;
  List<int> get hoursSeconds =>
      List.unmodifiable(hourMilliseconds.map((ms) => ms ~/ 1000));
  double? get nightRatio => measuredMilliseconds == 0
      ? null
      : nightMilliseconds / measuredMilliseconds;
  double get coverageRatio => activeDays / coverage.selectedDays;
  final StatisticsReadingEvent? latestReading;
  final StatisticsSession? longestSession;
  final List<StatisticsAnalysisBook> booksByDuration,
      openedBooks,
      firstOpenedBooks,
      completedBooks,
      reachedEndBooks;
  final int unknownCompletionDates;
  int get openedBooksCount => openedBooks.length;
  final List<StatisticsAnalysisGenre> genres;
  final StatisticsMarks marks;
  final StatisticsStreak longestStreak;
  final StatisticsHalfYears halves;
  final StatisticsCoverage coverage;
  // Page/chapter positions are layout snapshots, not measured reading volume.
  int? get pagesRead => null;
  int? get wordsRead => null;
}

class StatisticsAnalysisDay {
  const StatisticsAnalysisDay({required this.date, required this.seconds});
  final DateTime date;
  final int? seconds;
}

class StatisticsAnalysisMonth {
  const StatisticsAnalysisMonth({
    required this.date,
    required this.totalSeconds,
    required this.measuredMilliseconds,
    required this.nightMilliseconds,
    required this.selectedDays,
    required this.observedDays,
    required this.isComplete,
    required this.changeRatio,
  });
  final DateTime date;
  final int? totalSeconds;
  final int measuredMilliseconds, nightMilliseconds, selectedDays, observedDays;
  int get measuredSeconds => measuredMilliseconds ~/ 1000;
  int get nightSeconds => nightMilliseconds ~/ 1000;
  double? get nightRatio => measuredMilliseconds == 0
      ? null
      : nightMilliseconds / measuredMilliseconds;
  final bool isComplete;
  final double? changeRatio;
}

class StatisticsAnalysisBook {
  StatisticsAnalysisBook({
    required this.id,
    required this.title,
    required this.book,
    required this.seconds,
    required this.measuredMilliseconds,
    required this.nightMilliseconds,
    required Iterable<DateTime> activeDates,
    required this.firstOpenedAt,
    required this.firstKnownAt,
    required this.completedAt,
    required this.finished,
    required this.hasPartialTimeCoverage,
  }) : activeDates = List.unmodifiable(activeDates),
       activeMonths = List.unmodifiable(activeDates.map(_month).toSet());
  final int id;
  final String title;
  final Novel? book;
  final int? seconds;
  final int measuredMilliseconds, nightMilliseconds;
  int get measuredSeconds => measuredMilliseconds ~/ 1000;
  int get nightSeconds => nightMilliseconds ~/ 1000;
  double? get nightRatio => measuredMilliseconds == 0
      ? null
      : nightMilliseconds / measuredMilliseconds;
  final List<DateTime> activeDates, activeMonths;
  final DateTime? firstOpenedAt, firstKnownAt, completedAt;
  final bool? finished;
  final bool hasPartialTimeCoverage;
}

class StatisticsReadingEvent {
  const StatisticsReadingEvent({
    required this.instant,
    required this.bookId,
    required this.title,
  });
  final ReadingActivityInstant instant;
  DateTime get at => instant.localDateTime;
  final int bookId;
  final String title;
}

class StatisticsSession {
  const StatisticsSession({
    required this.id,
    required this.bookId,
    required this.title,
    required this.start,
    required this.end,
    required this.milliseconds,
    required this.isClipped,
  });
  final String id, title;
  final int bookId, milliseconds;
  int get seconds => milliseconds ~/ 1000;
  final DateTime start, end;
  final bool isClipped;
}

class StatisticsAnalysisGenre {
  StatisticsAnalysisGenre({
    required this.label,
    required this.seconds,
    required this.ratio,
    required Iterable<int> bookIds,
  }) : bookIds = Set.unmodifiable(bookIds);
  final String label;
  final int seconds;
  final double ratio;
  final Set<int> bookIds;
}

class StatisticsCoverage {
  const StatisticsCoverage({
    required this.trackedSince,
    required this.detailedSince,
    required this.selectedDays,
    required this.observedDays,
    required this.detailedDays,
    required this.totalSeconds,
    required this.measuredMilliseconds,
    required this.bookMeasuredSeconds,
  });
  final DateTime? trackedSince, detailedSince;

  /// [detailedDays] counts days with measured hour buckets, not zero-reading
  /// dates since installation. The detailed start timestamp is separate.
  final int selectedDays,
      observedDays,
      detailedDays,
      totalSeconds,
      measuredMilliseconds,
      bookMeasuredSeconds;
  int get measuredSeconds => measuredMilliseconds ~/ 1000;
  bool get hasTimeDetail => measuredMilliseconds > 0;
  bool get hasPartialTimeCoverage =>
      observedDays < selectedDays || measuredSeconds < totalSeconds;
  double? get detailRatio => totalSeconds == 0
      ? null
      : math.min(1, measuredMilliseconds / (totalSeconds * 1000));
}

class StatisticsStreak {
  const StatisticsStreak({
    required this.days,
    required this.start,
    required this.end,
  });
  final int days;
  final DateTime? start, end;
}

class StatisticsHalfYears {
  const StatisticsHalfYears({
    required this.year,
    required this.firstSeconds,
    required this.secondSeconds,
    required this.isFullYear,
    required this.comparable,
    required this.changeRatio,
  });
  factory StatisticsHalfYears.from(
    List<StatisticsAnalysisDay> days, {
    required DateTime start,
    required DateTime end,
  }) {
    if (start.year != end.year) {
      return const StatisticsHalfYears(
        year: null,
        firstSeconds: null,
        secondSeconds: null,
        isFullYear: false,
        comparable: false,
        changeRatio: null,
      );
    }
    final first = days
        .where((day) => day.date.month <= 6)
        .map((day) => day.seconds)
        .whereType<int>()
        .toList();
    final second = days
        .where((day) => day.date.month > 6)
        .map((day) => day.seconds)
        .whereType<int>()
        .toList();
    int? sum(List<int> values) =>
        values.isEmpty ? null : values.fold<int>(0, (a, b) => a + b);
    final firstSeconds = sum(first), secondSeconds = sum(second);
    final isFullYear =
        start.month == 1 && start.day == 1 && end.month == 12 && end.day == 31;
    final comparable = isFullYear && days.every((day) => day.seconds != null);
    return StatisticsHalfYears(
      year: start.year,
      firstSeconds: firstSeconds,
      secondSeconds: secondSeconds,
      isFullYear: isFullYear,
      comparable: comparable,
      changeRatio: comparable && (firstSeconds ?? 0) > 0
          ? (secondSeconds! - firstSeconds!) / firstSeconds
          : null,
    );
  }
  final int? year, firstSeconds, secondSeconds;
  final bool isFullYear, comparable;
  final double? changeRatio;
}

/// Marks without creation metadata remain inventory, not dated reading events.
class StatisticsMarkRecord {
  const StatisticsMarkRecord({
    required this.id,
    required this.bookId,
    required this.title,
    required this.isBookmark,
    required this.quote,
    required this.note,
    required this.chapter,
    this.createdAt,
  });
  final String id, title, quote, note, chapter;
  final int bookId;
  final bool isBookmark;
  bool get isExcerpt => quote.trim().isNotEmpty;
  final ReadingActivityInstant? createdAt;
}

class StatisticsMarks {
  static const countingRule = '书签为普通定位标记；摘录为含原文的标记，两者可重叠';
  StatisticsMarks._({
    required this.bookmarks,
    required this.excerpts,
    required this.nightBookmarks,
    required this.nightExcerpts,
    required this.unknownDateCount,
    required this.inventoryBookmarks,
    required this.inventoryExcerpts,
    required this.items,
    required this.byBook,
  });
  factory StatisticsMarks.from(
    Iterable<StatisticsMarkRecord> records, {
    required bool Function(DateTime) selected,
  }) {
    final all = records.toList(growable: false);
    final items = all
        .where(
          (mark) => mark.createdAt != null && selected(mark.createdAt!.date),
        )
        .toList();
    final groups = <int, List<StatisticsMarkRecord>>{};
    for (final mark in items) {
      groups.putIfAbsent(mark.bookId, () => []).add(mark);
    }
    final byBook =
        [
          for (final entry in groups.entries)
            StatisticsBookMarks(
              bookId: entry.key,
              title: entry.value.first.title,
              bookmarks: entry.value.where((mark) => mark.isBookmark).length,
              excerpts: entry.value.where((mark) => mark.isExcerpt).length,
              nightBookmarks: entry.value
                  .where(
                    (mark) => mark.isBookmark && _night(mark.createdAt!.hour),
                  )
                  .length,
              nightExcerpts: entry.value
                  .where(
                    (mark) => mark.isExcerpt && _night(mark.createdAt!.hour),
                  )
                  .length,
            ),
        ]..sort((a, b) {
          final count = b.excerpts.compareTo(a.excerpts);
          return count != 0 ? count : a.bookId.compareTo(b.bookId);
        });
    return StatisticsMarks._(
      bookmarks: items.where((mark) => mark.isBookmark).length,
      excerpts: items.where((mark) => mark.isExcerpt).length,
      nightBookmarks: items
          .where((mark) => mark.isBookmark && _night(mark.createdAt!.hour))
          .length,
      nightExcerpts: items
          .where((mark) => mark.isExcerpt && _night(mark.createdAt!.hour))
          .length,
      unknownDateCount: all.where((mark) => mark.createdAt == null).length,
      inventoryBookmarks: all.where((mark) => mark.isBookmark).length,
      inventoryExcerpts: all.where((mark) => mark.isExcerpt).length,
      items: List.unmodifiable(items),
      byBook: List.unmodifiable(byBook),
    );
  }
  final int bookmarks,
      excerpts,
      nightBookmarks,
      nightExcerpts,
      unknownDateCount,
      inventoryBookmarks,
      inventoryExcerpts;
  final List<StatisticsMarkRecord> items;
  final List<StatisticsBookMarks> byBook;
}

class StatisticsBookMarks {
  const StatisticsBookMarks({
    required this.bookId,
    required this.title,
    required this.bookmarks,
    required this.excerpts,
    required this.nightBookmarks,
    required this.nightExcerpts,
  });
  final int bookId, bookmarks, excerpts, nightBookmarks, nightExcerpts;
  final String title;
}

class StatisticsCompletionRecord {
  const StatisticsCompletionRecord({
    required this.bookId,
    required this.title,
    required this.at,
    required this.finished,
  });
  final int bookId;
  final String title;
  final DateTime? at;
  final bool finished;
}

class _MonthBuilder {
  int seconds = 0,
      selectedDays = 0,
      observedDays = 0,
      measuredMilliseconds = 0,
      nightMilliseconds = 0;
}

class _GenreBuilder {
  int seconds = 0;
  final bookIds = <int>{};
}
