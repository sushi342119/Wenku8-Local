import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'reading_activity.dart';
import 'reading_visual_theme.dart';

/// An earned, lifetime reading milestone. Opening the app earns nothing.
enum ReadingMomentKind { firstDay, streak, duration, completion }

/// Presentation preferences never disable measurement or erase earned history.
@immutable
class ReadingMomentsPreferences {
  const ReadingMomentsPreferences({
    this.enabled = true,
    this.milestones = true,
    this.completions = true,
    this.confetti = true,
    this.themeId = 'archive',
  });
  final bool enabled, milestones, completions, confetti;
  final String themeId;

  bool allows(ReadingMomentKind kind) =>
      enabled &&
      (kind == ReadingMomentKind.completion ? completions : milestones);

  ReadingMomentsPreferences copyWith({
    bool? enabled,
    bool? milestones,
    bool? completions,
    bool? confetti,
    String? themeId,
  }) => ReadingMomentsPreferences(
    enabled: enabled ?? this.enabled,
    milestones: milestones ?? this.milestones,
    completions: completions ?? this.completions,
    confetti: confetti ?? this.confetti,
    themeId: themeId ?? this.themeId,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'milestones': milestones,
    'completions': completions,
    'confetti': confetti,
    'themeId': themeId,
  };

  factory ReadingMomentsPreferences.fromJson(Object? raw) {
    if (raw == null) return const ReadingMomentsPreferences();
    if (raw is! Map<String, dynamic> ||
        raw['enabled'] is! bool ||
        raw['milestones'] is! bool ||
        raw['completions'] is! bool ||
        raw['confetti'] is! bool ||
        raw['themeId'] is! String ||
        !RegExp(
          r'^[a-z][a-z0-9_-]{0,63}$',
        ).hasMatch(raw['themeId'] as String)) {
      throw const FormatException('阅读纪念设置格式有误');
    }
    return ReadingMomentsPreferences(
      enabled: raw['enabled'] as bool,
      milestones: raw['milestones'] as bool,
      completions: raw['completions'] as bool,
      confetti: raw['confetti'] as bool,
      themeId: ReadingVisualTheme.fromId(raw['themeId'] as String).id,
    );
  }
}

/// A durable book identity and the measurements available at its last page.
/// No field depends on the original local book remaining in the library.
@immutable
class ReadingCompletionSnapshot {
  const ReadingCompletionSnapshot({
    required this.bookId,
    required this.title,
    required this.author,
    required this.completedAt,
    required this.finished,
    this.coverPath,
    this.verifiedSeconds,
    this.readingDays = 0,
    this.firstReadAt,
    this.lastReadAt,
    this.completedOffsetMinutes,
    this.firstReachedEndAt,
    this.firstReachedEndOffsetMinutes,
  });

  final int bookId;
  final String title, author;
  final String? coverPath;
  final DateTime completedAt;
  final int? completedOffsetMinutes;

  /// Retains the first reached-end observation when a serial later finishes.
  final DateTime? firstReachedEndAt;
  final int? firstReachedEndOffsetMinutes;
  final bool finished;
  final int? verifiedSeconds;
  final int readingDays;
  final DateTime? firstReadAt, lastReadAt;

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'title': title,
    'author': author,
    'completedAt': completedAt.millisecondsSinceEpoch,
    if (completedOffsetMinutes != null)
      'completedOffsetMinutes': completedOffsetMinutes,
    if (firstReachedEndAt != null)
      'firstReachedEndAt': firstReachedEndAt!.millisecondsSinceEpoch,
    if (firstReachedEndOffsetMinutes != null)
      'firstReachedEndOffsetMinutes': firstReachedEndOffsetMinutes,
    'finished': finished,
    'coverPath': coverPath,
    'verifiedSeconds': verifiedSeconds,
    'readingDays': readingDays,
    'firstReadAt': firstReadAt?.millisecondsSinceEpoch,
    'lastReadAt': lastReadAt?.millisecondsSinceEpoch,
  };

  factory ReadingCompletionSnapshot.fromJson(Map<String, dynamic> json) {
    final id = json['bookId'], title = json['title'], author = json['author'];
    final finished = json['finished'], seconds = json['verifiedSeconds'];
    final days = json['readingDays'], cover = json['coverPath'];
    final offset = json['completedOffsetMinutes'];
    final firstOffset = json['firstReachedEndOffsetMinutes'];
    if (id is! int ||
        id <= 0 ||
        id > 9999999999 ||
        title is! String ||
        title.isEmpty ||
        title.length > 4096 ||
        author is! String ||
        author.length > 4096 ||
        finished is! bool ||
        days is! int ||
        days < 0 ||
        (offset != null && (offset is! int || offset < -840 || offset > 840)) ||
        (firstOffset != null &&
            (firstOffset is! int ||
                firstOffset < -840 ||
                firstOffset > 840 ||
                json['firstReachedEndAt'] == null)) ||
        (seconds != null && (seconds is! int || seconds < 0)) ||
        (cover != null && (cover is! String || cover.length > 4096))) {
      throw const FormatException('阅读纪念书籍格式有误');
    }
    return ReadingCompletionSnapshot(
      bookId: id,
      title: title,
      author: author,
      completedAt: _timestamp(json['completedAt']),
      completedOffsetMinutes: offset as int?,
      firstReachedEndAt: _optionalTimestamp(json['firstReachedEndAt']),
      firstReachedEndOffsetMinutes: firstOffset as int?,
      finished: finished,
      coverPath: cover as String?,
      verifiedSeconds: seconds as int?,
      readingDays: days,
      firstReadAt: _optionalTimestamp(json['firstReadAt']),
      lastReadAt: _optionalTimestamp(json['lastReadAt']),
    );
  }
}

