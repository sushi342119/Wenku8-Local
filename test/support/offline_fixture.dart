import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wenku8_flutter/catalog.dart';

Novel offlineFixtureBook(int id, {int chapters = 3}) => Novel(
  id: id,
  title: '离线作品 $id',
  author: '离线作者',
  genre: '轻小说',
  summary: '用于验证离线阅读的固定接口样本。',
  colors: const [Color(0xFF202020), Color(0xFF333333)],
  lastUpdate: '2026-10-01',
  chapters: [
    for (var index = 0; index < chapters; index++)
      NovelChapter(
        '第 ${index + 1} 章',
        List.generate(
          40,
          (line) => '正文 $id-${index + 1} 段落 $line：离线保存与阅读位置验证。' * 3,
        ).join('\n\n'),
        id: id * 1000 + index + 1,
      ),
  ],
);

class OfflineFixtureRepository extends DemoNovelRepository {
  OfflineFixtureRepository({List<Novel>? books})
    : books = {
        for (final book in books ?? [offlineFixtureBook(71)]) book.id: book,
      };

  final Map<int, Novel> books;
  final List<String> calls = [];
  bool disconnected = false;
  int? failChapter;
  final Map<int, Completer<String>> held = {};
  int activeReads = 0;
  int maximumReads = 0;

  void _online() {
    if (disconnected) throw StateError('offline fixture');
  }

  @override
  Future<List<Novel>> list() async {
    _online();
    return books.values.toList();
  }

  @override
  Future<Novel?> find(int id) async {
    calls.add('find:$id');
    _online();
    return books[id];
  }

  @override
  Future<Novel> detail(Novel novel) async {
    calls.add('detail:${novel.id}');
    _online();
    return books[novel.id]!;
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    calls.add('chapters:$id');
    _online();
    return books[id]!.chapters
        .map((c) => NovelChapter(c.title, '', id: c.id))
        .toList();
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    calls.add('text:$novelId:${chapter.id}');
    activeReads++;
    maximumReads = maximumReads < activeReads ? activeReads : maximumReads;
    try {
      _online();
      if (failChapter == chapter.id) {
        throw StateError('chapter fixture failure');
      }
      final pending = held[chapter.id];
      if (pending != null) return await pending.future;
      return books[novelId]!.chapters
          .singleWhere((c) => c.id == chapter.id)
          .content;
    } finally {
      activeReads--;
    }
  }
}

Future<void> offlineWaitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('offline fixture condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
