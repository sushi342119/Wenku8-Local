part of 'reading_activity.dart';

/// A measured instant together with the civil offset at the time of reading.
/// Moving to another timezone later cannot move an event to a different date.
@immutable
class ReadingActivityInstant implements Comparable<ReadingActivityInstant> {
  const ReadingActivityInstant({
    required this.epochMilliseconds,
    required this.offsetMinutes,
  });

  factory ReadingActivityInstant.fromDateTime(DateTime value) =>
      ReadingActivityInstant(
        epochMilliseconds: value.millisecondsSinceEpoch,
        offsetMinutes: value.timeZoneOffset.inMinutes,
      );

  final int epochMilliseconds;
  final int offsetMinutes;

  /// UTC-marked civil components, not an instant to convert with `toLocal()`.
  DateTime get localDateTime => DateTime.fromMillisecondsSinceEpoch(
    epochMilliseconds,
    isUtc: true,
  ).add(Duration(minutes: offsetMinutes));
  DateTime get date {
    final value = localDateTime;
    return DateTime.utc(value.year, value.month, value.day);
  }

  int get hour => localDateTime.hour;

  @override
  int compareTo(ReadingActivityInstant other) =>
      epochMilliseconds.compareTo(other.epochMilliseconds);

  @override
  bool operator ==(Object other) =>
      other is ReadingActivityInstant &&
      epochMilliseconds == other.epochMilliseconds &&
      offsetMinutes == other.offsetMinutes;

  @override
  int get hashCode => Object.hash(epochMilliseconds, offsetMinutes);
}

/// Measured reading in one recorded civil hour and one book. Fall-back DST
/// hours may contain more than 60 minutes; missing spring hours remain absent.
@immutable
class ReadingActivityHour {
  const ReadingActivityHour({
    required this.date,
    required this.hour,
    required this.bookId,
    required this.milliseconds,
    required this.firstReadingAt,
    required this.latestReadingAt,
  });

  final DateTime date;
  final int hour;
  final int bookId;
  final int milliseconds;
  final ReadingActivityInstant firstReadingAt;

  /// Greatest observed civil clock value in this hour, breaking ties by epoch.
  /// A repeated DST hour can end at 01:10 after already reaching 01:59.
  final ReadingActivityInstant latestReadingAt;
  int get seconds => milliseconds ~/ 1000;
}

/// One continuously eligible foreground session, not one 30-second flush.
/// Wall-clock corrections may make endedAt precede startedAt; only measured
/// monotonic milliseconds determine duration. Civil day allocations survive it.
@immutable
class ReadingActivitySessionRecord {
  ReadingActivitySessionRecord({
    required this.id,
    required this.bookId,
    required this.startedAt,
    required this.endedAt,
    required this.milliseconds,
    required Map<DateTime, int> dayMilliseconds,
  }) : dayMilliseconds = Map.unmodifiable(dayMilliseconds);

  final String id;
  final int bookId;
  final ReadingActivityInstant startedAt;
  final ReadingActivityInstant endedAt;
  final int milliseconds;
  final Map<DateTime, int> dayMilliseconds;
  int get seconds => milliseconds ~/ 1000;
}

class _ActivitySessionToken {
  const _ActivitySessionToken(this.id, this.bookId, this.startedAt);
  final String id;
  final int bookId;
  final ReadingActivityInstant startedAt;
}

class _ActivityHourCounter {
  _ActivityHourCounter({
    required this.date,
    required this.hour,
    required this.bookId,
    required this.milliseconds,
    required this.firstReadingAt,
    required this.latestReadingAt,
  });

  final String date;
  final int hour;
  final int bookId;
  int milliseconds;
  ReadingActivityInstant firstReadingAt;
  ReadingActivityInstant latestReadingAt;
  String get key => '$date/$hour/$bookId';

  _ActivityHourCounter copy() => _ActivityHourCounter(
    date: date,
    hour: hour,
    bookId: bookId,
    milliseconds: milliseconds,
    firstReadingAt: firstReadingAt,
    latestReadingAt: latestReadingAt,
  );