/// An immutable entry; presentation state is stored separately from its content.
@immutable
class ReadingMoment {
  const ReadingMoment({
    required this.id,
    required this.kind,
    required this.earnedAt,
    this.value = 0,
    this.completion,
  });

  final String id;
  final ReadingMomentKind kind;
  final DateTime earnedAt;
  final int value;
  final ReadingCompletionSnapshot? completion;

  String get title => switch (kind) {
    ReadingMomentKind.firstDay => '故事，从今天开始',
    ReadingMomentKind.streak => '与文字相伴的 $value 天',
    ReadingMomentKind.duration => '把 $value 小时，留给阅读',
    ReadingMomentKind.completion =>
      completion!.finished ? '又读完了一个世界' : '读到故事的此刻',
  };

  String get subtitle => switch (kind) {
    ReadingMomentKind.firstDay => '第一次，认真读满五分钟。',
    ReadingMomentKind.streak => '连续 $value 天，每天至少五分钟。',
    ReadingMomentKind.duration => '一页一页，积攒成自己的时光。',
    ReadingMomentKind.completion =>
      completion!.finished ? '合上书页，故事仍在心里。' : '下一段故事，值得等待。',
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'earnedAt': earnedAt.millisecondsSinceEpoch,
    'value': value,
    if (completion != null) 'completion': completion!.toJson(),
  };

  factory ReadingMoment.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'], id = json['id'], value = json['value'];
    final kind = ReadingMomentKind.values
        .where((k) => k.name == kindName)
        .firstOrNull;
    if (kind == null || id is! String || value is! int || value < 0) {
      throw const FormatException('阅读纪念格式有误');
    }
    final raw = json['completion'];
    final completion = raw is Map<String, dynamic>
        ? ReadingCompletionSnapshot.fromJson(raw)
        : null;
    final valid = switch (kind) {
      ReadingMomentKind.firstDay => id == 'first_day' && value == 1,
      ReadingMomentKind.streak =>
        id == 'streak:$value' &&
            ReadingMomentsStore.streakMilestones.contains(value),
      ReadingMomentKind.duration =>
        id == 'duration:$value' &&
            ReadingMomentsStore.hourMilestones.contains(value),
      ReadingMomentKind.completion =>
        completion != null && id == 'completion:${completion.bookId}',
    };
    if (!valid || (kind != ReadingMomentKind.completion && raw != null)) {
      throw const FormatException('阅读纪念标识有误');
    }
    return ReadingMoment(
      id: id,
      kind: kind,
      earnedAt: _timestamp(json['earnedAt']),
      value: value,
      completion: completion,
    );
  }
}

/// Verified reading has its own new ledger; old foreground totals remain intact.
/// This notifier is also the read-only source for native widget snapshots.
class ReadingMomentsStore extends ChangeNotifier {
  ReadingMomentsStore({String? record, Future<void> Function()? persist})
    : _persist = persist {
    if (record == null) {
      _activity = ReadingActivityStore(collectDetails: false);
    } else {
      final decoded = _decode(record);
      _activity = ReadingActivityStore(
        record: decoded.activity,
        collectDetails: false,
      );
      _moments.addAll(decoded.moments);
      _presented.addAll(decoded.presented);
      _preferences = decoded.preferences;
    }
  }

