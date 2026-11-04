import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReadingTouchOrientation { portrait, landscape }

/// A fixed, normalized grid. Individual coordinates and book identities never
/// enter storage. The two orientations deliberately keep separate counters.
class ReadingTouchGrid {
  ReadingTouchGrid(this.orientation, Iterable<int> values)
    : cells = List<int>.unmodifiable(values);

  final ReadingTouchOrientation orientation;
  final List<int> cells;
  int get columns => orientation == ReadingTouchOrientation.portrait ? 12 : 20;
  int get rows => orientation == ReadingTouchOrientation.portrait ? 20 : 12;
  int get total => cells.fold(0, (sum, value) => sum + value);
  int get peak => cells.fold(0, (value, cell) => cell > value ? cell : value);
  int get occupied => cells.where((value) => value > 0).length;
  int get left => cells.indexed.fold(
    0,
    (sum, cell) => sum + (cell.$1 % columns < columns ~/ 2 ? cell.$2 : 0),
  );
  int get right => total - left;

  /// Broad zones are useful summaries; they do not infer the user's hand.
  String? get busiestZone {
    if (total == 0) return null;
    final zones = List<int>.filled(9, 0);
    for (var i = 0; i < cells.length; i++) {
      final x = (i % columns) * 3 ~/ columns;
      final y = (i ~/ columns) * 3 ~/ rows;
      zones[y * 3 + x] += cells[i];
    }
    var largest = 0;
    for (var i = 1; i < zones.length; i++) {
      if (zones[i] > zones[largest]) largest = i;
    }
    return const [
      '左上',
      '上方',
      '右上',
      '左侧',
      '中央',
      '右侧',
      '左下',
      '下方',
      '右下',
    ][largest];
  }
}

class ReadingTouchSnapshot {
  const ReadingTouchSnapshot({
    required this.portrait,
    required this.landscape,
    required this.startedAt,
  });
  final ReadingTouchGrid portrait, landscape;
  final DateTime? startedAt;
  int get total => portrait.total + landscape.total;
  ReadingTouchGrid grid(ReadingTouchOrientation orientation) =>
      orientation == ReadingTouchOrientation.portrait ? portrait : landscape;
}

/// Local counters, enabled by default while preserving an explicitly saved
/// pause. Independent of LibraryState, backup and sync. Pointer input only
/// increments a cell: no notification, JSON or I/O.
class ReadingTouchStore extends ChangeNotifier {
  ReadingTouchStore({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    DateTime Function()? now,
    this.flushDelay = const Duration(seconds: 30),
  }) : _read = read,
       _write = write,
       _now = now ?? DateTime.now,
       _loaded = read == null;

  static const preferenceKey = 'reading_touch_fingerprint_v1';
  static const cellCount = 240;
  static const maxCellCount = 0xffffffff;
  static ReadingTouchStore shared = ReadingTouchStore(
    read: () async =>
        (await SharedPreferences.getInstance()).getString(preferenceKey),
    write: (record) async {
      if (!await (await SharedPreferences.getInstance()).setString(
        preferenceKey,
        record,
      )) {
        throw StateError('touch counters were not persisted');
      }
    },
  );

  final Future<String?> Function()? _read;
  final Future<void> Function(String)? _write;
  final DateTime Function() _now;
  final Duration flushDelay;
  final _portrait = Uint32List(cellCount);
  final _landscape = Uint32List(cellCount);
  DateTime? _startedAt;
  bool _enabled = true, _loaded, _dirty = false, _disposed = false;
  bool _unreadable = false;
  int _revision = 0;
  Timer? _timer;
  Future<void>? _loading;
  Future<bool>? _saving;
  String? _error;

  bool get enabled => _enabled;
  bool get loaded => _loaded;
  bool get canRecord => _loaded && _enabled && !_disposed && !_unreadable;
  bool get unreadable => _unreadable;
  String? get error => _error;