  void includeBounds(_ActivityHourCounter other) {
    firstReadingAt = _earliestInstant(firstReadingAt, other.firstReadingAt)!;
    latestReadingAt = _latestClockInstant(
      latestReadingAt,
      other.latestReadingAt,
    );
  }

  ReadingActivityHour snapshot() => ReadingActivityHour(
    date: _civilDate(date),
    hour: hour,
    bookId: bookId,
    milliseconds: milliseconds,
    firstReadingAt: firstReadingAt,
    latestReadingAt: latestReadingAt,
  );
}

class _ActivitySessionCounter {
  _ActivitySessionCounter({
    required this.id,
    required this.bookId,
    required this.startedAt,
    required this.endedAt,
    required this.milliseconds,
    required this.dayMilliseconds,
  });
  final String id;
  final int bookId;
  final ReadingActivityInstant startedAt;
  ReadingActivityInstant endedAt;
  int milliseconds;
  final Map<String, int> dayMilliseconds;

  _ActivitySessionCounter copy() => _ActivitySessionCounter(
    id: id,
    bookId: bookId,
    startedAt: startedAt,
    endedAt: endedAt,
    milliseconds: milliseconds,
    dayMilliseconds: {...dayMilliseconds},
  );

  ReadingActivitySessionRecord snapshot() => ReadingActivitySessionRecord(
    id: id,
    bookId: bookId,
    startedAt: startedAt,
    endedAt: endedAt,
    milliseconds: milliseconds,
    dayMilliseconds: {
      for (final entry in dayMilliseconds.entries)
        _civilDate(entry.key): entry.value,
    },
  );
}

class _ActivityDetailSource {
  final Map<String, _ActivityHourCounter> hours = {};
  final Map<String, _ActivitySessionCounter> sessions = {};
  final Map<int, ReadingActivityInstant> firstOpenedAt = {};
  final Map<String, String> _encodedHours = {};
  final Map<String, String> _encodedSessions = {};
  String? _encodedFirstOpenedAt;
  String? _encoded;

  void changedHour(String key) {
    _encodedHours.remove(key);
    _encoded = null;
  }

  void changedSession(String key) {
    _encodedSessions.remove(key);
    _encoded = null;
  }

  void changedFirstOpenedAt() {
    _encodedFirstOpenedAt = null;
    _encoded = null;
  }

  // Only changed cumulative counters need JSON traversal on a 30-second flush.
  // This cache changes neither the persisted schema nor its merge semantics.
  String encode() {
    if (_encoded != null) return _encoded!;
    final hourRecords = hours.values
        .map(
          (hour) =>
              _encodedHours.putIfAbsent(hour.key, () => _encodeHour(hour)),
        )
        .join(',');
    final sessionRecords = sessions.values
        .map(
          (session) => _encodedSessions.putIfAbsent(
            session.id,
            () => _encodeSession(session),
          ),
        )
        .join(',');
    final firstOpened = _encodedFirstOpenedAt ??= jsonEncode({
      for (final book in firstOpenedAt.entries)
        '${book.key}': _encodeInstant(book.value),
    });
    return _encoded =
        '{"hours":[$hourRecords],"sessions":{$sessionRecords},'
        '"firstOpenedAt":$firstOpened}';
  }

  String _encodeHour(_ActivityHourCounter hour) => jsonEncode({
    'date': hour.date,
    'hour': hour.hour,
    'bookId': hour.bookId,
    'milliseconds': hour.milliseconds,
    'firstReadingAt': _encodeInstant(hour.firstReadingAt),
    'latestReadingAt': _encodeInstant(hour.latestReadingAt),
  });

  String _encodeSession(_ActivitySessionCounter session) {
    final record = jsonEncode({
      'bookId': session.bookId,
      'startedAt': _encodeInstant(session.startedAt),
      'endedAt': _encodeInstant(session.endedAt),
      'milliseconds': session.milliseconds,
      'days': session.dayMilliseconds,
    });
    return '${jsonEncode(session.id)}:$record';
  }
}