  static const preferenceKey = 'reading_moments_v1';
  static const qualifyingSeconds = 300;
  static const streakMilestones = [3, 7, 14, 30, 100, 365];
  static const hourMilestones = [1, 10, 50, 100, 500];
  final Future<void> Function()? _persist;
  late final ReadingActivityStore _activity;
  final Map<String, ReadingMoment> _moments = {};
  final Set<String> _presented = {};
  bool _disposed = false;
  ReadingMomentsPreferences _preferences = const ReadingMomentsPreferences();

  ReadingMomentsPreferences get preferences => _preferences;

  /// Disabling a popup category retires its pending queue, not its history.
  Future<void> setPreferences(ReadingMomentsPreferences value) async {
    final before = _preferences;
    final previouslyPresented = {..._presented};
    _preferences = value;
    for (final event in _moments.values) {
      if (!value.allows(event.kind)) _presented.add(event.id);
    }
    try {
      await _save();
    } catch (_) {
      _preferences = before;
      _presented
        ..clear()
        ..addAll(previouslyPresented);
      rethrow;
    }
  }

  DateTime? get trackedSince => _activity.startedAt;
  int get verifiedTotalSeconds => _activity.totalSeconds;

  /// Unknown before measurement began; zero is a measured calendar-day absence.
  int? verifiedSecondsOn(DateTime localDay) {
    final start = trackedSince;
    final date = _day(localDay.toLocal());
    if (start == null || date.isBefore(_day(start))) return null;
    for (final day in _activity.days) {
      if (day.date == date) return day.seconds;
    }
    return 0;
  }

  /// Today's ongoing streak keeps yesterday's qualifying run until today ends.
  int qualifiedStreakDaysAt(DateTime now) {
    var date = _day(now.toLocal());
    if ((verifiedSecondsOn(date) ?? 0) < qualifyingSeconds) {
      date = DateTime(date.year, date.month, date.day - 1);
    }
    var count = 0;
    while ((verifiedSecondsOn(date) ?? 0) >= qualifyingSeconds) {
      count++;
      date = DateTime(date.year, date.month, date.day - 1);
    }
    return count;
  }

  List<ReadingMoment> get moments => List.unmodifiable(
    _moments.values.toList()..sort((a, b) => b.earnedAt.compareTo(a.earnedAt)),
  );

  ReadingCompletionSnapshot? get latestCompletion => moments
      .where((moment) => moment.completion != null)
      .map((moment) => moment.completion)
      .firstOrNull;

  /// Only a causal reading gate calls this in production. Deterministic tests
  /// may supply intervals directly; saved positions never reach this method.
  Future<void> recordVerifiedInterval({
    required int bookId,
    required DateTime startedAt,
    required Duration elapsed,
  }) async {
    if (elapsed <= Duration.zero) return;
    await _activity.recordInterval(
      bookId: bookId,
      startedAt: startedAt,
      elapsed: elapsed,
    );
    final earnedAt = startedAt.add(elapsed);
    var streak = 0;
    DateTime? previousDay;
    for (final day in _activity.days) {
      final preceding = DateTime(
        day.date.year,
        day.date.month,
        day.date.day - 1,
      );
      if (day.seconds < qualifyingSeconds) {
        streak = 0;
        previousDay = null;
        continue;
      }
      streak = previousDay == preceding ? streak + 1 : 1;
      previousDay = day.date;
      _earn(
        ReadingMoment(
          id: 'first_day',
          kind: ReadingMomentKind.firstDay,
          earnedAt: earnedAt,
          value: 1,
        ),
      );
      for (final threshold in streakMilestones) {
        if (streak >= threshold) {
          _earn(
            ReadingMoment(
              id: 'streak:$threshold',
              kind: ReadingMomentKind.streak,
              earnedAt: earnedAt,
              value: threshold,
            ),
          );
        }
      }
    }
    for (final hours in hourMilestones) {
      if (verifiedTotalSeconds >= hours * 3600) {
        _earn(
          ReadingMoment(
            id: 'duration:$hours',
            kind: ReadingMomentKind.duration,
            earnedAt: earnedAt,
            value: hours,
          ),
        );
      }
    }
    await _save();
  }

