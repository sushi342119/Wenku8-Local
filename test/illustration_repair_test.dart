import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/reader_content.dart';

import 'support/offline_fixture.dart';

const _old = '前文\n\n[插图]\n\n后文';
const _new =
    '前文\n\n<!--image-->https://pic.777743.xyz/1/1305/41759/50471.jpg<!--image-->\n\n后文';

void main() {
  test(
    'legacy and current CDN addresses survive normalization in order',
    () async {
      final repository = LegacyWenkuRepository(
        request: (_) async =>
            '前文\r\n<!--image-->http://pic.wenku8.cn/pictures/1/a.jpg<!--image-->'
            '<!--image-->https://pic.777743.xyz/1/b.jpg<!--image-->\r\n后文',
      );
      final content = await ReaderContent.parse(
        await repository.chapterContent(
          71,
          offlineFixtureBook(71).chapters.first,
        ),
      );
      expect(content.illustrations, [
        'https://pic.wenku8.cn/pictures/1/a.jpg',
        'https://pic.777743.xyz/1/b.jpg',
      ]);
      expect(content.paragraphs.length, 4);
      for (final host in [
        'pic.wenku8.cn.evil.test',
        'pic.777743.xyz.evil.test',
        'example.org',
      ]) {
        expect(
          readerIllustrationUrl('<!--image-->https://$host/a.jpg<!--image-->'),
          isNull,
        );
      }
      expect(readerHasMissingIllustrations('我在[插图]前读到这句话。'), isFalse);
    },
  );

  late Directory root;
  late OfflineCacheStore cache;
  late OfflineFixtureRepository remote;
  late OfflineNovelRepository repository;
  final novel = offlineFixtureBook(
    71,
  ).withChapters([const NovelChapter('插图', _new, id: 71001)]);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('novel8-image-repair-');
    cache = OfflineCacheStore(root);
    remote = OfflineFixtureRepository(books: [novel]);
    repository = OfflineNovelRepository(remote: remote, cache: cache);
    await repository.rememberDirectory(novel);
    await cache.saveChapter(71, 71001, _old, epoch: cache.epochFor(71));
  });
  tearDown(() async {
    repository.dispose();
    cache.dispose();
    await root.delete(recursive: true);
  });

  test('URL-less old bodies repair once and survive offline restart', () async {
    expect(await repository.chapterContent(71, novel.chapters.first), _old);
    expect(remote.calls, isEmpty);
    expect(
      await repository.repairChapterIllustrations(71, novel.chapters.first),
      _new,
    );
    expect(await cache.readChapter(71, 71001), _new);
    remote.disconnected = true;
    expect(await repository.chapterContent(71, novel.chapters.first), _new);
    expect(remote.calls.where((c) => c.startsWith('text:')).length, 1);
    expect(cache.book(71)!.cachedCount, 1);
  });

  test(
    'concurrent reads share repair and preserve image paragraph indices',
    () async {
      final held = remote.held[71001] = Completer<String>();
      final a = repository.repairChapterIllustrations(71, novel.chapters.first);
      final b = repository.repairChapterIllustrations(71, novel.chapters.first);
      await offlineWaitUntil(() => remote.activeReads == 1);
      expect(
        await repository.chapterContent(71, novel.chapters.first),
        _old,
        reason: 'Readable cached text must not wait for image repair.',
      );
      held.complete(_new);
      expect(await a, _new);
      expect(await b, _new);
      expect(remote.calls.where((c) => c.startsWith('text:')).length, 1);
      expect((await ReaderContent.parse(_new)).paragraphs[2], '后文');
    },
  );

  test(
    'offline failure keeps text and explicit retry can recover later',
    () async {
      remote.disconnected = true;
      expect(await repository.chapterContent(71, novel.chapters.first), _old);
      expect(
        await repository.repairChapterIllustrations(71, novel.chapters.first),
        isNull,
      );
      expect(
        await repository.repairChapterIllustrations(71, novel.chapters.first),
        isNull,
      );
      expect(remote.calls.where((c) => c.startsWith('text:')).length, 1);
      expect(await cache.readChapter(71, 71001), _old);
      remote.disconnected = false;
      expect(
        await repository.refreshChapterContent(71, novel.chapters.first),
        _new,
      );
      expect(await cache.readChapter(71, 71001), _new);
    },
  );

  test(
    'a response still missing image URLs cannot overwrite the good old body',
    () async {
      remote.books[71] = novel.withChapters([
        const NovelChapter('插图', '[插图]', id: 71001),
      ]);
      expect(await repository.chapterContent(71, novel.chapters.first), _old);
      expect(
        await repository.repairChapterIllustrations(71, novel.chapters.first),
        isNull,
      );
      await expectLater(
        repository.refreshChapterContent(71, novel.chapters.first),
        throwsFormatException,
      );
      expect(await cache.readChapter(71, 71001), _old);
    },
  );

  test('deleting cache during repair suppresses its late disk write', () async {
    final held = remote.held[71001] = Completer<String>();
    final reading = repository.repairChapterIllustrations(
      71,
      novel.chapters.first,
    );
    await offlineWaitUntil(() => remote.activeReads == 1);
    await repository.removeCachedBook(71);
    held.complete(_new);
    expect(await reading, _new);
    expect(await cache.readChapter(71, 71001), isNull);
  });
}