class _ActivityDetailLedger {
  ReadingActivityInstant? startedAt;
  final Map<String, _ActivityDetailSource> sources = {};

  void observeOpen(String sourceId, int bookId, ReadingActivityInstant at) {
    startedAt = _earliestInstant(startedAt, at);
    final source = sources.putIfAbsent(sourceId, _ActivityDetailSource.new);
    final before = source.firstOpenedAt[bookId];
    final after = _earliestInstant(before, at)!;
    if (before != after) {
      source.firstOpenedAt[bookId] = after;
      source.changedFirstOpenedAt();
    }
  }

  void recordHour(String sourceId, int bookId, DateTime start, int duration) {
    final source = sources[sourceId]!;
    // Last included millisecond belongs to this bucket, not the next hour.
    final first = ReadingActivityInstant.fromDateTime(start);
    final last = _latestReadingWithinHour(start, duration);
    final value = _ActivityHourCounter(
      date: _dateKey(first.localDateTime),
      hour: first.hour,
      bookId: bookId,
      milliseconds: duration,
      firstReadingAt: first,
      latestReadingAt: last,
    );
    final existing = source.hours[value.key];
    if (existing == null) {
      source.hours[value.key] = value;
    } else {
      existing.milliseconds += duration;
      existing.includeBounds(value);
    }
    source.changedHour(value.key);
  }

  void recordSession(
    String sourceId,
    _ActivitySessionToken token,
    ReadingActivityInstant end,
    int duration,
    Map<String, int> days,
  ) {
    final source = sources[sourceId]!;
    final value = source.sessions.putIfAbsent(
      token.id,
      () => _ActivitySessionCounter(
        id: token.id,
        bookId: token.bookId,
        startedAt: token.startedAt,
        endedAt: end,
        milliseconds: 0,
        dayMilliseconds: {},
      ),
    );
    value.milliseconds += duration;
    value.endedAt = end;
    for (final day in days.entries) {
      value.dayMilliseconds.update(
        day.key,
        (value) => value + day.value,
        ifAbsent: () => day.value,
      );
    }
    source.changedSession(token.id);
  }

  List<ReadingActivityHour> aggregateHours() {
    final totals = <String, _ActivityHourCounter>{};
    for (final source in sources.values) {
      for (final hour in source.hours.values) {
        final total = totals[hour.key];
        if (total == null) {
          totals[hour.key] = hour.copy();
        } else {
          total.milliseconds += hour.milliseconds;
          total.includeBounds(hour);
        }
      }
    }
    final result = totals.values.map((hour) => hour.snapshot()).toList()
      ..sort((a, b) {
        final date = a.date.compareTo(b.date);
        if (date != 0) return date;
        final hour = a.hour.compareTo(b.hour);
        return hour != 0 ? hour : a.bookId.compareTo(b.bookId);
      });
    return List.unmodifiable(result);
  }

  List<ReadingActivitySessionRecord> aggregateSessions() => List.unmodifiable(
    sources.values
        .expand((source) => source.sessions.values)
        .map((session) => session.snapshot())
        .toList()
      ..sort((a, b) {
        final start = a.startedAt.compareTo(b.startedAt);
        return start != 0 ? start : a.id.compareTo(b.id);
      }),
  );

  Map<int, ReadingActivityInstant> aggregateFirstOpenedAt() {
    final result = <int, ReadingActivityInstant>{};
    for (final source in sources.values) {
      for (final entry in source.firstOpenedAt.entries) {
        result.update(
          entry.key,
          (value) => _earliestInstant(value, entry.value)!,
          ifAbsent: () => entry.value,
        );
      }
    }
    return Map.unmodifiable(result);
  }

