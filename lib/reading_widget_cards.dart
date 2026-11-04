import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'library_state.dart';
import 'reading_widget_controller.dart';
import 'reading_widget_design.dart';
import 'reading_widget_reference.dart';
import 'reading_widget_reference_capture.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

enum ReadingWidgetAppearance { system, light, dark }

@immutable
class ReadingWidgetCardConfig {
  const ReadingWidgetCardConfig({
    required this.id,
    required this.design,
    this.skin = ReadingWidgetSkin.seasons,
    this.appearance = ReadingWidgetAppearance.system,
    this.showBookDetails = false,
    this.name,
  });
  final String id;
  final ReadingWidgetDesign design;
  final ReadingWidgetSkin skin;
  final ReadingWidgetAppearance appearance;
  final bool showBookDetails;
  final String? name;
  String get label => name ?? design.label;
  ReadingWidgetCardConfig copyWith({
    ReadingWidgetSkin? skin,
    ReadingWidgetAppearance? appearance,
    bool? showBookDetails,
  }) => ReadingWidgetCardConfig(
    id: id,
    design: design,
    name: name,
    skin: skin ?? this.skin,
    appearance: appearance ?? this.appearance,
    showBookDetails: showBookDetails ?? this.showBookDetails,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': label,
    'design': design.name,
    'skin': skin.name,
    'appearance': appearance.name,
    'showBookDetails': showBookDetails,
  };
  static ReadingWidgetCardConfig? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(value['id'])) {
      return null;
    }
    final design = ReadingWidgetDesign.fromId(value['design'] as String?);
    if (design == ReadingWidgetDesign.classic) return null;
    final skin = ReadingWidgetSkin.fromId(value['skin'] as String?);
    return ReadingWidgetCardConfig(
      id: value['id'],
      design: design,
      name: value['name'] is String ? value['name'] : null,
      skin: skin == ReadingWidgetSkin.original
          ? ReadingWidgetSkin.seasons
          : skin,
      appearance:
          ReadingWidgetAppearance.values
              .where((v) => v.name == value['appearance'])
              .firstOrNull ??
          ReadingWidgetAppearance.system,
      showBookDetails: value['showBookDetails'] == true,
    );
  }
}

/// Saved cards are independent configurations. Native widget instances bind a
/// card ID, never the editor's current selection; duplicating a card makes a new ID.
class ReadingWidgetCards extends ChangeNotifier {
  ReadingWidgetCards._(this.state);
  static final _instances = Expando<ReadingWidgetCards>();
  static ReadingWidgetCards forState(LibraryState state) =>
      _instances[state] ??= ReadingWidgetCards._(state);
  static const preferenceKey = 'reading_widget_cards_v1';
  static const designs = [
    ReadingWidgetDesign.focus,
    ReadingWidgetDesign.week,
    ReadingWidgetDesign.calendar,
    ReadingWidgetDesign.memory,
    ReadingWidgetDesign.quote,
  ];
  final LibraryState state;
  List<ReadingWidgetCardConfig> _cards = [];
  List<ReadingWidgetCardConfig> get cards => List.unmodifiable(_cards);
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  Timer? _timer;
  bool _disposed = false;
  String? error;
  final _cache = <String, ({String signature, Map<String, String> images})>{};
  Directory? _directory;
  Future<bool>? _hostReady;

