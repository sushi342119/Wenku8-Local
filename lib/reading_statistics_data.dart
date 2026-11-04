import 'dart:math' as math;

import 'bookmark_library_page.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'offline_repository.dart';
import 'reading_activity.dart';
import 'reading_statistics_analysis.dart';

export 'reading_statistics_analysis.dart';

DateTime statisticsDay(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

int _dayNumber(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

class StatisticsAuthor {
  const StatisticsAuthor(this.name, this.books);
  final String name;
  final int books;
}

class StatisticsBookDays {
  const StatisticsBookDays({
    required this.id,
    required this.days,
    this.title,
    this.author,
    this.book,
  });
  final int id, days;
  final String? title, author;
  final Novel? book;
}

class StatisticsMonth {
  const StatisticsMonth(this.date, this.seconds);
  final DateTime date;
  final int? seconds;
}

class StatisticsExcerpt {
  const StatisticsExcerpt({
    required this.quote,
    required this.note,
    required this.title,
    required this.chapter,
  });
  final String quote, note, title, chapter;
}

/// A page snapshot, never recalculated by chart painting or animation ticks.
class ReadingStatisticsData {
  ReadingStatisticsData({
    required LibraryState state,
    required NovelRepository repository,
    required DateTime now,
    required this.period,
    DateTime? snapshotAt,
  }) {
    today = statisticsDay(now);
    final activity = state.readingActivity;
    // Persisted day keys retain the date at collection. A legacy timestamp
    // without its original zone must not shift this boundary after travel.
    startedAt = activity.days.isEmpty
        ? null
        : activity.days
              .map(
                (day) => DateTime(day.date.year, day.date.month, day.date.day),
              )
              .reduce((a, b) => a.isBefore(b) ? a : b);
    final start = startedAt;
    bool observed(DateTime day) => start != null && !day.isBefore(start);
    final extended = activity.daysEndingAt(today, period + 6);
    final selected = extended.skip(6).toList(growable: false);
    dates = List.unmodifiable(selected.map((day) => day.date));
    seconds = List.unmodifiable([
      for (final day in selected) observed(day.date) ? day.seconds : null,
    ]);
    minutes = List.unmodifiable([
      for (final value in seconds) value == null ? null : value / 60,
    ]);
    averageMinutes = List.unmodifiable([
      for (var i = 6; i < extended.length; i++)
        if (!observed(extended[i].date))
          null
        else
          _average([
            for (final day in extended.sublist(i - 6, i + 1))
              if (observed(day.date)) day.seconds / 60,
          ]),
    ]);
    periodSeconds = selected.fold(0, (sum, day) => sum + day.seconds);
    activeDays = selected.where((day) => day.seconds > 0).length;
    periodBooks = {
      for (final day in selected)
        if (day.seconds > 0) ...day.bookIds,
    }.length;
    observedDays = seconds.whereType<int>().length;
    final monthValues = <DateTime, int?>{};
    for (var i = 0; i < dates.length; i++) {
      final month = DateTime(dates[i].year, dates[i].month);
      monthValues.putIfAbsent(month, () => null);
      if (seconds[i] != null) {
        monthValues[month] = (monthValues[month] ?? 0) + seconds[i]!;
      }
    }
    months = List.unmodifiable([
      for (final entry in monthValues.entries)
        StatisticsMonth(entry.key, entry.value),
    ]);
    averageSeconds = observedDays == 0 ? 0 : periodSeconds ~/ observedDays;
    activeAverageSeconds = activeDays == 0 ? 0 : periodSeconds ~/ activeDays;
    bookCounts = List.unmodifiable([
      for (final day in selected)
        observed(day.date) ? day.bookIds.length : null,
    ]);
    peakSeconds = seconds.whereType<int>().fold(0, math.max);
    peakDate = peakSeconds == 0 ? null : dates[seconds.indexOf(peakSeconds)];
    final previousPeriod = activity.daysEndingAt(
      DateTime(today.year, today.month, today.day - period),
      period,
    );
    previousObservedDays = previousPeriod
        .where((day) => observed(day.date))
        .length;
    previousPeriodSeconds = previousPeriod.fold(
      0,
      (sum, day) => sum + day.seconds,
    );
    totalSeconds = activity.totalSeconds;
    final calendar = activity.daysEndingAt(today, 84);
    calendarDates = List.unmodifiable(calendar.map((day) => day.date));
    calendarSeconds = List.unmodifiable([
      for (final day in calendar) observed(day.date) ? day.seconds : null,
    ]);
    final active = {
      for (final day in activity.days)
        if (day.seconds > 0 && !day.date.isAfter(today)) _dayNumber(day.date),
    };
    final sortedDays = active.toList()..sort();
    var longest = 0;
    var run = 0;
    int? previous;
    for (final day in sortedDays) {
      run = previous == day - 1 ? run + 1 : 1;
      longest = math.max(longest, run);
      previous = day;
    }
    var cursor = _dayNumber(today);
    if (!active.contains(cursor)) cursor--;
    longestStreak = longest;
    var current = 0;
    while (active.contains(cursor--)) {
      current++;
    }
    currentStreak = current;

    final offline = repository is OfflineNovelRepository ? repository : null;
    final local = state.localLibrary;
    Novel? known(int id) =>
        local?.novelFor(id) ??
        state.cachedNovel(id) ??
        offline?.cache.book(id)?.novel;
    final bookDays = <int, int>{};
    for (final day in selected) {
      if (!observed(day.date)) continue;
      for (final id in day.bookIds) {
        bookDays.update(id, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final rankedBooks = bookDays.entries.toList()
      ..sort((a, b) {
        final days = b.value.compareTo(a.value);
        return days == 0 ? a.key.compareTo(b.key) : days;
      });
    booksByReadingDays = List.unmodifiable([
      for (final entry in rankedBooks)
        StatisticsBookDays(
          id: entry.key,
          days: entry.value,
          title: known(entry.key)?.title,
          author: known(entry.key)?.author,
          book: known(entry.key),
        ),
    ]);
    final ids = state.recordedReadingIds;
    readingBooks = ids.length;
    finishedBooks = 0;
    unknownProgress = 0;
    final distribution = List.filled(4, 0);
    for (final id in ids) {
      final book = known(id);
      if (book == null) {
        unknownProgress++;
        continue;
      }
      if (state.finishedReading(book)) finishedBooks++;
      final count = book.chapters.isEmpty
          ? book.chapterCount
          : book.chapters.length;
      final position = state.positionFor(id);
      final chapter = position == null
          ? state.chapterFor(id)
          : book.chapters.isEmpty
          ? position.chapter
          : state.chapterForPosition(book, position);
      if (count <= 0 || chapter == null || chapter < 0 || chapter >= count) {
        unknownProgress++;
        continue;
      }
      final fraction = (chapter + (position?.fraction ?? 0)) / count;
      distribution[(fraction.clamp(0, 1) * 4).floor().clamp(0, 3)]++;
    }
    progressBands = List.unmodifiable(distribution);
    final marks = libraryBookmarks(state, books: local);
    underlines = marks.where((entry) => entry.bookmark.isUnderline).length;
    bookmarks = marks.length - underlines;
    excerpts = List.unmodifiable([
      for (final entry in marks)
        if (entry.bookmark.quote.trim().isNotEmpty)
          StatisticsExcerpt(
            quote: entry.bookmark.quote.trim(),
            note: entry.bookmark.note.trim(),
            title: known(entry.novelId)?.title ?? '书名待读取',
            chapter: entry.bookmark.chapterTitle,
          ),
    ]);
    onlineBooks = state.shelf.length;
    localBooks = local?.books.length ?? 0;
    final collection = <int, Novel>{
      for (final id in state.shelf) id: ?known(id),
      for (final book in local?.novels ?? const <Novel>[]) book.id: book,
    };
    collectionBooks = List.unmodifiable(collection.values);
    final genreCounts = <String, int>{};
    for (final book in collection.values) {
      final name = book.genre.trim().isEmpty ? '未分类' : book.genre.trim();
      genreCounts.update(name, (value) => value + 1, ifAbsent: () => 1);
    }
    final rankedGenres = genreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    genres = List.unmodifiable([
      for (final entry in rankedGenres)
        StatisticsAuthor(entry.key, entry.value),
    ]);
    final counts = <String, int>{};
    var missingAuthors = onlineBooks + localBooks - collection.length;
    for (final book in collection.values) {
      final author = book.author.trim();
      if (author.isEmpty || author == '未知作者' || author == '未知') {
        missingAuthors++;
      } else {
        counts.update(author, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    authorCount = counts.length;
    unknownAuthors = missingAuthors;
    final ranked = counts.entries.toList()
      ..sort((a, b) {
        final count = b.value.compareTo(a.value);
        return count == 0 ? a.key.compareTo(b.key) : count;
      });
    authors = List.unmodifiable([
      for (final entry in ranked.take(5))
        StatisticsAuthor(entry.key, entry.value),
    ]);
    analysis = ReadingStatisticsAnalysis(
      activity: activity,
      start: dates.first,
      end: dates.last,
      snapshotAt: snapshotAt ?? DateTime.now(),
      bookFor: known,
      marks: [
        for (final entry in marks)
          StatisticsMarkRecord(
            id: entry.bookmark.id,
            bookId: entry.novelId,
            title: known(entry.novelId)?.title ?? '书名待读取',
            isBookmark: !entry.bookmark.isUnderline,
            quote: entry.bookmark.quote,
            note: entry.bookmark.note,
            chapter: entry.bookmark.chapterTitle,
            createdAt:
                entry.bookmark.createdAt == null ||
                    entry.bookmark.createdOffsetMinutes == null
                ? null
                : ReadingActivityInstant(
                    epochMilliseconds:
                        entry.bookmark.createdAt!.millisecondsSinceEpoch,
                    offsetMinutes: entry.bookmark.createdOffsetMinutes!,
                  ),
          ),
      ],
      completions: [
        for (final moment in state.readingMoments.moments)
          if (moment.completion case final completion?)
            StatisticsCompletionRecord(
              bookId: completion.bookId,
              title: completion.title,
              at: completion.completedOffsetMinutes == null
                  ? null
                  : completion.completedAt.toUtc().add(
                      Duration(minutes: completion.completedOffsetMinutes!),
                    ),
              finished: completion.finished,
            ),
      ],
    );
  }

  final int period;
  late final ReadingStatisticsAnalysis analysis;
  late final DateTime today;
  late final DateTime? startedAt;
  late final List<DateTime> dates, calendarDates;
  late final List<int?> seconds, calendarSeconds;
  late final List<double?> minutes, averageMinutes;
  late final int periodSeconds, totalSeconds, activeDays, periodBooks;
  late final int observedDays, averageSeconds;
  late final int activeAverageSeconds, peakSeconds;
  late final DateTime? peakDate;
  late final int previousObservedDays, previousPeriodSeconds;
  late final List<int?> bookCounts;
  late final List<StatisticsBookDays> booksByReadingDays;
  late final List<StatisticsMonth> months;
  late final List<Novel> collectionBooks;
  late final List<StatisticsAuthor> genres;
  late final List<StatisticsExcerpt> excerpts;
  late final int currentStreak, longestStreak;
  late final int readingBooks, bookmarks, underlines, onlineBooks, localBooks;
  late final int authorCount, unknownAuthors;
  late final List<int> progressBands;
  late final List<StatisticsAuthor> authors;
  late int finishedBooks, unknownProgress;

  double? get activeRatio =>
      observedDays == 0 ? null : activeDays / observedDays;
  bool get hasCompleteComparison =>
      observedDays == period && previousObservedDays == period;

  static double _average(List<double> values) =>
      values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
}

String statisticsDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  if (seconds < 60) return '不足 1 分钟';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  final remainder = minutes % 60;
  return '${minutes ~/ 60} 小时${remainder == 0 ? '' : ' $remainder 分'}';
}

String statisticsDate(DateTime date) => '${date.month}月${date.day}日';
