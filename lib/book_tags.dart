import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 书籍标签：标签库 + 每本书的标签归属，全部存在本机。
class Tag {
  const Tag({required this.id, required this.name, required this.colorIndex});
  final String id;
  final String name;
  final int colorIndex;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'color': colorIndex};

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
  TagStore._(this._prefs);

  static TagStore? _shared;

  /// 全局单例，main() 中预加载。
  static TagStore get shared => _shared!;

  static Future<void> load() async {
    final store = TagStore._(await SharedPreferences.getInstance());
    store._read();
    _shared = store;
  }

  final SharedPreferences _prefs;
  final List<Tag> _tags = [];
  final Map<int, Set<String>> _bookTags = {};

  List<Tag> get tags => List.unmodifiable(_tags);

  void _read() {
    try {
      final raw = _prefs.getString('book_tags');
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final entry in list.whereType<Map<String, Object?>>()) {
            final tag = Tag.fromJson(entry);
            if (tag.id.isNotEmpty && tag.name.isNotEmpty) _tags.add(tag);
          }
        }
      }
      final rawMap = _prefs.getString('book_tag_map');
      if (rawMap != null) {
        final map = jsonDecode(rawMap);
        if (map is Map<String, Object?>) {
          map.forEach((key, value) {
            final id = int.tryParse(key);
            if (id == null || value is! List) return;
            final ids = value.whereType<String>().toSet();
            if (ids.isNotEmpty) _bookTags[id] = ids;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    await _prefs.setString(
      'book_tags',
      jsonEncode(_tags.map((t) => t.toJson()).toList()),
    );
    await _prefs.setString(
      'book_tag_map',
      jsonEncode(_bookTags.map((k, v) => MapEntry('$k', v.toList()))),
    );
  }

  Tag? tagById(String id) {
    for (final tag in _tags) {
      if (tag.id == id) return tag;
    }
    return null;
  }

  /// 创建标签，返回 id；同名返回既有标签。
  Future<String> createTag(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError('标签名为空');
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
  }

  Future<void> renameTag(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final index = _tags.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final old = _tags[index];
    _tags[index] = Tag(id: old.id, name: clean, colorIndex: old.colorIndex);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteTag(String id) async {
    _tags.removeWhere((t) => t.id == id);
    for (final entry in _bookTags.values) {
      entry.remove(id);
    }
    _bookTags.removeWhere((_, ids) => ids.isEmpty);
    await _persist();
    notifyListeners();
  }

  List<Tag> tagsForBook(int bookId) {
    final ids = _bookTags[bookId];
    if (ids == null) return const [];
    return [for (final id in ids) tagById(id)].whereType<Tag>().toList();
  }

  Future<void> setTagsForBook(int bookId, Iterable<String> tagIds) async {
    final ids = tagIds.toSet();
    if (ids.isEmpty) {
      _bookTags.remove(bookId);
    } else {
      _bookTags[bookId] = ids;
    }
    await _persist();
    notifyListeners();
  }

  int bookCountFor(String tagId) =>
      _bookTags.values.where((ids) => ids.contains(tagId)).length;

  /// 导出备份记录：标签定义 + 书籍归属，供 LibraryState 备份使用。
  Map<String, Object> exportTagRecords() => {
        'tag_defs': jsonEncode(_tags.map((t) => t.toJson()).toList()),
        'tag_map': jsonEncode(
          _bookTags.map((k, v) => MapEntry('$k', v.toList())),
        ),
      };

  /// 从备份记录合并标签（只增不减，与书架合并语义一致）。
  /// 新装迁移时本地为空，等同于完整恢复。
  Future<void> importTagRecords(Map<String, Object> records) async {
    final defsRaw = records['tag_defs'];
    if (defsRaw is String) {
      try {
        final list = jsonDecode(defsRaw);
        if (list is List) {
          for (final entry in list.whereType<Map<String, Object?>>()) {
            final tag = Tag.fromJson(entry);
            if (tag.id.isEmpty || tag.name.isEmpty) continue;
            if (tag.name.length > 64) continue;
            if (_tags.any((t) => t.id == tag.id)) continue;
            _tags.add(tag);
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
                .where(
                    (id) => id.isNotEmpty && knownIds.contains(id))
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
  }
}
