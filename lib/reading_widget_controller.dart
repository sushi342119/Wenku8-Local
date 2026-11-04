import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'legacy_cover.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'reading_moment_cover.dart';
import 'reading_moments.dart';
import 'reading_visual_theme.dart';
import 'reading_widget_design.dart';
import 'reading_widget_snapshot.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_reference_capture.dart';

ReadingWidgetSnapshot readingWidgetSnapshot(
  LibraryState state, {
  DateTime? now,
  ReadingCompletionSnapshot? completion,
}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final source = state.readingMoments;
  final last = completion ?? source.latestCompletion;
  final heatmapStart = widgetHeatmapStart(today);
  ReadingWidgetCurrentBook? currentBook;
  if (state.readingHistoryIds.firstOrNull case final id?) {
    final book = state.localLibrary?.novelFor(id) ?? state.cachedNovel(id);
    final position = state.positionFor(id);
    final index = book == null || position == null
        ? null
        : state.chapterForPosition(book, position);
    currentBook = ReadingWidgetCurrentBook(
      title: book?.title ?? '上次阅读',
      chapter: index == null ? '' : book!.chapters[index].title,
    );
  }
  return ReadingWidgetSnapshot(
    currentBook: currentBook,
    generatedAt: current,
    localDay: today,
    verifiedTotalSeconds: source.trackedSince == null
        ? null
        : source.verifiedTotalSeconds,
    verifiedTodaySeconds: source.verifiedSecondsOn(today),
    qualifiedStreakDays: source.trackedSince == null
        ? null
        : source.qualifiedStreakDaysAt(current),
    week: [
      for (var i = 6; i >= 0; i--)
        ReadingWidgetDay(
          date: DateTime(today.year, today.month, today.day - i),
          verifiedSeconds: source.verifiedSecondsOn(
            DateTime(today.year, today.month, today.day - i),
          ),
        ),
    ],
    heatmap: ReadingWidgetHeatmap(
      localDay: today,
      verifiedSeconds: [
        for (var index = 0; index < ReadingWidgetHeatmap.dayCount; index++)
          if (DateTime(
            heatmapStart.year,
            heatmapStart.month,
            heatmapStart.day + index,
          ).isAfter(today))
            null
          else
            source.verifiedSecondsOn(
              DateTime(
                heatmapStart.year,
                heatmapStart.month,
                heatmapStart.day + index,
              ),
            ),
      ],
    ),
    latestCompletion: last == null
        ? null
        : ReadingWidgetCompletion(
            completedAt: last.completedAt,
            finished: last.finished,
            bookId: last.bookId,
            title: last.title,
            author: last.author,
            coverPath: last.coverPath,
          ),
  );
}

abstract final class ReadingWidgetBridge {
  static const channel = MethodChannel('org.mewx.wenku8/reading_widgets');
  static bool get supported =>
      LocalPlatform.android || LocalPlatform.ios || LocalPlatform.harmony;

  static Future<void> start(ValueChanged<String> onOpen) async {
    if (!supported) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openReadingSurface') {
        final destination = call.arguments as String?;
        if (destination == 'statistics' ||
            destination == 'moments' ||
            destination == 'continue' ||
            destination == 'excerpts' ||
            RegExp(r'^configure:[0-9]{1,32}$').hasMatch(destination ?? '')) {
          onOpen(destination!);
        }
      }
    });
    try {
      final destination = await channel.invokeMethod<String>(
        'consumeOpenRequest',
      );
      if (destination == 'statistics' ||
          destination == 'moments' ||
          destination == 'continue' ||
          destination == 'excerpts' ||
          RegExp(r'^configure:[0-9]{1,32}$').hasMatch(destination ?? '')) {
        onOpen(destination!);
      }
    } on MissingPluginException {
      // Desktop/test hosts do not install a home-screen widget extension.
    }
  }

  static void stop() => channel.setMethodCallHandler(null);
  static Future<void> publish(
    ReadingWidgetSnapshot snapshot, {
    Map<String, String>? desktopImages,
  }) async {
    if (!supported) return;
    await channel.invokeMethod<void>('publishSnapshot', {
      'json': jsonEncode({
        ...snapshot.toJson(),
        'desktopImages': ?desktopImages,
      }),
    });
  }
}

