import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

part 'reading_activity_detail.dart';

/// A local calendar day's measured foreground reading activity.
@immutable
class ReadingActivityDay {
  ReadingActivityDay({
    required this.date,
    required this.seconds,
    required Iterable<int> bookIds,
  }) : bookIds = Set.unmodifiable(bookIds);

  final DateTime date;
  final int seconds;
  final Set<int> bookIds;
}

/// Local-only, independently observable reading ledger.
///
/// Counters belong to an installation and a calendar day. Backup merges take
/// each counter's maximum, so importing the same backup cannot add time twice.
/// Milliseconds are retained internally to preserve short interrupted sessions.
class ReadingActivityStore extends ChangeNotifier {
  ReadingActivityStore({
    String? record,
    Future<void> Function()? persist,
    bool collectDetails = true,
  }) : _record = record == null
           ? _ActivityRecord.empty()
           : _ActivityRecord.decode(record),
       _persist = persist,
       _collectDetails = collectDetails;

  static const preferenceKey = 'reading_activity_v1';
  final Future<void> Function()? _persist;
  // The verified-milestone ledger reuses daily counters but does not need a
  // second history of foreground hours and sessions.
  final bool _collectDetails;
  final _ActivityRecord _record;
  List<ReadingActivityDay>? _days;
  List<ReadingActivityHour>? _hours;
  List<ReadingActivitySessionRecord>? _sessions;
  Map<int, ReadingActivityInstant>? _firstOpenedAt;
  bool _disposed = false;
  bool _notificationQueued = false;

  /// The first measured interval, not a reconstructed historical timestamp.
  DateTime? get startedAt => _record.startedAt;

  /// Recorded days only; [daysEndingAt] also includes days with no activity.
  List<ReadingActivityDay> get days => _days ??= _record.aggregate();

  int get totalSeconds => days.fold(0, (total, day) => total + day.seconds);

  /// Detail coverage starts with a newly observed reading event. Old daily
  /// totals never acquire invented hours, sessions, or first-open timestamps.
  ReadingActivityInstant? get detailStartedAt => _record.details.startedAt;
  List<ReadingActivityHour> get hours =>
      _hours ??= _record.details.aggregateHours();
  List<ReadingActivitySessionRecord> get sessions =>
      _sessions ??= _record.details.aggregateSessions();
  Map<int, ReadingActivityInstant> get firstOpenedAt =>
      _firstOpenedAt ??= _record.details.aggregateFirstOpenedAt();

  /// Per-book measurements exist only for newly recorded intervals. Legacy
  /// daily totals are deliberately not divided among their book identifiers.
  List<ReadingActivityDay> daysForBook(int bookId) {
    final totals = <String, int>{};
    for (final source in _record.sources.values) {
      for (final day in source.entries) {
        final measured = day.value.bookMilliseconds[bookId];
        if (measured != null) {
          totals.update(
            day.key,
            (value) => value + measured,
            ifAbsent: () => measured,
          );
        }
      }
    }
    final dates = totals.keys.toList()..sort();
    return List.unmodifiable([
      for (final date in dates)
        ReadingActivityDay(
          date: DateTime.parse(date),
          seconds: totals[date]! ~/ 1000,
          bookIds: [bookId],
        ),
    ]);
  }

  /// Returns [count] chronological local calendar days, including [end].
  List<ReadingActivityDay> daysEndingAt(DateTime end, int count) {
    if (count < 0) throw ArgumentError.value(count, 'count');
    final local = end.toLocal();
    final byDate = {for (final day in days) _dateKey(day.date): day};
    return List.unmodifiable([
      for (var offset = count - 1; offset >= 0; offset--)
        byDate[_dateKey(
              DateTime(local.year, local.month, local.day - offset),
            )] ??
            ReadingActivityDay(
              date: DateTime(local.year, local.month, local.day - offset),
              seconds: 0,
              bookIds: const [],
            ),
    ]);
  }