  /// A reader-confirmed forward end boundary, not a restored last-page fraction.
  Future<void> completeBook({
    required int bookId,
    required String title,
    required String author,
    required bool finished,
    DateTime? at,
    String? coverPath,
  }) async {
    final key = 'completion:$bookId';
    final previous = _moments[key];
    final original = previous?.completion;
    if (previous != null && (original?.finished != false || !finished)) return;
    final wasPresented = _presented.contains(key);
    final days = _activity.daysForBook(bookId);
    final completedAt = at ?? DateTime.now();
    final snapshot = ReadingCompletionSnapshot(
      bookId: bookId,
      title: original?.title ?? title,
      author: original?.author ?? author,
      completedAt: completedAt,
      completedOffsetMinutes: completedAt.timeZoneOffset.inMinutes,
      firstReachedEndAt:
          original?.firstReachedEndAt ?? original?.completedAt ?? completedAt,
      firstReachedEndOffsetMinutes: original == null
          ? completedAt.timeZoneOffset.inMinutes
          : original.firstReachedEndOffsetMinutes ??
                original.completedOffsetMinutes,
      finished: finished,
      coverPath: original?.coverPath ?? coverPath,
      verifiedSeconds: days.isEmpty
          ? null
          : days.fold<int>(0, (sum, day) => sum + day.seconds),
      readingDays: days.where((day) => day.seconds > 0).length,
      firstReadAt: days.firstOrNull?.date,
      lastReadAt: days.lastOrNull?.date,
    );
    final event = ReadingMoment(
      id: key,
      kind: ReadingMomentKind.completion,
      earnedAt: completedAt,
      completion: snapshot,
    );
    if (previous == null) {
      _earn(event);
    } else {
      _moments[key] = event;
    }
    try {
      await _save();
    } catch (_) {
      if (previous == null) {
        _moments.remove(key);
      } else {
        _moments[key] = previous;
      }
      if (wasPresented) {
        _presented.add(key);
      } else {
        _presented.remove(key);
      }
      rethrow;
    }
  }

  void _earn(ReadingMoment moment) {
    _moments.putIfAbsent(moment.id, () => moment);
    if (!_preferences.allows(moment.kind)) _presented.add(moment.id);
  }

  /// One natural stop shows at most one event. The rest remain in the timeline.
  /// Persist presentation before opening a route, so reload never replays it.
  Future<ReadingMoment?> takePending({bool Function()? canPresent}) async {
    if (canPresent?.call() == false) return null;
    final pending = moments
        .where((event) => !_presented.contains(event.id))
        .toList();
    if (pending.isEmpty) return null;
    final selected =
        pending
            .where((event) => event.kind == ReadingMomentKind.completion)
            .firstOrNull ??
        pending.first;
    final added = pending.map((event) => event.id).toSet();
    _presented.addAll(added);
    try {
      await _save();
      if (canPresent?.call() == false) {
        _presented.removeAll(added);
        await _save();
        return null;
      }
    } catch (_) {
      _presented.removeAll(added);
      rethrow;
    }
    return selected;
  }

  String encode() => jsonEncode({
    'version': 1,
    'activity': _activity.encode(),
    'moments': _moments.values.map((event) => event.toJson()).toList(),
    'presented': _presented.toList()..sort(),
    'preferences': _preferences.toJson(),
  });

  static String validateRecord(String record) {
    final store = ReadingMomentsStore(record: record);
    try {
      return store.encode();
    } finally {
      store.dispose();
    }
  }

  String mergedRecord(String incoming, {bool importPreferences = false}) {
    final copy = ReadingMomentsStore(record: encode());
    try {
      copy._merge(incoming, importPreferences: importPreferences);
      return copy.encode();
    } finally {
      copy.dispose();
    }
  }

  /// Imported achievements are history, not a queue of historical popups.
  Future<void> mergeRecord(
    String incoming, {
    bool persist = true,
    bool importPreferences = false,
  }) async {
    _merge(incoming, importPreferences: importPreferences);
    if (persist) {
      await _save();
    } else {
      _notify();
    }
  }