/// Owns widget presentation settings and publication, never reading eligibility.
class ReadingWidgetController extends ChangeNotifier {
  ReadingWidgetController._(this.state);
  static final _instances = Expando<ReadingWidgetController>();
  static ReadingWidgetController forState(LibraryState state) =>
      _instances[state] ??= ReadingWidgetController._(state);
  static const _paletteKey = 'reading_widgets_palette_v1';
  static const _themeKey = 'reading_widgets_theme_v1';
  static const _detailsKey = 'reading_widgets_book_details_v1';
  static const _designKey = 'reading_widgets_layout_v1';
  static const _skinKey = 'reading_widgets_skin_v1';
  static const _goalKey = 'reading_daily_goal_minutes_v1';
  final LibraryState state;
  ReadingVisualTheme theme = ReadingVisualTheme.archive;
  ReadingWidgetDesign design = ReadingWidgetDesign.classic;
  ReadingWidgetSkin skin = ReadingWidgetSkin.original;
  int dailyGoalMinutes = 0;
  bool showBookDetails = false;
  String? error;
  bool _attached = false, _disposed = false;
  Timer? _debounce;
  Future<void>? _loading;
  int _ticket = 0;
  String? _lastVisualSignature;
  bool? _lastPublishedDetails;
  (int?, DateTime, String?)? _preparedCoverFor;
  String? _preparedCoverPath;
  ReadingWidgetSnapshot get snapshot => readingWidgetSnapshot(state).styled(
    theme: theme,
    design: design,
    skin: skin,
    dailyGoalMinutes: dailyGoalMinutes,
    showBookDetails: showBookDetails,
  );

  Future<void> attach() => _loading ??= _attach();
  Future<void> _attach() async {
    final preferences = await SharedPreferences.getInstance();
    if (_disposed) return;
    theme = ReadingVisualTheme.fromId(
      preferences.getString(_themeKey) ?? preferences.getString(_paletteKey),
    );
    showBookDetails = preferences.getBool(_detailsKey) ?? false;
    design = ReadingWidgetDesign.fromId(preferences.getString(_designKey));
    skin = ReadingWidgetSkin.fromId(preferences.getString(_skinKey));
    dailyGoalMinutes = readingDailyGoal(preferences.getInt(_goalKey));
    _attached = true;
    state.readingMoments.addListener(_changed);
    state.historyChanges.addListener(_changed);
    notifyListeners();
    await publish();
  }

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(publish(force: false));
    });
  }

  Future<void> configure({
    ReadingWidgetPalette? palette,
    ReadingVisualTheme? theme,
    ReadingWidgetDesign? design,
    ReadingWidgetSkin? skin,
    int? dailyGoalMinutes,
    bool? showBookDetails,
  }) async {
    await attach();
    if (_disposed) return;
    this.theme =
        theme ??
        (palette == null
            ? this.theme
            : ReadingVisualTheme.fromId(palette.name));
    this.showBookDetails = showBookDetails ?? this.showBookDetails;
    this.design = design ?? this.design;
    this.skin = skin ?? this.skin;
    this.dailyGoalMinutes = readingDailyGoal(
      dailyGoalMinutes ?? this.dailyGoalMinutes,
    );
    ++_ticket;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeKey, this.theme.id);
    await preferences.setString(
      _paletteKey,
      this.theme.isDark ? 'night' : 'cream',
    );
    await preferences.setBool(_detailsKey, this.showBookDetails);
    await preferences.setString(_designKey, this.design.name);
    await preferences.setString(_skinKey, this.skin.name);
    await preferences.setInt(_goalKey, this.dailyGoalMinutes);
    await publish();
  }

  Future<void> publish({bool force = true}) async {
    if (!_attached || _disposed) return;
    _debounce?.cancel();
    var value = snapshot;
    final signature = _visualSignature(value);
    if (!force && signature == _lastVisualSignature) return;
    final completion = value.latestCompletion;
    final needsCover =
        value.design == ReadingWidgetDesign.classic ||
        value.design == ReadingWidgetDesign.memory &&
            value.skin == ReadingWidgetSkin.original;
    final coverKey = completion == null
        ? null
        : (completion.bookId, completion.completedAt, completion.coverPath);
    if (!needsCover && completion != null) {
      value = value.styled(
        theme: value.theme,
        showBookDetails: value.showBookDetails,
        completion: completion.withCover(null),
      );
    } else if (value.showBookDetails &&
        completion != null &&
        coverKey == _preparedCoverFor &&
        _preparedCoverPath != null) {
      // Reuse only this event's prepared cover. Repeated reading updates then
      // need one host write/refresh instead of clearing and restoring the image.
      value = value.styled(
        theme: value.theme,
        showBookDetails: true,
        completion: completion.withCover(_preparedCoverPath),
      );
    } else if (completion != null &&
        isReadingMomentCoverReference(completion.coverPath)) {
      // Stored locators are portable, not native file paths. Publish the totals
      // first, then add only the resolved absolute owned file below.
      value = value.styled(
        theme: value.theme,
        showBookDetails: value.showBookDetails,
        completion: completion.withCover(null),
      );
    }
    final ticket = ++_ticket;
    final referenceFace =
        ReadingWidgetBridge.supported &&
        value.design != ReadingWidgetDesign.classic &&
        value.skin != ReadingWidgetSkin.original;
    try {
      // Reading totals reach the host immediately, including on backgrounding;
      // preparing an optional cover must not delay the measured snapshot.
      if (!referenceFace ||
          !value.showBookDetails && _lastPublishedDetails != false) {
        await ReadingWidgetBridge.publish(value);
        _lastPublishedDetails = value.showBookDetails;
      }
      if (_disposed || ticket != _ticket) return;
      if (needsCover && value.showBookDetails && completion != null) {
        final path = await cachedReadingWidgetCover(state, completion);
        if (_disposed || ticket != _ticket) return;
        _preparedCoverFor = coverKey;
        _preparedCoverPath = path;
        if (path != value.latestCompletion!.coverPath) {
          value = value.styled(
            theme: value.theme,
            showBookDetails: true,
            completion: completion.withCover(path),
          );
          if (!referenceFace) await ReadingWidgetBridge.publish(value);
        }
      }
      if (_disposed || ticket != _ticket) return;
      if (referenceFace) {
        final images = await renderReadingDesktopCards(value);
        if (_disposed || ticket != _ticket) return;
        final folder = await (await getTemporaryDirectory()).createTemp(
          'reading-desktop-',
        );
        try {
          final paths = <String, String>{};
          for (final entry in images.entries) {
            final file = File('${folder.path}/${entry.key}.png');
            await file.writeAsBytes(entry.value, flush: true);
            paths[entry.key] = file.path;
          }
          if (_disposed || ticket != _ticket) return;
          await ReadingWidgetBridge.publish(value, desktopImages: paths);
        } finally {
          await folder.delete(recursive: true);
        }
      }
      if (_disposed || ticket != _ticket) return;
      _lastVisualSignature = signature;
      _lastPublishedDetails = value.showBookDetails;
      if (error != null) {
        error = null;
        notifyListeners();
      }
    } on PlatformException catch (failure) {
      if (_disposed || ticket != _ticket) return;
      error = failure.code == 'WIDGET_GROUP_UNAVAILABLE'
          ? '桌面组件共享空间尚未启用，请使用已启用共享空间的安装版本'
          : '桌面组件暂未更新，打开此页后可重试';
      notifyListeners();
    } on MissingPluginException {
      if (_disposed || ticket != _ticket) return;
      error = '当前安装版本未提供桌面组件';
      notifyListeners();
    } catch (failure, stack) {
      assert(() {
        debugPrintStack(
          label: 'Reading widget render failed: $failure',
          stackTrace: stack,
        );
        return true;
      }());
      if (_disposed || ticket != _ticket) return;
      _lastVisualSignature = null;
      error = '小组件图片暂未更新，请重试';
      notifyListeners();
    }
  }

  String _visualSignature(ReadingWidgetSnapshot value) {
    Object? minuteBucket(int? seconds) => seconds == null
        ? null
        : seconds == 0
        ? 0
        : seconds < 60
        ? '<1'
        : seconds ~/ 60;
    final json = value.toJson()..remove('generatedAt');
    json['verifiedTotalSeconds'] = minuteBucket(value.verifiedTotalSeconds);
    json['verifiedTodaySeconds'] = minuteBucket(value.verifiedTodaySeconds);
    json['week'] = [
      for (final day in value.week)
        {
          'date': widgetDate(day.date),
          'minutes': minuteBucket(day.verifiedSeconds),
        },
    ];
    // Only the fixed intensity changes native dots; raw seconds would undo the
    // existing visible-minute publication deduplication on every reader tick.
    json['heatmap'] = {
      'startDate': widgetDate(value.heatmap.startDate),
      'levels': value.heatmap.verifiedSeconds
          .map(readingWidgetHeatLevel)
          .toList(),
    };
    return jsonEncode(json);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_ticket;
    _debounce?.cancel();
    if (_attached) state.readingMoments.removeListener(_changed);
    if (_attached) state.historyChanges.removeListener(_changed);
    _instances[state] = null;
    super.dispose();
  }
}

