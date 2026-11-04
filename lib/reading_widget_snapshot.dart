import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'reading_visual_theme.dart';
import 'reading_widget_design.dart';
import 'reading_widget_skin.dart';

/// The one, versioned contract consumed by all three native widget hosts.
/// Null means unmeasured, never an inferred zero from the old foreground timer.
@immutable
class ReadingWidgetDay {
  const ReadingWidgetDay({required this.date, required this.verifiedSeconds});
  final DateTime date;
  final int? verifiedSeconds;
  Map<String, Object?> toJson() => {
    'date': widgetDate(date),
    'verifiedSeconds': verifiedSeconds,
  };
}

@immutable
class ReadingWidgetCompletion {
  const ReadingWidgetCompletion({
    required this.completedAt,
    this.finished = true,
    this.bookId,
    this.title,
    this.author,
    this.coverPath,
  });
  final DateTime completedAt;
  final bool finished;
  final int? bookId;
  final String? title, author, coverPath;

  ReadingWidgetCompletion privateCopy() =>
      ReadingWidgetCompletion(completedAt: completedAt, finished: finished);

  ReadingWidgetCompletion withCover(String? path) => ReadingWidgetCompletion(
    completedAt: completedAt,
    finished: finished,
    bookId: bookId,
    title: title,
    author: author,
    coverPath: path,
  );

  Map<String, Object?> toJson() => {
    'completedAt': completedAt.toIso8601String(),
    'finished': finished,
    'bookId': bookId,
    'title': title,
    'author': author,
    'coverPath': coverPath,
  };
}

enum ReadingWidgetPalette { cream, night }

@immutable
class ReadingWidgetCurrentBook {
  const ReadingWidgetCurrentBook({required this.title, required this.chapter});
  final String title, chapter;
}

/// One compact 26-week calendar shared by native hosts. Dates are implicit from
/// a Monday start; null is unmeasured, never a fabricated zero-day history.
@immutable
class ReadingWidgetHeatmap {
  ReadingWidgetHeatmap({
    required DateTime localDay,
    required Iterable<int?> verifiedSeconds,
  }) : localDay = DateTime(localDay.year, localDay.month, localDay.day),
       startDate = widgetHeatmapStart(localDay),
       verifiedSeconds = List.unmodifiable(verifiedSeconds) {
    if (this.verifiedSeconds.length != dayCount) {
      throw ArgumentError('Heatmap requires $dayCount calendar days');
    }
    for (var index = 0; index < dayCount; index++) {
      final seconds = this.verifiedSeconds[index];
      if (seconds != null &&
          (seconds < 0 || dateAt(index).isAfter(this.localDay))) {
        throw ArgumentError(
          'Heatmap values must be nonnegative and not future',
        );
      }
    }
  }

  /// Old callers know exactly seven trailing dates, not the rest of the past.
  factory ReadingWidgetHeatmap.fromWeek({
    required DateTime localDay,
    required Iterable<ReadingWidgetDay> week,
  }) {
    final known = {
      for (final day in week) widgetDate(day.date): day.verifiedSeconds,
    };
    final start = widgetHeatmapStart(localDay);
    return ReadingWidgetHeatmap(
      localDay: localDay,
      verifiedSeconds: [
        for (var index = 0; index < dayCount; index++)
          known[widgetDate(
            DateTime(start.year, start.month, start.day + index),
          )],
      ],
    );
  }

  static const weeks = 26;
  static const dayCount = weeks * 7;
  static const weekStart = DateTime.monday;
  final DateTime localDay, startDate;
  final List<int?> verifiedSeconds;

  DateTime dateAt(int index) =>
      DateTime(startDate.year, startDate.month, startDate.day + index);

  List<ReadingWidgetDay> window(int weeks) {
    if (weeks < 1 || weeks > ReadingWidgetHeatmap.weeks) {
      throw ArgumentError.value(weeks, 'weeks', 'Expected 1..26');
    }
    return List.unmodifiable([
      for (var index = dayCount - weeks * 7; index < dayCount; index++)
        ReadingWidgetDay(
          date: dateAt(index),
          verifiedSeconds: verifiedSeconds[index],
        ),
    ]);
  }

  Map<String, Object?> toJson() => {
    'startDate': widgetDate(startDate),
    'weekStart': weekStart,
    'verifiedSeconds': verifiedSeconds,
  };
}

DateTime widgetHeatmapStart(DateTime localDay) => DateTime(
  localDay.year,
  localDay.month,
  localDay.day -
      (localDay.weekday - DateTime.monday) -
      (ReadingWidgetHeatmap.weeks - 1) * 7,
);

int? readingWidgetHeatLevel(int? seconds) {
  if (seconds == null) return null;
  if (seconds < 0) {
    throw ArgumentError.value(seconds, 'seconds', 'Must be nonnegative');
  }
  return seconds == 0
      ? 0
      : seconds < 900
      ? 1
      : seconds < 1800
      ? 2
      : seconds < 3600
      ? 3
      : 4;
}

