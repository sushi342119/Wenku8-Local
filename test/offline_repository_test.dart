import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';

import 'support/offline_fixture.dart';

class _FullDisk extends OfflineCacheStore {
  _FullDisk(super.directory);
  @override
  Future<bool> saveChapter(
    int id,
    int cid,
    String text, {
    required CacheEpoch epoch,
  }) async => throw const FileSystemException('fixture full disk');
}

class _DelayedChapterLookup extends OfflineCacheStore {
  _DelayedChapterLookup(super.directory);
  final lookupBlocked = Completer<void>();
  final resumeLookup = Completer<void>();
  int _reads = 0;

  @override
  Future<String?> readChapter(int id, int cid) async {
    final read = ++_reads;
    final saved = await super.readChapter(id, cid);
    if (read == 2) {
      lookupBlocked.complete();
      await resumeLookup.future;
    }
    return saved;
  }
}

void main() {
  late Directory root;
  late OfflineCacheStore cache;
  late OfflineFixtureRepository remote;
  late OfflineNovelRepository repository;
  final novel = offlineFixtureBook(71);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('novel8-offline-test-');
    cache = OfflineCacheStore(root);
    remote = OfflineFixtureRepository();
    repository = OfflineNovelRepository(remote: remote, cache: cache);
  });
  tearDown(() async {
    repository.dispose();
    cache.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'metadata, stable chapter IDs, UTF8 bodies and sizes survive restart',
    () async {
      await repository.rememberDirectory(novel);
      final expected = novel.chapters.first.content;
      expect(
        await repository.chapterContent(novel.id, novel.chapters.first),
        expected,
      );
      expect(cache.book(novel.id)!.bytes, utf8.encode(expected).length);
      final reopened = OfflineCacheStore(root);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.book(novel.id)!.cachedCount, 1);
      expect(
        (await reopened.readBook(novel.id))!.chapters.map((c) => c.id),
        novel.chapters.map((c) => c.id),
      );
      expect(
        await reopened.readChapter(novel.id, novel.chapters.first.id),
        expected,
      );
    },
  );

  test(
    'offline cached body performs no remote call and missing body stays an error',
    () async {
      await repository.rememberDirectory(novel);
      await repository.chapterContent(novel.id, novel.chapters.first);
      final before = remote.calls.length;
      remote.disconnected = true;
      expect(
        await repository.chapterContent(novel.id, novel.chapters.first),
        novel.chapters.first.content,
      );
      expect(remote.calls.length, before);
      expect(await repository.find(novel.id), isNotNull);
      expect((await repository.chapters(novel.id)).length, 3);
      expect(repository.isDirectoryOffline(novel.id), isTrue);
      await expectLater(
        repository.chapterContent(novel.id, novel.chapters[1]),
        throwsStateError,
      );
      expect(cache.book(novel.id)!.cachedCount, 1);
    },
  );

  test(
    'invalid cache identifiers are misses and preserve remote find behavior',
    () async {
      expect(await cache.readBook(0), isNull);
      expect(await cache.readBook(-1), isNull);
      expect(await cache.readChapter(0, 71001), isNull);
      expect(await cache.readChapter(71, -1), isNull);
      expect(await repository.find(0), isNull);
      remote.disconnected = true;
      await expectLater(repository.find(-1), throwsStateError);
      expect(cache.books, isEmpty);
    },
  );

  test(
    'large directory and body codecs round trip without storing inline bodies',
    () async {
      final chapters = List.generate(
        400,
        (index) =>
            NovelChapter('章节 $index ${'长标题' * 100}', '', id: 71001 + index),
      );
      final full = novel.withChapters(chapters);
      final text = '长章节内容 😀\n' * 10000;
      final epoch = cache.epochFor(71);
      expect(await cache.saveBook(full, epoch: epoch), isTrue);
      expect(await cache.saveChapter(71, 71001, text, epoch: epoch), isTrue);
      final metadata = await File('${root.path}/b71/book.json').readAsString();
      expect(metadata.length, greaterThan(64 * 1024));
      final reopened = OfflineCacheStore(root);
      addTearDown(reopened.dispose);
      await reopened.load();
      final saved = await reopened.readBook(71);
      expect(saved!.chapters.length, 400);
      expect(saved.chapters.last.title, chapters.last.title);
      expect(
        saved.chapters.every((chapter) => chapter.content.isEmpty),
        isTrue,
      );
      expect(await reopened.readChapter(71, 71001), text);
      expect(reopened.book(71)!.bytes, utf8.encode(text).length);
      expect(reopened.book(71)!.cachedCount, 1);
    },
  );

  test(
    'chapter IDs are partitioned by novel and directory insertion preserves cached ID',
    () async {
      final first = novel.withChapters([
        const NovelChapter('旧章节', '', id: 101),
      ]);
      final other = offlineFixtureBook(
        72,
      ).withChapters([const NovelChapter('另一本章节', '', id: 101)]);
      final e1 = cache.epochFor(first.id);
      final e2 = cache.epochFor(other.id);
      await cache.saveBook(first, epoch: e1);
      await cache.saveBook(other, epoch: e2);
      await cache.saveChapter(first.id, 101, '书一正文', epoch: e1);
      await cache.saveChapter(other.id, 101, '书二正文', epoch: e2);
      await cache.saveBook(
        first.withChapters([
          const NovelChapter('新增', '', id: 90),
          first.chapters.single,
        ]),
        epoch: e1,
      );
      expect(await cache.readChapter(first.id, 101), '书一正文');
      expect(await cache.readChapter(other.id, 101), '书二正文');
      expect(cache.book(first.id)!.cachedCount, 1);
    },
  );

  test(
    'broken snapshots and empty bodies are misses rather than invented content',
    () async {
      await cache.saveBook(novel, epoch: cache.epochFor(novel.id));
      await File('${root.path}/b71/book.json').writeAsString('{broken');
      expect(await cache.readBook(71), isNull);
      await File('${root.path}/b71/book.json').writeAsString(
        jsonEncode({
          'version': 1,
          'novel': novel.toSnapshot(),
          'chapters': [null],
        }),
      );
      expect(await cache.readBook(71), isNull);
      await File('${root.path}/b71/c71001.txt').writeAsString('');
      expect(await cache.readChapter(71, 71001), isNull);
      await expectLater(
        cache.saveChapter(71, 71001, ' ', epoch: cache.epochFor(71)),
        throwsFormatException,
      );
      await cache.saveBook(novel, epoch: cache.epochFor(71));
      await cache.saveChapter(71, 71001, '正确正文', epoch: cache.epochFor(71));
      expect(await cache.readChapter(71, 71001), '正确正文');
    },
  );

  test(
    'duplicate chapter IDs cannot overwrite a valid saved directory',
    () async {
      final epoch = cache.epochFor(novel.id);
      await cache.saveBook(novel, epoch: epoch);
      await expectLater(
        cache.saveBook(
          novel.withChapters([novel.chapters.first, novel.chapters.first]),
          epoch: epoch,
        ),
        throwsFormatException,
      );
      expect((await cache.readBook(novel.id))!.chapters.length, 3);
      await cache.saveChapter(
        novel.id,
        novel.chapters.first.id,
        '队列继续工作',
        epoch: epoch,
      );
      expect(
        await cache.readChapter(novel.id, novel.chapters.first.id),
        '队列继续工作',
      );
    },
  );

  test(
    'delete generations reject old metadata and body writes, then allow fresh reads',
    () async {
      final old = cache.epochFor(71);
      await cache.saveBook(novel, epoch: old);
      await cache.removeBook(71);
      expect(await cache.saveBook(novel, epoch: old), isFalse);
      expect(await cache.saveChapter(71, 71001, '旧结果', epoch: old), isFalse);
      expect(await cache.readBook(71), isNull);
      final fresh = cache.epochFor(71);
      expect(await cache.saveBook(novel, epoch: fresh), isTrue);
      expect(await cache.saveChapter(71, 71001, '新结果', epoch: fresh), isTrue);
      await cache.clear();
      expect(cache.books, isEmpty);
      expect(await cache.readChapter(71, 71001), isNull);
      expect(await cache.saveBook(novel, epoch: fresh), isFalse);
    },
  );

  test(
    'download pauses at first failure and retry skips committed chapters',
    () async {
      remote.failChapter = novel.chapters[1].id;
      repository.download(novel);
      await offlineWaitUntil(
        () => repository.jobFor(71)!.phase == DownloadPhase.failed,
      );
      expect(cache.book(71)!.cachedCount, 1);
      remote.failChapter = null;
      repository.retry(71);
      await offlineWaitUntil(
        () => repository.jobFor(71)!.phase == DownloadPhase.completed,
      );
      expect(cache.book(71)!.cachedCount, 3);
      expect(remote.calls.where((c) => c == 'text:71:71001').length, 1);
      expect(remote.maximumReads, 1);
    },
  );

  test(
    'cancel suppresses an in-flight body commit and all following requests',
    () async {
      final pending = Completer<String>();
      remote.held[71001] = pending;
      repository.download(novel);
      await offlineWaitUntil(() => remote.activeReads == 1);
      repository.cancel(71);
      pending.complete(novel.chapters.first.content);
      await offlineWaitUntil(() => remote.activeReads == 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repository.jobFor(71)!.phase, DownloadPhase.cancelled);
      expect(cache.book(71)!.cachedCount, 0);
      expect(await cache.readChapter(71, 71001), isNull);
      expect(remote.calls.where((c) => c.startsWith('text:')).length, 1);
    },
  );

  test(
    'clearing during network fetch does not resurrect a deleted book',
    () async {
      final pending = Completer<String>();
      remote.held[71001] = pending;
      await repository.rememberDirectory(novel);
      final read = repository.chapterContent(71, novel.chapters.first);
      await offlineWaitUntil(() => remote.activeReads == 1);
      await repository.clearCache();
      pending.complete(novel.chapters.first.content);
      expect(await read, novel.chapters.first.content);
      expect(await cache.readBook(71), isNull);
      expect(await cache.readChapter(71, 71001), isNull);
    },
  );

  test(
    'reader and downloader coalesce the same remote chapter request',
    () async {
      final pending = Completer<String>();
      remote.held[71001] = pending;
      await repository.rememberDirectory(novel);
      final read = repository.chapterContent(71, novel.chapters.first);
      await offlineWaitUntil(() => remote.activeReads == 1);
      repository.download(novel, chapterIds: {71001});
      await offlineWaitUntil(
        () => repository.jobFor(71)!.phase == DownloadPhase.downloading,
      );
      pending.complete(novel.chapters.first.content);
      expect(await read, novel.chapters.first.content);
      await offlineWaitUntil(
        () => repository.jobFor(71)!.phase == DownloadPhase.completed,
      );
      expect(remote.calls.where((c) => c == 'text:71:71001').length, 1);
      expect(cache.book(71)!.cachedCount, 1);
    },
  );

  test('a fresh cache generation never reuses an obsolete response', () async {
    final oldBody = Completer<String>();
    final newBody = Completer<String>();
    remote.held[71001] = oldBody;
    await repository.rememberDirectory(novel);
    final oldRead = repository.chapterContent(71, novel.chapters.first);
    await offlineWaitUntil(() => remote.activeReads == 1);
    await repository.clearCache();
    await repository.rememberDirectory(novel);
    remote.held[71001] = newBody;
    final newRead = repository.chapterContent(71, novel.chapters.first);
    await offlineWaitUntil(() => remote.activeReads == 2);
    newBody.complete('刷新后的正文');
    expect(await newRead, '刷新后的正文');
    oldBody.complete('清空前的正文');
    expect(await oldRead, '清空前的正文');
    expect(await cache.readChapter(71, 71001), '刷新后的正文');
    expect(remote.calls.where((c) => c == 'text:71:71001').length, 2);
  });

  test(
    'a cache miss already in flight shares a response through its disk commit',
    () async {
      repository.dispose();
      cache.dispose();
      final delayed = _DelayedChapterLookup(root);
      cache = delayed;
      repository = OfflineNovelRepository(remote: remote, cache: cache);
      addTearDown(() {
        if (!delayed.resumeLookup.isCompleted) delayed.resumeLookup.complete();
      });
      final pending = Completer<String>();
      remote.held[71001] = pending;
      await repository.rememberDirectory(novel);
      final read = repository.chapterContent(71, novel.chapters.first);
      await offlineWaitUntil(() => remote.activeReads == 1);
      repository.download(novel, chapterIds: {71001});
      await delayed.lookupBlocked.future;
      // The downloader already observed a cache miss, but its filesystem
      // continuation arrives only after the reader committed the response.
      pending.complete(novel.chapters.first.content);
      expect(await read, novel.chapters.first.content);
      expect(cache.book(71)!.cachedCount, 1);
      delayed.resumeLookup.complete();
      await offlineWaitUntil(
        () => repository.jobFor(71)!.phase == DownloadPhase.completed,
      );
      expect(remote.calls.where((c) => c == 'text:71:71001').length, 1);
    },
  );

  test(
    'books download serially and selected stable IDs define the requested range',
    () async {
      final second = offlineFixtureBook(72);
      remote.books[72] = second;
      final pending = Completer<String>();
      remote.held[71001] = pending;
      repository.download(novel, chapterIds: {71001});
      repository.download(second, chapterIds: {72002, 72003});
      await offlineWaitUntil(() => remote.activeReads == 1);
      expect(repository.jobFor(72)!.phase, DownloadPhase.queued);
      pending.complete(novel.chapters.first.content);
      await offlineWaitUntil(
        () => repository.jobFor(72)!.phase == DownloadPhase.completed,
      );
      expect(remote.maximumReads, 1);
      expect(cache.book(71)!.cachedCount, 1);
      expect(cache.book(72)!.cachedCount, 2);
      expect(remote.calls, isNot(contains('text:72:72001')));
    },
  );

  test(
    'a storage failure preserves online reading and fails an explicit download',
    () async {
      repository.dispose();
      cache.dispose();
      cache = _FullDisk(root);
      repository = OfflineNovelRepository(remote: remote, cache: cache);
      await repository.rememberDirectory(novel);
      expect(
        await repository.chapterContent(71, novel.chapters.first),
        novel.chapters.first.content,
      );
      expect(repository.cacheError, isA<FileSystemException>());
      repository.download(novel);
      await offlineWaitUntil(
        () => repository.jobFor(71)!.phase == DownloadPhase.failed,
      );
      expect(cache.book(71)!.cachedCount, 0);
      expect(repository.jobFor(71)!.error, isA<FileSystemException>());
    },
  );
}