  void merge(_ActivityDetailLedger other) {
    // Validate all shared identities before mutating any published counters.
    for (final source in other.sources.entries) {
      for (final session in source.value.sessions.values) {
        final current = sources[source.key]?.sessions[session.id];
        if (current != null &&
            (current.bookId != session.bookId ||
                current.startedAt != session.startedAt)) {
          throw const FormatException('阅读活动会话标识冲突');
        }
      }
    }
    startedAt = _earliestInstant(startedAt, other.startedAt);
    for (final entry in other.sources.entries) {
      final target = sources.putIfAbsent(entry.key, _ActivityDetailSource.new);
      for (final hour in entry.value.hours.values) {
        final current = target.hours[hour.key];
        if (current == null) {
          target.hours[hour.key] = hour.copy();
        } else {
          current.milliseconds = max(current.milliseconds, hour.milliseconds);
          current.includeBounds(hour);
        }
        target.changedHour(hour.key);
      }
      for (final session in entry.value.sessions.values) {
        final current = target.sessions[session.id];
        if (current == null) {
          target.sessions[session.id] = session.copy();
        } else {
          if (session.milliseconds > current.milliseconds) {
            // These are cumulative snapshots of the same continuous session.
            // Keep one complete snapshot, including a backward-adjusted end.
            target.sessions[session.id] = session.copy();
          }
        }
        target.changedSession(session.id);
      }
      for (final book in entry.value.firstOpenedAt.entries) {
        target.firstOpenedAt.update(
          book.key,
          (value) => _earliestInstant(value, book.value)!,
          ifAbsent: () => book.value,
        );
      }
      target.changedFirstOpenedAt();
    }
  }

  static _ActivityDetailLedger decode(Object? raw) {
    final result = _ActivityDetailLedger();
    if (raw == null) return result;
    if (raw is! Map<String, dynamic> ||
        raw['version'] != 1 ||
        raw['sources'] is! Map<String, dynamic>) {
      throw const FormatException('阅读活动明细格式有误');
    }
    result.startedAt = _decodeInstant(raw['startedAt']);
    for (final entry in (raw['sources'] as Map<String, dynamic>).entries) {
      final data = entry.value;
      if (!_validSource(entry.key) ||
          data is! Map<String, dynamic> ||
          data['hours'] is! List ||
          data['sessions'] is! Map<String, dynamic> ||
          data['firstOpenedAt'] is! Map<String, dynamic>) {
        throw const FormatException('阅读活动明细来源格式有误');
      }
      final source = _ActivityDetailSource();
      for (final rawHour in data['hours'] as List) {
        if (rawHour is! Map<String, dynamic> ||
            !_validDateKey(rawHour['date']) ||
            rawHour['hour'] is! int ||
            (rawHour['hour'] as int) < 0 ||
            (rawHour['hour'] as int) > 23 ||
            !_validBook(rawHour['bookId']) ||
            !_validMilliseconds(rawHour['milliseconds'])) {
          throw const FormatException('阅读活动小时格式有误');
        }
        final first = _decodeInstant(rawHour['firstReadingAt']);
        final last = _decodeInstant(rawHour['latestReadingAt']);
        final hour = _ActivityHourCounter(
          date: rawHour['date'] as String,
          hour: rawHour['hour'] as int,
          bookId: rawHour['bookId'] as int,
          milliseconds: rawHour['milliseconds'] as int,
          firstReadingAt: first,
          latestReadingAt: last,
        );
        if (first.compareTo(last) > 0 ||
            [first, last].any(
              (at) =>
                  _dateKey(at.localDateTime) != hour.date ||
                  at.hour != hour.hour,
            ) ||
            source.hours.containsKey(hour.key)) {
          throw const FormatException('阅读活动小时边界有误');
        }
        source.hours[hour.key] = hour;
      }
      for (final entrySession
          in (data['sessions'] as Map<String, dynamic>).entries) {
        final session = entrySession.value;
        if (!RegExp(
              '^${entry.key}_[a-f0-9]{32}\$',
            ).hasMatch(entrySession.key) ||
            session is! Map<String, dynamic> ||
            !_validBook(session['bookId']) ||
            !_validMilliseconds(session['milliseconds']) ||
            session['days'] is! Map<String, dynamic>) {
          throw const FormatException('阅读活动会话格式有误');
        }
        final days = <String, int>{};
        for (final day in (session['days'] as Map<String, dynamic>).entries) {
          if (!_validDateKey(day.key) || !_validMilliseconds(day.value)) {
            throw const FormatException('阅读活动会话日期格式有误');
          }
          days[day.key] = day.value as int;
        }
        if (days.values.fold<int>(0, (total, value) => total + value) !=
            session['milliseconds']) {
          throw const FormatException('阅读活动会话时长不一致');
        }
        source.sessions[entrySession.key] = _ActivitySessionCounter(
          id: entrySession.key,
          bookId: session['bookId'] as int,
          startedAt: _decodeInstant(session['startedAt']),
          endedAt: _decodeInstant(session['endedAt']),
          milliseconds: session['milliseconds'] as int,
          dayMilliseconds: days,
        );
      }
      for (final book
          in (data['firstOpenedAt'] as Map<String, dynamic>).entries) {
        final id = int.tryParse(book.key);
        if (!_validBook(id) || '$id' != book.key) {
          throw const FormatException('首次翻开书籍格式有误');
        }
        source.firstOpenedAt[id!] = _decodeInstant(book.value);
      }
      result.sources[entry.key] = source;
    }
    return result;
  }