  void _merge(String incoming, {bool importPreferences = false}) {
    final decoded = _decode(incoming);
    unawaited(_activity.mergeRecord(decoded.activity, persist: false));
    for (final event in decoded.moments.values) {
      final current = _moments[event.id];
      if (current == null) {
        _moments[event.id] = event;
        _presented.add(event.id);
      } else if (current.completion?.finished == false &&
          event.completion?.finished == true) {
        final old = current.completion!, incoming = event.completion!;
        _moments[event.id] = ReadingMoment(
          id: event.id,
          kind: event.kind,
          earnedAt: event.earnedAt,
          value: event.value,
          completion: ReadingCompletionSnapshot(
            bookId: old.bookId,
            title: old.title,
            author: old.author,
            completedAt: incoming.completedAt,
            completedOffsetMinutes: incoming.completedOffsetMinutes,
            firstReachedEndAt: old.firstReachedEndAt ?? old.completedAt,
            firstReachedEndOffsetMinutes:
                old.firstReachedEndOffsetMinutes ?? old.completedOffsetMinutes,
            finished: true,
            coverPath: old.coverPath ?? incoming.coverPath,
            verifiedSeconds: incoming.verifiedSeconds,
            readingDays: incoming.readingDays,
            firstReadAt: incoming.firstReadAt,
            lastReadAt: incoming.lastReadAt,
          ),
        );
        _presented.add(event.id);
      }
    }
    _presented.addAll(decoded.presented);
    if (importPreferences) _preferences = decoded.preferences;
  }