  /// Records actual elapsed time. Also serves as a deterministic fixture entry
  /// point; existing reading positions are never converted into activity.
  Future<void> recordInterval({
    required int bookId,
    required DateTime startedAt,
    required Duration elapsed,
  }) async {
    _validateBookId(bookId);
    if (elapsed.inMilliseconds <= 0) return;
    final token = _beginSession(bookId, startedAt);
    await _recordSessionInterval(token, startedAt, elapsed);
  }

  _ActivitySessionToken _beginSession(int bookId, DateTime start) {
    _validateBookId(bookId);
    final instant = ReadingActivityInstant.fromDateTime(start.toLocal());
    final token = _ActivitySessionToken(
      _collectDetails ? '${_record.sourceId}_${_newIdentity()}' : '',
      bookId,
      instant,
    );
    if (_collectDetails) {
      _record.details.observeOpen(_record.sourceId, bookId, instant);
      _changed();
    }
    return token;
  }

  Future<void> _recordSessionInterval(
    _ActivitySessionToken token,
    DateTime startedAt,
    Duration elapsed, {
    bool persistEmpty = false,
  }) async {
    var remaining = elapsed.inMilliseconds;
    if (remaining <= 0) {
      // Opening visible text is independently observable, even when it closes
      // within the monotonic clock's first millisecond.
      if (persistEmpty && _collectDetails) await _persist?.call();
      return;
    }
    final bookId = token.bookId;
    var cursor = startedAt.toLocal();
    _record.startedAt = _earliest(_record.startedAt, cursor);
    final source = _record.sources.putIfAbsent(_record.sourceId, () => {});
    final sessionDays = <String, int>{};
    while (remaining > 0) {
      // Local construction handles skipped/repeated DST hours. A repeated hour
      // belongs to the same civil bucket, with its actual elapsed milliseconds.
      final boundary = _collectDetails
          ? DateTime(cursor.year, cursor.month, cursor.day, cursor.hour + 1)
          : DateTime(cursor.year, cursor.month, cursor.day + 1);
      final portion = min(
        remaining,
        boundary.difference(cursor).inMilliseconds,
      );
      if (portion <= 0) {
        throw StateError('Local reading-hour boundary did not advance');
      }
      final date = _dateKey(cursor);
      final counter = source.putIfAbsent(date, _ActivityCounter.new);
      counter.milliseconds += portion;
      counter.bookIds.add(bookId);
      counter.bookMilliseconds.update(
        bookId,
        (value) => value + portion,
        ifAbsent: () => portion,
      );
      if (_collectDetails) {
        sessionDays.update(
          date,
          (value) => value + portion,
          ifAbsent: () => portion,
        );
        _record.details.recordHour(_record.sourceId, bookId, cursor, portion);
      }
      remaining -= portion;
      cursor = cursor.add(Duration(milliseconds: portion));
    }
    if (_collectDetails) {
      _record.details.recordSession(
        _record.sourceId,
        token,
        ReadingActivityInstant.fromDateTime(cursor),
        elapsed.inMilliseconds,
        sessionDays,
      );
    }
    _changed();
    await _persist?.call();
  }

  /// Encodes the complete local ledger, including the local writer identity.
  String encode() => _record.encode();

  /// Validates a backup record without creating a notifier or writer identity.
  static String validateRecord(String record) =>
      _ActivityRecord.decode(record).encode();

  /// Prepares the transaction's merged value without publishing it to the UI.
  String mergedRecord(String incoming) => _ActivityRecord.decode(
    encode(),
  ).merge(_ActivityRecord.decode(incoming)).encode();

  /// Publishes an idempotent merge after the surrounding restore commits.
  /// The current installation remains the writer, even on a fresh import.
  Future<void> mergeRecord(String incoming, {bool persist = true}) async {
    _record.merge(_ActivityRecord.decode(incoming));
    _changed();
    if (persist) await _persist?.call();
  }