@immutable
class ReadingWidgetSnapshot {
  ReadingWidgetSnapshot({
    required this.generatedAt,
    required this.localDay,
    required this.verifiedTotalSeconds,
    required this.verifiedTodaySeconds,
    required this.qualifiedStreakDays,
    required Iterable<ReadingWidgetDay> week,
    ReadingWidgetHeatmap? heatmap,
    this.latestCompletion,
    ReadingWidgetPalette? palette,
    ReadingVisualTheme? theme,
    this.showBookDetails = false,
    this.design = ReadingWidgetDesign.classic,
    this.skin = ReadingWidgetSkin.original,
    this.dailyGoalMinutes = 0,
    this.currentBook,
  }) : theme =
           theme ??
           (palette == null
               ? ReadingVisualTheme.archive
               : ReadingVisualTheme.fromId(palette.name)),
       week = List.unmodifiable(week),
       heatmap =
           heatmap ??
           ReadingWidgetHeatmap.fromWeek(localDay: localDay, week: week) {
    if (this.week.length != 7) {
      throw ArgumentError.value(
        this.week.length,
        'week',
        'Expected seven days',
      );
    }
    final today = DateTime(localDay.year, localDay.month, localDay.day);
    if (widgetDate(this.heatmap.localDay) != widgetDate(today)) {
      throw ArgumentError('Heatmap must use the same snapshot localDay');
    }
    for (var i = 0; i < 7; i++) {
      if (widgetDate(this.week[i].date) !=
          widgetDate(DateTime(today.year, today.month, today.day - 6 + i))) {
        throw ArgumentError('Week must end on localDay, oldest day first');
      }
    }
    if ([
      verifiedTotalSeconds,
      verifiedTodaySeconds,
      qualifiedStreakDays,
      ...this.week.map((day) => day.verifiedSeconds),
    ].any((value) => value != null && value < 0)) {
      throw ArgumentError('Measured counts must be nonnegative');
    }
  }

  static const version = 1;
  static const qualificationSeconds = 300;
  final DateTime generatedAt, localDay;
  final int? verifiedTotalSeconds, verifiedTodaySeconds, qualifiedStreakDays;
  final List<ReadingWidgetDay> week;
  final ReadingWidgetHeatmap heatmap;
  final ReadingWidgetCompletion? latestCompletion;
  final ReadingVisualTheme theme;
  final ReadingWidgetDesign design;
  final ReadingWidgetSkin skin;
  final int dailyGoalMinutes;
  final ReadingWidgetCurrentBook? currentBook;
  ReadingWidgetPalette get palette =>
      theme.isDark ? ReadingWidgetPalette.night : ReadingWidgetPalette.cream;
  String get themeId => theme.id;
  final bool showBookDetails;
  bool get hasMeasuredDays => week.any((day) => day.verifiedSeconds != null);
  int? get weekSeconds => hasMeasuredDays
      ? week.fold(0, (sum, day) => sum! + (day.verifiedSeconds ?? 0))
      : null;
  int get qualifiedWeekDays => week
      .where((day) => (day.verifiedSeconds ?? 0) >= qualificationSeconds)
      .length;

  ReadingWidgetSnapshot styled({
    ReadingWidgetPalette? palette,
    ReadingVisualTheme? theme,
    ReadingWidgetDesign? design,
    ReadingWidgetSkin? skin,
    int? dailyGoalMinutes,
    required bool showBookDetails,
    ReadingWidgetCompletion? completion,
  }) => ReadingWidgetSnapshot(
    generatedAt: generatedAt,
    localDay: localDay,
    verifiedTotalSeconds: verifiedTotalSeconds,
    verifiedTodaySeconds: verifiedTodaySeconds,
    qualifiedStreakDays: qualifiedStreakDays,
    week: week,
    heatmap: heatmap,
    latestCompletion: completion ?? latestCompletion,
    theme:
        theme ??
        (palette == null
            ? this.theme
            : ReadingVisualTheme.fromId(palette.name)),
    showBookDetails: showBookDetails,
    design: design ?? this.design,
    skin: skin ?? this.skin,
    currentBook: currentBook,
    dailyGoalMinutes: readingDailyGoal(
      dailyGoalMinutes ?? this.dailyGoalMinutes,
    ),
  );

  /// Redaction happens before crossing the process boundary, not just in paint.
  Map<String, Object?> toJson() => {
    'version': version,
    'generatedAt': generatedAt.toIso8601String(),
    'localDay': widgetDate(localDay),
    'qualificationSeconds': qualificationSeconds,
    'verifiedTotalSeconds': verifiedTotalSeconds,
    'verifiedTodaySeconds': verifiedTodaySeconds,
    'qualifiedStreakDays': qualifiedStreakDays,
    'week': week.map((day) => day.toJson()).toList(),
    'heatmap': heatmap.toJson(),
    'latestCompletion':
        (showBookDetails ? latestCompletion : latestCompletion?.privateCopy())
            ?.toJson(),
    'palette': palette.name,
    'themeId': themeId,
    'layoutId': design.name,
    'skinId': skin.name,
    'dailyGoalMinutes': readingDailyGoal(dailyGoalMinutes),
    'showBookDetails': showBookDetails,
    'currentBook': showBookDetails && currentBook != null
        ? {'title': currentBook!.title, 'chapter': currentBook!.chapter}
        : null,
  };

  String encode() => jsonEncode(toJson());
}

String widgetDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String widgetMinutes(int? seconds) => seconds == null
    ? '—'
    : seconds > 0 && seconds < 60
    ? '<1'
    : '${seconds ~/ 60}';
