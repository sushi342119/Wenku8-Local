import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'filename_tags.dart';
import 'recovery_archive.dart';

/// 书籍标签：标签库 + 每本书的标签归属，全部存在本机。
class Tag {
  const Tag({required this.id, required this.name, required this.colorIndex});
  final String id;
  final String name;
  final int colorIndex;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'color': colorIndex,
  };

  factory Tag.fromJson(Map<String, Object?> json) => Tag(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    colorIndex: (json['color'] as num?)?.toInt() ?? 0,
  );
}

const tagPalette = [
  Color(0xFF8A6F55),
  Color(0xFF6E8F7F),
  Color(0xFF7B8AA5),
  Color(0xFF9B7A8A),
  Color(0xFF8F8F6B),
  Color(0xFF6E9B9B),
  Color(0xFFA5845C),
  Color(0xFF7A9B6E),
];

class TagStore extends ChangeNotifier {
  static String validateTagName(String name) {
    if (!isValidFilenameTag(name)) {
      throw ArgumentError('标签名包含文件名不允许的字符或过长');
    }
    return name;
  }

  TagStore._(this._prefs);

  static TagStore? _shared;

  /// 全局单例，main() 中预加载。
  static TagStore get shared => _shared!;

  /// 可能未初始化（测试环境）；生产环境 main() 中已预加载。
  /// 调用方应在 TagStore 未就绪时降级跳过，避免崩溃。
  static TagStore? get maybeShared => _shared;

  static Future<void> load() async {
    final store = TagStore._(await SharedPreferences.getInstance());
    await store._read();
    _shared = store;
  }

  final SharedPreferences _prefs;
  final List<Tag> _tags = [];
  final Map<int, Set<String>> _bookTags = {};
  final Map<String, Tag> _tagById = {};
  final Map<String, int> _bookCountByTagId = {};

  List<Tag> get tags => List.unmodifiable(_tags);

  void _rebuildIndexes() {
    _tagById
      ..clear()
      ..addEntries(_tags.map((tag) => MapEntry(tag.id, tag)));
    _bookCountByTagId.clear();
    for (final ids in _bookTags.values) {
      for (final id in ids) {
        _bookCountByTagId[id] = (_bookCountByTagId[id] ?? 0) + 1;
      }
    }
  }

  Future<void> _read() async {
    for (final key in ['book_tags', 'book_tag_map']) {
      final raw = _prefs.get(key);
      if (raw == null) continue;
      var damaged = false;
      try {
        if (raw is! String) throw const FormatException('invalid tags');
        final decoded = jsonDecode(raw);
        if (key == 'book_tags') {
          if (decoded is! List) throw const FormatException('invalid tags');
          for (final entry in decoded) {
            try {
              final tag = Tag.fromJson(Map<String, Object?>.from(entry as Map));
              if (tag.id.isEmpty || tag.name.isEmpty ||
                  _tags.any((existing) => existing.id == tag.id)) {
                throw const FormatException('invalid tag');
              }
              _tags.add(tag);
            } catch (_) {
              damaged = true;
            }
          }
        } else {
          if (decoded is! Map) throw const FormatException('invalid tags');
          for (final entry in decoded.entries) {
            final id = int.tryParse('${entry.key}');
            final value = entry.value;
            if (id == null || id <= 0 || value is! List) {
              damaged = true;
              continue;
            }
            final ids = value.whereType<String>().toSet();
            if (ids.length != value.length) damaged = true;
            if (ids.isNotEmpty) _bookTags[id] = ids;
          }
        }
      } catch (_) {
        damaged = true;
      }
      if (damaged) {
        try {
          await archiveRecoveryRecord(_prefs, '${key}_quarantine_v1', raw,
              reason: 'invalid_tag_records');
        } catch (_) {
          // archiveRecoveryRecord 内部已 recordRecoveryFailure；此处不再抛、不再另记，
          // 保证归档失败不阻断 _read()/load()。
        }
      }
    }
    _rebuildIndexes();
  }

  Future<void> _persist() async {
    if (!await _prefs.setString(
          'book_tags',
          jsonEncode(_tags.map((t) => t.toJson()).toList()),
        ) ||
        !await _prefs.setString(
          'book_tag_map',
          jsonEncode(_bookTags.map((k, v) => MapEntry('$k', v.toList()))),
        )) {
      throw StateError('标签记录保存失败');
    }
  }

  Future<void>? _writeLock;

  Future<T> _change<T>(Future<T> Function() action) {
    Future<T> run() async {
      final oldTags = List<Tag>.of(_tags);
      final oldMap = _bookTags.map(
        (id, ids) => MapEntry(id, Set<String>.of(ids)),
      );
      try {
        final result = await action();
        _rebuildIndexes();
        return result;
      } catch (error, stack) {
        _tags
          ..clear()
          ..addAll(oldTags);
        _bookTags
          ..clear()
          ..addAll(oldMap);
        _rebuildIndexes();
        try {
          await _persist();
        } catch (_) {
          /* Original failure wins. */
        }
        Error.throwWithStackTrace(error, stack);
      }
    }

    // An idle store must start in the caller's zone. Retaining a completed
    // Future created at load time stalls widget-test callers in FakeAsync.
    final pending = _writeLock;
    final next = pending == null ? run() : pending.then((_) => run());
    final barrier = next.then<void>((_) {}, onError: (_) {});
    _writeLock = barrier;
    return next.whenComplete(() {
      if (identical(_writeLock, barrier)) _writeLock = null;
    });
  }

  Tag? tagById(String id) {
    return _tagById[id];
  }