  void _changed() {
    _days = null;
    _hours = null;
    _sessions = null;
    _firstOpenedAt = null;
    if (_disposed || _notificationQueued) return;
    _notificationQueued = true;
    scheduleMicrotask(() {
      _notificationQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Low-frequency elapsed-time sampler. The reader owns visibility eligibility;
/// this class never infers reading from gestures or from saved positions.
class ReadingActivitySession {
  ReadingActivitySession({
    required this.store,
    required this.bookId,
    DateTime Function()? now,
    Duration Function()? elapsed,
    this.interval = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now {
    _elapsed = elapsed ?? (() => _clock.elapsed);
    _clock.start();
  }

  final ReadingActivityStore store;
  final int bookId;
  final Duration interval;
  final DateTime Function() _now;
  final Stopwatch _clock = Stopwatch();
  late final Duration Function() _elapsed;
  DateTime? _startedAt;
  Duration? _startedElapsed;
  _ActivitySessionToken? _session;
  Timer? _timer;
  bool _disposed = false;

  bool get active => _startedAt != null;

  /// Pausing settles immediately; resuming starts a new monotonic segment.
  void setActive(bool value) {
    if (_disposed || active == value) return;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      _settle(restart: false);
    } else {
      _startedAt = _now();
      _startedElapsed = _elapsed();
      _session = store._beginSession(bookId, _startedAt!);
      _timer = Timer.periodic(interval, (_) => _settle(restart: true));
    }
  }

  void _settle({required bool restart}) {
    final start = _startedAt,
        startElapsed = _startedElapsed,
        session = _session;
    if (start == null || startElapsed == null || session == null) return;
    final endElapsed = _elapsed();
    _startedAt = restart ? _now() : null;
    _startedElapsed = restart ? endElapsed : null;
    if (!restart) _session = null;
    // Wall-clock corrections affect only the next segment's day attribution,
    // never the measured duration of the current interval.
    unawaited(
      store
          ._recordSessionInterval(
            session,
            start,
            endElapsed - startElapsed,
            persistEmpty: !restart,
          )
          .catchError((Object error, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: 'reading activity',
                context: ErrorDescription('while saving local reading time'),
              ),
            );
          }),
    );
  }

  /// Stops the timer and settles the last visible interval exactly once.
  void dispose() {
    setActive(false);
    _disposed = true;
    _clock.stop();
  }
}

class _ActivityCounter {
  _ActivityCounter({
    this.milliseconds = 0,
    Iterable<int> bookIds = const [],
    Map<int, int> bookMilliseconds = const {},
  }) : bookIds = {...bookIds},
       bookMilliseconds = {...bookMilliseconds};
  int milliseconds;
  final Set<int> bookIds;
  final Map<int, int> bookMilliseconds;
}

class _ActivityRecord {
  _ActivityRecord(
    this.sourceId,
    this.startedAt,
    this.sources, [
    _ActivityDetailLedger? details,
  ]) : details = details ?? _ActivityDetailLedger();

  factory _ActivityRecord.empty() {
    return _ActivityRecord(_newIdentity(), null, {});
  }

  final String sourceId;
  DateTime? startedAt;
  final Map<String, Map<String, _ActivityCounter>> sources;
  final _ActivityDetailLedger details;

  static _ActivityRecord decode(String value) {
    final raw = jsonDecode(value);
    if (raw is! Map<String, dynamic> || raw['version'] != 1) {
      throw const FormatException('阅读活动记录格式有误');
    }
    final source = raw['sourceId'], start = raw['startedAt'];
    final data = raw['sources'];
    if (!_validSource(source) ||
        data is! Map<String, dynamic> ||
        (start != null &&
            (start is! int || start < 0 || start > 8640000000000000))) {
      throw const FormatException('阅读活动记录格式有误');
    }
    final sources = <String, Map<String, _ActivityCounter>>{};
    for (final entry in data.entries) {
      if (!_validSource(entry.key) || entry.value is! Map<String, dynamic>) {
        throw const FormatException('阅读活动来源格式有误');
      }
      final days = <String, _ActivityCounter>{};
      for (final day in (entry.value as Map<String, dynamic>).entries) {
        final parsed = DateTime.tryParse(day.key);
        final counter = day.value;
        if (parsed == null ||
            _dateKey(parsed) != day.key ||
            counter is! Map<String, dynamic>) {
          throw const FormatException('阅读活动日期格式有误');
        }
        final milliseconds = counter['milliseconds'], books = counter['books'];
        if (milliseconds is! int ||
            milliseconds <= 0 ||
            milliseconds > 9007199254740991 ||
            books is! List ||
            books.isEmpty ||
            books.any((id) => id is! int || id <= 0 || id > 9999999999)) {
          throw const FormatException('阅读活动时长或书籍格式有误');
        }
        final perBook = counter['bookMilliseconds'];
        final measured = <int, int>{};
        if (perBook != null) {
          if (perBook is! Map<String, dynamic>) {
            throw const FormatException('单书阅读时长格式有误');
          }
          for (final entry in perBook.entries) {
            final id = int.tryParse(entry.key), time = entry.value;
            if (id == null ||
                !books.contains(id) ||
                time is! int ||
                time <= 0 ||
                time > milliseconds) {
              throw const FormatException('单书阅读时长格式有误');
            }
            measured[id] = time;
          }
        }
        days[day.key] = _ActivityCounter(
          milliseconds: milliseconds,
          bookIds: books.cast<int>(),
          bookMilliseconds: measured,
        );
      }
      sources[entry.key] = days;
    }
    if (sources.values.any((days) => days.isNotEmpty) && start == null) {
      throw const FormatException('阅读活动缺少开始日期');
    }
    return _ActivityRecord(
      source as String,
      start == null ? null : DateTime.fromMillisecondsSinceEpoch(start as int),
      sources,
      _ActivityDetailLedger.decode(raw['details']),
    );
  }

  _ActivityRecord merge(_ActivityRecord other) {
    details.merge(other.details);
    startedAt = _earliest(startedAt, other.startedAt);
    for (final source in other.sources.entries) {
      final target = sources.putIfAbsent(source.key, () => {});
      for (final day in source.value.entries) {
        final counter = target.putIfAbsent(day.key, _ActivityCounter.new);
        counter.milliseconds = max(
          counter.milliseconds,
          day.value.milliseconds,
        );
        counter.bookIds.addAll(day.value.bookIds);
        for (final book in day.value.bookMilliseconds.entries) {
          counter.bookMilliseconds.update(
            book.key,
            (value) => max(value, book.value),
            ifAbsent: () => book.value,
          );
        }
      }
    }
    return this;
  }

  List<ReadingActivityDay> aggregate() {
    final totals = <String, _ActivityCounter>{};
    for (final source in sources.values) {
      for (final day in source.entries) {
        final total = totals.putIfAbsent(day.key, _ActivityCounter.new);
        total.milliseconds += day.value.milliseconds;
        total.bookIds.addAll(day.value.bookIds);
      }
    }
    final dates = totals.keys.toList()..sort();
    return List.unmodifiable([
      for (final date in dates)
        ReadingActivityDay(
          date: DateTime.parse(date),
          seconds: totals[date]!.milliseconds ~/ 1000,
          bookIds: totals[date]!.bookIds,
        ),
    ]);
  }

  String encode() {
    final counters = jsonEncode({
      'version': 1,
      'sourceId': sourceId,
      if (startedAt != null) 'startedAt': startedAt!.millisecondsSinceEpoch,
      'sources': {
        for (final source in sources.entries)
          source.key: {
            for (final day in source.value.entries)
              day.key: {
                'milliseconds': day.value.milliseconds,
                'books': day.value.bookIds.toList()..sort(),
                if (day.value.bookMilliseconds.isNotEmpty)
                  'bookMilliseconds': {
                    for (final book in day.value.bookMilliseconds.entries)
                      '${book.key}': book.value,
                  },
              },
          },
      },
    });
    return details.startedAt == null
        ? counters
        : '${counters.substring(0, counters.length - 1)},"details":${details.encode()}}';
  }
}

void _validateBookId(int bookId) {
  if (bookId <= 0 || bookId > 9999999999) {
    throw ArgumentError.value(bookId, 'bookId');
  }
}

String _newIdentity() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool _validSource(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

String _dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

DateTime? _earliest(DateTime? first, DateTime? second) => first == null
    ? second
    : (second == null || first.isBefore(second) ? first : second);