/// At most one small local copy per book; extensions never fetch cover URLs.
Future<String?> cachedReadingWidgetCover(
  LibraryState state,
  ReadingWidgetCompletion completion,
) async {
  if (isReadingMomentCoverReference(completion.coverPath)) {
    final original = state.readingMoments.moments
        .map((event) => event.completion)
        .whereType<ReadingCompletionSnapshot>()
        .where(
          (event) =>
              event.bookId == completion.bookId &&
              event.completedAt == completion.completedAt &&
              event.coverPath == completion.coverPath,
        )
        .firstOrNull;
    // A missing snapshot remains missing; do not substitute today's cover.
    return original == null ? null : resolveReadingMomentCoverPath(original);
  }
  if (completion.coverPath case final String path when path.isNotEmpty) {
    if (await File(path).exists()) return path;
  }
  final id = completion.bookId;
  if (id == null) return null;
  final url =
      state.localLibrary?.novelFor(id)?.coverUrl ??
      state.cachedNovel(id)?.coverUrl;
  if (url == null) return null;
  try {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/reading-widget-covers-v1',
    );
    final target = File('${directory.path}/$id.png');
    if (await target.exists()) return target.path;
    final Uint8List bytes = url.startsWith('file://')
        ? await File(Uri.parse(url).toFilePath()).readAsBytes()
        : await LegacyCover.bytes(id, url: url);
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 360);
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) return null;
        await directory.create(recursive: true);
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
        return target.path;
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    // A missing cover leaves the typographic book treatment intact.
    return null;
  }
}