  Future<void> attach() => _loading ??= _load();
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(preferenceKey);
    if (stored != null) {
      try {
        _cards = (jsonDecode(stored) as List)
            .map(ReadingWidgetCardConfig.fromJson)
            .whereType<ReadingWidgetCardConfig>()
            .toList();
      } catch (_) {}
    }
    if (_cards.isEmpty) {
      final oldSkin = ReadingWidgetSkin.fromId(
        prefs.getString('reading_widgets_skin_v1'),
      );
      _cards = [
        for (final design in designs)
          ReadingWidgetCardConfig(
            id: design.name,
            design: design,
            skin: oldSkin == ReadingWidgetSkin.original
                ? ReadingWidgetSkin.seasons
                : oldSkin,
            showBookDetails:
                prefs.getBool('reading_widgets_book_details_v1') ?? false,
          ),
      ];
      await _save();
    }
    if (_disposed) return;
    state.readingMoments.addListener(_changed);
    state.historyChanges.addListener(_changed);
    state.bookmarkChanges.addListener(_changed);
    notifyListeners();
    await publish();
  }

  Future<void> _save() async {
    await (await SharedPreferences.getInstance()).setString(
      preferenceKey,
      jsonEncode(_cards.map((card) => card.toJson()).toList()),
    );
  }

  Future<void> update(ReadingWidgetCardConfig card) async {
    await attach();
    final index = _cards.indexWhere((v) => v.id == card.id);
    if (index < 0) throw StateError('小组件已移除');
    _cards[index] = card;
    await _save();
    notifyListeners();
    await publish();
  }

  Future<ReadingWidgetCardConfig> add(ReadingWidgetDesign design) async {
    await attach();
    final count = _cards.where((c) => c.design == design).length;
    final card = ReadingWidgetCardConfig(
      id: '${design.name}_${DateTime.now().microsecondsSinceEpoch}',
      design: design,
      name: '${design.label} ${count + 1}',
    );
    _cards.add(card);
    await _save();
    notifyListeners();
    await publish();
    return card;
  }

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(publish()),
    );
  }

  List<Map<String, String>> quotes({required bool details}) => [
    for (final entry in state.bookmarkEntries)
      if (entry.bookmark.quote.trim().isNotEmpty)
        {
          'id': '${entry.novelId}:${entry.bookmark.id}',
          'text': entry.bookmark.quote.trim().characters.take(400).toString(),
          'source': details
              ? [
                  state.cachedNovel(entry.novelId)?.title ?? '',
                  entry.bookmark.chapterTitle,
                ].where((v) => v.isNotEmpty).join(' · ')
              : '',
        },
  ];

  Future<void> publish() {
    // One owner serializes native commits, so a slower old render cannot replace
    // a newer privacy/configuration update.
    final next = _writes.then((_) => _publish());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> _publish() async {
    if (_disposed || !ReadingWidgetBridge.supported) return;
    _hostReady ??= ReadingWidgetBridge.channel
        .invokeMethod<bool>('cardsSupported')
        .then((value) => value == true)
        .catchError((Object _) => false);
    if (!await _hostReady! || _disposed) return;
    final configs = List<ReadingWidgetCardConfig>.of(_cards);
    final base = ReadingWidgetController.forState(state).snapshot;
    final payload = <Map<String, Object?>>[];
    final oldFiles = <String>[];
    try {
      _directory ??= await (await getTemporaryDirectory()).createTemp(
        'reading-cards-',
      );
      for (final card in configs) {
        final value = base.styled(
          design: card.design,
          skin: card.skin,
          showBookDetails: card.showBookDetails,
        );
        final visible = value.toJson()..remove('generatedAt');
        visible['verifiedTodaySeconds'] = value.verifiedTodaySeconds == null
            ? null
            : value.verifiedTodaySeconds! ~/ 60;
        visible['verifiedTotalSeconds'] = value.verifiedTotalSeconds == null
            ? null
            : value.verifiedTotalSeconds! ~/ 60;
        visible['week'] = value.week
            .map(
              (day) => day.verifiedSeconds == null
                  ? null
                  : day.verifiedSeconds! ~/ 60,
            )
            .toList();
        visible['heatmap'] = value.heatmap.verifiedSeconds
            .map((v) => v == null ? null : v ~/ 60)
            .toList();
        final signature = card.design == ReadingWidgetDesign.quote
            ? '${card.skin.name}:${widgetDate(value.localDay)}'
            : jsonEncode(visible);
        final previous = _cache[card.id];
        Map<String, String> images;
        if (previous?.signature == signature) {
          images = previous!.images;
        } else {
          images = {};
          await warmReadingDesktopImages(value);
          for (final brightness in Brightness.values) {
            for (final size in ReadingDesktopSize.values) {
              final bytes = await renderReadingDesktopCard(
                value,
                size,
                brightness: brightness,
                paintQuote: false,
              );
              final key = '${size.name}_${brightness.name}';
              final path =
                  '${_directory!.path}/${card.id}_${DateTime.now().microsecondsSinceEpoch}_$key.png';
              await File(path).writeAsBytes(bytes);
              images[key] = path;
              if (_disposed) return;
            }
          }
          oldFiles.addAll(previous?.images.values ?? []);
          _cache[card.id] = (signature: signature, images: images);
        }
        payload.add({
          ...card.toJson(),
          'images': images,
          'localDay': widgetDate(base.localDay),
          'hasRecent':
              card.design == ReadingWidgetDesign.focus &&
              card.showBookDetails &&
              base.currentBook != null,
          'quotes': card.design == ReadingWidgetDesign.quote
              ? quotes(details: card.showBookDetails)
              : <Object>[],
        });
      }
      if (_disposed) return;
      await ReadingWidgetBridge.channel.invokeMethod<void>('publishCards', {
        'cards': payload,
      });
      for (final path in oldFiles) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      error = null;
    } catch (_) {
      error = '桌面组件暂未更新，请重试';
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    state.readingMoments.removeListener(_changed);
    state.historyChanges.removeListener(_changed);
    state.bookmarkChanges.removeListener(_changed);
    _instances[state] = null;
    unawaited(
      _writes
          .then((_) async {
            final directory = _directory;
            if (directory != null && await directory.exists()) {
              await directory.delete(recursive: true);
            }
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}
