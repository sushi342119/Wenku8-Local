import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'library_backup.dart';
import 'library_state.dart';

class LegacyImportPreview {
  const LegacyImportPreview(
    this.backup, {
    required this.damagedRecords,
    required this.unmappedChapters,
    required this.skippedFiles,
  });
  final LibraryBackup backup;
  final int damagedRecords, unmappedChapters, skippedFiles;
  static Future<LegacyImportPreview> parse(Map<Object?, Object?> bundle) =>
      compute(_parseLegacyImport, bundle);
}

Future<LegacyImportPreview> _parseLegacyImport(
  Map<Object?, Object?> bundle,
) async {
  final documents = bundle['documents'];
  if (documents is! Map || documents.length > 10000) {
    throw const FormatException('旧版目录中没有有效记录');
  }
  final normalized = <String, ({String text, int modified})>{};
  var bytes = 0;
  for (final entry in documents.entries) {
    if (entry.key is! String || entry.value is! Map) {
      throw const FormatException('旧版记录格式有误');
    }
    final name = entry.key as String;
    if (!{
          'bookshelf_local.wk8',
          'read_saves.wk8',
          'read_saves_v1.wk8',
          'search_history.wk8',
        }.contains(name) &&
        !RegExp(r'^[1-9][0-9]{0,9}-volume\.xml$').hasMatch(name)) {
      throw const FormatException('旧版导入只接受书架、进度、搜索及目录记录');
    }
    final value = entry.value as Map;
    final text = value['text'];
    if (text is! String) throw const FormatException('旧版记录内容格式有误');
    bytes += utf8.encode(text).length;
    if (bytes > 8 * 1024 * 1024) throw const FormatException('旧版记录超过 8 MiB');
    final modified = value['modifiedAt'];
    normalized[name] = (
      text: text,
      modified:
          modified is int &&
              modified >= 0 &&
              modified <= DateTime.now().millisecondsSinceEpoch
          ? modified
          : 0,
    );
  }
  var damaged = 0;
  final shelf = <int>{};
  final text = normalized['bookshelf_local.wk8']?.text ?? '';
  for (final token in text.split('||')) {
    if (token.trim().isEmpty) continue;
    final id = int.tryParse(token.trim());
    if (id != null && id > 0 && id <= 0x7fffffff) {
      shelf.add(id);
    } else {
      damaged++;
    }
  }
  final chapters = <int, ({int book, int index})>{};
  for (final entry in normalized.entries.where(
    (entry) => entry.key.endsWith('-volume.xml'),
  )) {
    final book = int.tryParse(entry.key.split('-').first);
    if (book == null || book > 0x7fffffff) {
      damaged++;
      continue;
    }
    try {
      final root = XmlDocument.parse(entry.value.text).rootElement;
      if (root.name.local != 'metadata') throw const FormatException();
      var index = 0;
      for (final chapter in root.findAllElements('chapter')) {
        final cid = int.tryParse(chapter.getAttribute('cid') ?? '');
        if (cid != null && cid > 0) {
          chapters[cid] = (book: book, index: index);
          index++;
        }
      }
    } catch (_) {
      damaged++;
    }
  }
  final positions = <int, ReadingPosition>{};
  ReadingPosition position(int cid, int chapter, double fraction, int time) =>
      ReadingPosition(
        chapter: chapter,
        chapterId: cid,
        offset: 0,
        fraction: fraction,
        fontSize: 19,
        width: 0,
        updatedAt: time,
      );
  final paged = normalized['read_saves_v1.wk8'];
  if (paged != null) {
    for (final record in paged.text.split('||')) {
      if (record.trim().isEmpty) continue;
      final values = record.split(':').map(int.tryParse).toList();
      if (values.length != 5 ||
          values.any((v) => v == null || v < 0 || v > 0x7fffffff) ||
          values[0] == 0 ||
          values[2] == 0) {
        damaged++;
        continue;
      }
      final aid = values[0]!, cid = values[2]!;
      // The old wrapped line/word geometry is not a Flutter paragraph coordinate.
      // Recover the exact chapter, never invent a text offset.
      positions[aid] = position(
        cid,
        chapters[cid]?.index ?? 0,
        0,
        paged.modified,
      );
    }
  }
  var unmapped = 0;
  final vertical = normalized['read_saves.wk8'];
  if (vertical != null) {
    for (final record in vertical.text.split('||')) {
      if (record.trim().isEmpty) continue;
      final values = record.split(',,').map(int.tryParse).toList();
      if (values.length != 3 ||
          values.any((v) => v == null || v < 0 || v > 0x7fffffff) ||
          values[0] == 0 ||
          values[2] == 0) {
        damaged++;
        continue;
      }
      final match = chapters[values[0]];
      if (match == null) {
        unmapped++;
        continue;
      }
      final old = positions[match.book];
      if (old == null || old.updatedAt < vertical.modified) {
        positions[match.book] = position(
          values[0]!,
          match.index,
          (values[1]! / values[2]!).clamp(0, 1),
          vertical.modified,
        );
      }
    }
  }
  final searches = <String>[];
  final seen = <String>{};
  for (final match in RegExp(
    r'\[([^\[\]]+)\]',
  ).allMatches(normalized['search_history.wk8']?.text ?? '')) {
    var query = match[1]!.trim();
    if (query.startsWith('0') || query.startsWith('1')) {
      query = query.substring(1).trim();
    }
    if (LibraryState.validSearchHistory(query) &&
        seen.add(query.toLowerCase())) {
      searches.add(query);
    }
  }
  if (shelf.isEmpty && positions.isEmpty && searches.isEmpty && damaged > 0) {
    throw const FormatException('旧版文件中没有可恢复的记录');
  }
  final backup = await LibraryBackup.fromRecords({
    'shelf': shelf.map((id) => '$id').toList(),
    'recentSearches': searches.take(12).toList(),
    for (final entry in positions.entries)
      'chapter_${entry.key}': entry.value.chapter,
    for (final entry in positions.entries)
      'reading_position_${entry.key}': jsonEncode(entry.value.toJson()),
  });
  return LegacyImportPreview(
    backup,
    damagedRecords: damaged,
    unmappedChapters: unmapped,
    skippedFiles: bundle['skippedFiles'] is int
        ? (bundle['skippedFiles'] as int).clamp(0, 10000)
        : 0,
  );
}
