/// Measured report dimensions. Empty summaries stay unavailable; they never
/// reconstruct hour, session or event detail from legacy daily totals.
class StatisticsWeekHourMatrix {
  StatisticsWeekHourMatrix({
    required Iterable<Iterable<int>> milliseconds,
    required this.measuredMilliseconds,
    required this.hourEntries,
    required this.days,
  }) : milliseconds = List.unmodifiable(
         milliseconds.map((row) => List<int>.unmodifiable(row)),
       );

  /// Monday first, then recorded civil hours 00–23. A zero cell has no measured
  /// time in this sample; it is not a claim about unrecorded historical hours.
  final List<List<int>> milliseconds;
  final int measuredMilliseconds;

  /// Positive book × civil-hour records, not elapsed hours or distinct cells.
  final int hourEntries;

  /// Distinct recorded civil dates containing positive hour detail.
  final int days;
  bool get hasData => measuredMilliseconds > 0;
}

enum StatisticsSessionLengthBand {
  under5('不足5分钟', 0, 5 * 60000),
  from5To15('5–15分钟', 5 * 60000, 15 * 60000),
  from15To30('15–30分钟', 15 * 60000, 30 * 60000),
  from30To60('30–60分钟', 30 * 60000, 60 * 60000),
  from60('60分钟及以上', 60 * 60000, null);

  const StatisticsSessionLengthBand(
    this.label,
    this.minimumMilliseconds,
    this.maximumMillisecondsExclusive,
  );
  final String label;
  final int minimumMilliseconds;
  final int? maximumMillisecondsExclusive;

  bool contains(int milliseconds) =>
      milliseconds >= minimumMilliseconds &&
      (maximumMillisecondsExclusive == null ||
          milliseconds < maximumMillisecondsExclusive!);
}

class StatisticsSessionLengthBucket {
  const StatisticsSessionLengthBucket({
    required this.band,
    required this.count,
    required this.milliseconds,
  });
  final StatisticsSessionLengthBand band;
  String get label => band.label;
  final int count, milliseconds;
}

/// Only complete measured sessions enter the five bands. A session clipped by
/// the report range is excluded rather than relabelled as a short session.
class StatisticsSessionLengthDistribution {
  StatisticsSessionLengthDistribution({
    required Iterable<StatisticsSessionLengthBucket> buckets,
    required this.completeSessionCount,
    required this.completeMilliseconds,
    required this.excludedClippedSessionCount,
    required this.excludedClippedMilliseconds,
  }) : buckets = List.unmodifiable(buckets);
  final List<StatisticsSessionLengthBucket> buckets;
  final int completeSessionCount,
      completeMilliseconds,
      excludedClippedSessionCount;

  /// Selected-range portions of excluded sessions, not their full durations.
  final int excludedClippedMilliseconds;
  bool get hasData => completeSessionCount > 0;
}

enum StatisticsBookDayBand {
  one('1本', 1, 1),
  two('2本', 2, 2),
  threeOrMore('3本及以上', 3, null);

  const StatisticsBookDayBand(this.label, this.minimumBooks, this.maximumBooks);
  final String label;
  final int minimumBooks;
  final int? maximumBooks;

  bool contains(int books) =>
      books >= minimumBooks && (maximumBooks == null || books <= maximumBooks!);
}

class StatisticsBookDayBucket {
  const StatisticsBookDayBucket({required this.band, required this.days});
  final StatisticsBookDayBand band;
  String get label => band.label;
  final int days;
}

/// How many distinct books were read on an attributed active day, not how many
/// were read simultaneously. Unattributed days are outside the denominator.
class StatisticsBookDayDistribution {
  StatisticsBookDayDistribution({
    required Iterable<StatisticsBookDayBucket> buckets,
    required this.attributedActiveDays,
    required this.unattributedActiveDays,
  }) : buckets = List.unmodifiable(buckets);
  final List<StatisticsBookDayBucket> buckets;
  final int attributedActiveDays, unattributedActiveDays;
  bool get hasData => attributedActiveDays > 0;
}

class StatisticsMonthMilestone {
  const StatisticsMonthMilestone({
    required this.date,
    required this.openedBooks,
    required this.completedBooks,
  });

  /// UTC-marked civil year/month, not an instant to convert with toLocal().
  final DateTime date;
  final int openedBooks, completedBooks;
  bool get hasEvents => openedBooks > 0 || completedBooks > 0;
}

/// Counts known dated events only. Zero means no known dated event in that
/// selected month, not that a book with a missing date was never opened/finished.
class StatisticsMonthlyMilestones {
  StatisticsMonthlyMilestones({
    required Iterable<StatisticsMonthMilestone> months,
    required this.datedOpenedBooks,
    required this.datedCompletedBooks,
    required this.undatedOpenedBooks,
    required this.undatedCompletionRecords,
    required this.reachedEndOnlyBooks,
  }) : months = List.unmodifiable(months);
  final List<StatisticsMonthMilestone> months;
  final int datedOpenedBooks, datedCompletedBooks;

  /// Selected-range opened books lacking a first-open timestamp.
  final int undatedOpenedBooks;

  /// Supplied completion records with no date cannot be placed in any range.
  final int undatedCompletionRecords;

  /// Dated selected-range serial endings are not finished-book milestones.
  final int reachedEndOnlyBooks;
  bool get hasData => datedOpenedBooks > 0 || datedCompletedBooks > 0;
}