  /// 创建标签，返回 id；同名返回既有标签。
  Future<String> createTag(String name) => _change(() async {
    final clean = validateTagName(name);
    for (final tag in _tags) {
      if (tag.name == clean) return tag.id;
    }
    // 用时间戳+随机数避免同一毫秒内创建的标签 ID 碰撞
    final random = DateTime.now().microsecondsSinceEpoch % 1000000;
    final tag = Tag(
      id: 'tag_${DateTime.now().millisecondsSinceEpoch}_$random',
      name: clean,
      colorIndex: _tags.length % tagPalette.length,
    );
    _tags.add(tag);
    await _persist();
    notifyListeners();
    return tag.id;
  });

  Future<void> renameTag(String id, String name) => _change(() async {
    final clean = validateTagName(name);
    if (_tags.any((tag) => tag.id != id && tag.name == clean)) {
      throw ArgumentError('同名标签已存在');
    }
    final index = _tags.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final old = _tags[index];
    _tags[index] = Tag(id: old.id, name: clean, colorIndex: old.colorIndex);
    await _persist();
    notifyListeners();
  });

  Future<void> deleteTag(String id) => _change(() async {
    _tags.removeWhere((t) => t.id == id);
    for (final entry in _bookTags.values) {
      entry.remove(id);
    }
    _bookTags.removeWhere((_, ids) => ids.isEmpty);
    await _persist();
    notifyListeners();
  });

  List<Tag> tagsForBook(int bookId) {
    final ids = _bookTags[bookId];
    if (ids == null) return const [];
    final names = <String>{};
    return [
      for (final id in ids) tagById(id),
    ].whereType<Tag>().where((tag) => names.add(tag.name)).toList();
  }

  Future<void> setTagsForBook(int bookId, Iterable<String> tagIds) =>
      _change(() async {
        final ids = tagIds.toSet();
        if (ids.isEmpty) {
          _bookTags.remove(bookId);
        } else {
          _bookTags[bookId] = ids;
        }
        await _persist();
        notifyListeners();
      });

  /// Creates any missing definitions and merges filename tags into a book's
  /// existing internal tags. An empty filename tag list never clears old tags.
  Future<List<String>> mergeTagNamesForBook(
    int bookId,
    Iterable<String> names,
  ) => _change(() async {
    final cleanNames = <String>[];
    for (final name in names) {
      final clean = validateTagName(name);
      if (!cleanNames.contains(clean)) cleanNames.add(clean);
    }
    if (cleanNames.isEmpty) {
      return tagsForBook(bookId).map((tag) => tag.name).toList();
    }

    final ids = <String>{...(_bookTags[bookId] ?? const <String>{})};
    var changed = false;
    for (final name in cleanNames) {
      String? id;
      for (final tag in _tags) {
        if (tag.name == name) {
          id = tag.id;
          break;
        }
      }
      if (id == null) {
        id = 'tag_${DateTime.now().microsecondsSinceEpoch}_${_tags.length}';
        _tags.add(
          Tag(id: id, name: name, colorIndex: _tags.length % tagPalette.length),
        );
        changed = true;
      }
      changed = ids.add(id) || changed;
    }
    if (!changed) return tagsForBook(bookId).map((tag) => tag.name).toList();
    _bookTags[bookId] = ids;
    await _persist();
    notifyListeners();
    return tagsForBook(bookId).map((tag) => tag.name).toList();
  });

  List<String> tagNamesForBook(int bookId) =>
      tagsForBook(bookId).map((tag) => tag.name).toList();

  int bookCountFor(String tagId) =>
      _bookCountByTagId[tagId] ?? 0;

  Iterable<int> bookIdsFor(String tagId) =>
      _bookTags.entries.where((entry) => entry.value.contains(tagId)).map((entry) => entry.key);

  /// 导出备份记录：标签定义 + 书籍归属，供 LibraryState 备份使用。
  Map<String, Object> exportTagRecords() => {
    'tag_defs': jsonEncode(_tags.map((t) => t.toJson()).toList()),
    'tag_map': jsonEncode(_bookTags.map((k, v) => MapEntry('$k', v.toList()))),
  };

  /// 从备份记录合并标签（只增不减，与书架合并语义一致）。
  /// 新装迁移时本地为空，等同于完整恢复。
  Future<void> importTagRecords(Map<String, Object> records) =>
      _change(() async {
        final defsRaw = records['tag_defs'];
        if (defsRaw is String) {
          try {
            final list = jsonDecode(defsRaw);
            if (list is List) {
              for (final entry in list.whereType<Map<String, Object?>>()) {
                try {
                final tag = Tag.fromJson(entry);
                if (tag.id.isEmpty || !isValidFilenameTag(tag.name)) continue;
                if (tag.name.length > 64) continue;
                if (_tags.any((t) => t.id == tag.id)) continue;
                _tags.add(tag);
                } catch (_) {
                  continue;
                }
              }
            }
          } catch (_) {}
        }
        final mapRaw = records['tag_map'];
        if (mapRaw is String) {
          // 只保留有对应标签定义的归属（合并后的定义集合，含本机已有标签）。
          final knownIds = _tags.map((t) => t.id).toSet();
          try {
            final map = jsonDecode(mapRaw);
            if (map is Map<String, Object?>) {
              map.forEach((key, value) {
                final bookId = int.tryParse(key);
                if (bookId == null ||
                    bookId <= 0 ||
                    bookId > 0x7fffffff ||
                    value is! List) {
                  return;
                }
                final ids = value
                    .whereType<String>()
                    .where((id) => id.isNotEmpty && knownIds.contains(id))
                    .toSet();
                if (ids.isEmpty) return;
                final existing = _bookTags[bookId];
                if (existing == null) {
                  _bookTags[bookId] = ids;
                } else {
                  existing.addAll(ids);
                }
              });
            }
          } catch (_) {}
        }
        await _persist();
        notifyListeners();
      });
}