  Future<void> _save() async {
    await _persist?.call();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static ({
    String activity,
    Map<String, ReadingMoment> moments,
    Set<String> presented,
    ReadingMomentsPreferences preferences,
  })
  _decode(String record) {
    final raw = jsonDecode(record);
    if (raw is! Map<String, dynamic> ||
        raw['version'] != 1 ||
        raw['activity'] is! String ||
        raw['moments'] is! List ||
        raw['presented'] is! List) {
      throw const FormatException('阅读纪念记录格式有误');
    }
    final activity = ReadingActivityStore.validateRecord(
      raw['activity'] as String,
    );
    final moments = <String, ReadingMoment>{};
    for (final item in raw['moments'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('阅读纪念格式有误');
      }
      final event = ReadingMoment.fromJson(item);
      if (moments.containsKey(event.id)) {
        throw const FormatException('阅读纪念标识重复');
      }
      moments[event.id] = event;
    }
    final presented = <String>{};
    for (final id in raw['presented'] as List) {
      if (id is! String || !moments.containsKey(id)) {
        throw const FormatException('阅读纪念状态格式有误');
      }
      presented.add(id);
    }
    return (
      activity: activity,
      moments: moments,
      presented: presented,
      preferences: ReadingMomentsPreferences.fromJson(raw['preferences']),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _activity.dispose();
    super.dispose();
  }
}

/// A timer-free causal gate: elapsed foreground time is pending until a genuine
/// meaningful page/scroll movement confirms it. Menus and route/lifecycle changes
/// discard unconfirmed tails. A long static page can confirm at most 180 seconds.
class VerifiedReadingSession {
  VerifiedReadingSession({
    required this.store,
    required this.bookId,
    DateTime Function()? now,
    Duration Function()? elapsed,
    this.idleWindow = const Duration(seconds: 180),
    this.minimumDwell = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now {
    _elapsed = elapsed ?? (() => _clock.elapsed);
    _clock.start();
  }

  final ReadingMomentsStore store;
  final int bookId;
  final Duration idleWindow, minimumDwell;
  final DateTime Function() _now;
  final Stopwatch _clock = Stopwatch();
  late final Duration Function() _elapsed;
  Duration? _start;
  DateTime? _wall;
  Object? _audioSegment;
  Duration? _audioPosition;
  Duration? _audioAnchorPosition;
  Duration? _audioCallbackElapsed;
  DateTime? _audioPendingAt;
  Duration _audioPendingElapsed = Duration.zero;
  bool _active = false;
  Future<void> _writes = Future.value();

  bool get active => _active;
  Future<void> get settled {
    _flushPlayback();
    return _writes;
  }

  void setActive(bool value) {
    if (_active == value) return;
    _active = value;
    resetPending();
  }

  /// Restores, seeks and reflows establish a new baseline but earn no interval.
  void resetPending() {
    _flushPlayback();
    _start = _active ? _elapsed() : null;
    _wall = _active ? _now() : null;
    _audioSegment = null;
    _audioPosition = null;
    _audioAnchorPosition = null;
    _audioCallbackElapsed = null;
  }

  /// Returns whether a real dwell was confirmed (also required for completion).
  bool advance() {
    _flushPlayback();
    final start = _start, wall = _wall, end = _elapsed();
    if (!_active || start == null || wall == null) return false;
    final duration = end - start;
    _start = end;
    _wall = _now();
    _audioAnchorPosition = _audioPosition;
    if (duration < minimumDwell) return false;
    final bounded = Duration(
      microseconds: math.min(
        duration.inMicroseconds,
        idleWindow.inMicroseconds,
      ),
    );
    _record(wall, bounded);
    return true;
  }

  /// Actual playing progress confirms only the time between advancing callbacks.
  /// Controller existence, paused/preparing state and seeks never confirm time.
  void playbackProgress({
    required Object segment,
    required Duration position,
    required bool playing,
    double speed = 1,
  }) {
    if (!_active || !playing) {
      _flushPlayback();
      _audioSegment = null;
      _audioPosition = null;
      _audioAnchorPosition = null;
      _audioCallbackElapsed = null;
      return;
    }
    final end = _elapsed();
    final previous = _audioPosition;
    if (_audioSegment != segment || previous == null || position < previous) {
      _audioSegment = segment;
      _audioPosition = position;
      _audioAnchorPosition = position;
      _audioCallbackElapsed = end;
      _start = end;
      _wall = _now();
      return;
    }
    if (position <= previous) return;
    final callbackElapsed = end - (_audioCallbackElapsed ?? end);
    final rate = speed.isFinite && speed > 0 ? speed : 1.0;
    final plausibleAdvance = callbackElapsed.inMicroseconds * rate + 250000;
    _audioPosition = position;
    _audioCallbackElapsed = end;
    // A seek can publish through the same notifier as decoder progress. A
    // position jump larger than elapsed playback establishes a new baseline.
    if ((position - previous).inMicroseconds > plausibleAdvance) {
      _flushPlayback();
      _audioAnchorPosition = position;
      _start = end;
      _wall = _now();
      return;
    }
    final start = _start, wall = _wall;
    if (start == null || wall == null) return;
    final elapsed = end - start;
    // Decoder evidence also covers short spoken fragments; unlike a page flip,
    // a sub-second advancing callback is not a fast navigation gesture.
    if (elapsed <= Duration.zero) return;
    _start = end;
    _wall = _now();
    final mediaElapsed = position - (_audioAnchorPosition ?? position);
    _audioAnchorPosition = position;
    if (elapsed > const Duration(seconds: 5)) return;
    final confirmed = Duration(
      microseconds: math.min(
        elapsed.inMicroseconds,
        (mediaElapsed.inMicroseconds / rate).round(),
      ),
    );
    if (confirmed > Duration.zero) _bufferPlayback(wall, confirmed);
  }

  void _bufferPlayback(DateTime wall, Duration duration) {
    final expected = _audioPendingAt?.add(_audioPendingElapsed);
    // Wall-clock corrections affect only the next segment's local-day owner.
    if (expected != null &&
        wall.difference(expected).abs() > const Duration(seconds: 1)) {
      _flushPlayback();
    }
    _audioPendingAt ??= wall;
    _audioPendingElapsed += duration;
    if (_audioPendingElapsed >= const Duration(seconds: 30)) _flushPlayback();
  }

  void _flushPlayback() {
    final wall = _audioPendingAt;
    if (wall == null) return;
    final duration = _audioPendingElapsed;
    _audioPendingAt = null;
    _audioPendingElapsed = Duration.zero;
    _record(wall, duration);
  }

  void _record(DateTime wall, Duration duration) {
    _writes = _writes
        .then(
          (_) => store.recordVerifiedInterval(
            bookId: bookId,
            startedAt: wall,
            elapsed: duration,
          ),
        )
        .catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'verified reading',
              context: ErrorDescription('while saving reading memories'),
            ),
          );
        });
  }

  void dispose() {
    setActive(false);
    _clock.stop();
  }
}

DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);
DateTime _timestamp(Object? value) {
  if (value is! int || value < 0 || value > 8640000000000000) {
    throw const FormatException('阅读纪念日期格式有误');
  }
  return DateTime.fromMillisecondsSinceEpoch(value);
}

DateTime? _optionalTimestamp(Object? value) =>
    value == null ? null : _timestamp(value);