  ReadingTouchSnapshot get snapshot => ReadingTouchSnapshot(
    portrait: ReadingTouchGrid(ReadingTouchOrientation.portrait, _portrait),
    landscape: ReadingTouchGrid(ReadingTouchOrientation.landscape, _landscape),
    startedAt: _startedAt,
  );

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _read?.call();
      if (_disposed) return;
      if (raw != null) _decode(raw);
    } catch (_) {
      // Preserve the unreadable record until the user explicitly clears it.
      _enabled = false;
      _unreadable = true;
      _error = '记录未能读取，可清空后重新开始';
    }
    _loaded = true;
    _changed();
  }

  Future<bool> setEnabled(bool value) async {
    await ensureLoaded();
    if (_disposed || _unreadable) return false;
    if (_enabled == value) return flush();
    _enabled = value;
    _markDirty();
    _changed();
    return flush();
  }

  /// x/y are fractions of the current article viewport, independent of pixel
  /// density and text scaling. Boundary points outside that viewport are ignored.
  void record({
    required double x,
    required double y,
    required ReadingTouchOrientation orientation,
  }) {
    if (!canRecord ||
        !x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        x >= 1 ||
        y < 0 ||
        y >= 1) {
      return;
    }
    final portrait = orientation == ReadingTouchOrientation.portrait;
    final grid = portrait ? _portrait : _landscape;
    final columns = portrait ? 12 : 20;
    final rows = portrait ? 20 : 12;
    final index = (y * rows).floor() * columns + (x * columns).floor();
    // Saturation keeps storage bounded even for exceptionally long-lived data.
    if (grid[index] == maxCellCount) return;
    _startedAt ??= _now();
    grid[index]++;
    _markDirty();
    _scheduleFlush();
  }

  Future<bool> clear() async {
    await ensureLoaded();
    if (_disposed) return false;
    _portrait.fillRange(0, cellCount, 0);
    _landscape.fillRange(0, cellCount, 0);
    _startedAt = null;
    _unreadable = false;
    _markDirty();
    _changed();
    return flush();
  }

  void _markDirty() {
    _revision++;
    _dirty = true;
  }

  void _scheduleFlush() {
    if (_timer != null || _disposed || _write == null) return;
    _timer = Timer(flushDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Called at a batch boundary, reader exit, app backgrounding or user action.
  /// Concurrent writes are serialized so clearing cannot resurrect old counts.
  Future<bool> flush() async {
    _timer?.cancel();
    _timer = null;
    while (_saving != null) {
      await _saving;
    }
    if (!_dirty || _unreadable) return _error == null;
    final revision = _revision;
    final record = _encode();
    final saving = _save(record, revision);
    _saving = saving;
    final result = await saving;
    if (identical(_saving, saving)) _saving = null;
    return result;
  }

  Future<bool> _save(String record, int revision) async {
    try {
      await _write?.call(record);
      if (_revision == revision) _dirty = false;
      final hadError = _error != null;
      _error = null;
      if (hadError) _changed();
      if (_dirty) _scheduleFlush();
      return true;
    } catch (_) {
      _error = '记录未能保存，当前次数仍在内存中';
      _changed();
      return false;
    }
  }

  String _encode() => jsonEncode({
    'version': 1,
    'enabled': _enabled,
    'startedAt': _startedAt?.toIso8601String(),
    'portrait': _portrait,
    'landscape': _landscape,
  });

  void _decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map || value['version'] != 1 || value['enabled'] is! bool) {
      throw const FormatException('unsupported touch record');
    }
    List<int> readGrid(Object? source) {
      if (source is! List || source.length != cellCount) {
        throw const FormatException('invalid touch grid');
      }
      return source
          .map((cell) {
            if (cell is! int || cell < 0 || cell > maxCellCount) {
              throw const FormatException('invalid touch count');
            }
            return cell;
          })
          .toList(growable: false);
    }

    final portrait = readGrid(value['portrait']);
    final landscape = readGrid(value['landscape']);
    final started = value['startedAt'];
    final date = started == null ? null : DateTime.parse(started as String);
    _portrait.setAll(0, portrait);
    _landscape.setAll(0, landscape);
    _enabled = value['enabled'] as bool;
    _startedAt = date;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _disposed = true;
    super.dispose();
  }
}