  String encode() {
    final start = jsonEncode(_encodeInstant(startedAt!));
    final records = sources.entries
        .map((entry) => '${jsonEncode(entry.key)}:${entry.value.encode()}')
        .join(',');
    return '{"version":1,"startedAt":$start,"sources":{$records}}';
  }
}

Map<String, int> _encodeInstant(ReadingActivityInstant value) => {
  'epochMilliseconds': value.epochMilliseconds,
  'offsetMinutes': value.offsetMinutes,
};

ReadingActivityInstant _decodeInstant(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('阅读活动时刻格式有误');
  }
  final epoch = value['epochMilliseconds'], offset = value['offsetMinutes'];
  if (epoch is! int ||
      epoch < 0 ||
      epoch > 8639999913600000 ||
      offset is! int ||
      offset < -1440 ||
      offset > 1440) {
    throw const FormatException('阅读活动时刻格式有误');
  }
  return ReadingActivityInstant(
    epochMilliseconds: epoch,
    offsetMinutes: offset,
  );
}

bool _validBook(Object? value) =>
    value is int && value > 0 && value <= 9999999999;
bool _validMilliseconds(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _validDateKey(Object? value) {
  if (value is! String) return false;
  final date = DateTime.tryParse(value);
  return date != null && _dateKey(date) == value;
}

DateTime _civilDate(String value) {
  final date = DateTime.parse(value);
  return DateTime.utc(date.year, date.month, date.day);
}

ReadingActivityInstant? _earliestInstant(
  ReadingActivityInstant? first,
  ReadingActivityInstant? second,
) => first == null
    ? second
    : (second == null || first.compareTo(second) <= 0 ? first : second);

ReadingActivityInstant _latestClockInstant(
  ReadingActivityInstant first,
  ReadingActivityInstant second,
) {
  final clock = first.localDateTime.compareTo(second.localDateTime);
  return clock > 0 || (clock == 0 && first.compareTo(second) >= 0)
      ? first
      : second;
}

ReadingActivityInstant _latestReadingWithinHour(DateTime start, int duration) {
  final end = start.add(Duration(milliseconds: duration - 1));
  var latest = ReadingActivityInstant.fromDateTime(end);
  if (start.timeZoneOffset > end.timeZoneOffset) {
    // Only an offset transition needs this logarithmic search; ordinary
    // 30-second settles do constant work and never scan historical events.
    var low = 0, high = duration - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (start.add(Duration(milliseconds: middle)).timeZoneOffset ==
          start.timeZoneOffset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low > 0) {
      latest = _latestClockInstant(
        latest,
        ReadingActivityInstant.fromDateTime(
          start.add(Duration(milliseconds: low - 1)),
        ),
      );
    }
  }
  return latest;
}
