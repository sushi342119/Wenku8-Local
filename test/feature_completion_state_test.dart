import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legacy_import.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/publication_catalog.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_find.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';

import 'support/offline_fixture.dart';

String publicationXml(int id, {String date = '2026-10-05'}) =>
    '<result><page num="3"/><item aid="$id"><data name="Title" value="作品 $id"/><data name="LastUpdate" value="$date"/></item></result>';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  group('publication catalogue', () {
    test(
      'uses server category IDs/names, deduplicates and rejects error XML',
      () {
        expect(
          PublicationLibrary.parse(
            '<metadata><item sort="8">一迅社</item><item sort="8">重复</item></metadata>',
          ).single.id,
          8,
        );
        expect(
          () => PublicationLibrary.parse('<result/>'),
          throwsFormatException,
        );
        expect(
          () => PublicationLibrary.parse('<metadata/>'),
          throwsFormatException,
        );
      },
    );
    test(
      'category browse reuses original sort key and normal cursor',
      () async {
        final calls = <String>[];
        final repository = LegacyWenkuRepository(
          request: (action) async {
            calls.add(action);
            return publicationXml(71);
          },
        );
        expect(
          (await repository.browse(sort: NovelSort.lastUpdate, page: 2)).page,
          2,
        );
        await repository.browse(sort: NovelSort.lastUpdate, page: 2);
        expect(calls, ['action=novellist&sort=lastupdate&page=2&t=0']);
        await repository.browse(sort: NovelSort.lastUpdate, refresh: true);
        expect(calls.last, 'action=novellist&sort=lastupdate&page=1&t=0');
      },
    );
    test('stale browse refresh cannot replace newer metadata', () async {
      final old = Completer<String>(), fresh = Completer<String>();
      var calls = 0;
      final repository = LegacyWenkuRepository(
        request: (action) {
          calls++;
          return calls == 1 ? old.future : fresh.future;
        },
      );
      final a = repository.browse(sort: NovelSort.lastUpdate);
      final b = repository.browse(sort: NovelSort.lastUpdate, refresh: true);
      fresh.complete(publicationXml(71, date: '2026-10-05'));
      await b;
      old.complete(publicationXml(71, date: '2010-01-01'));
      await a;
      expect((await repository.find(71))!.lastUpdate, '2026-10-05');
    });
    test(
      'failed browse request is retriable rather than cached forever',
      () async {
        var calls = 0;
        final repository = LegacyWenkuRepository(
          request: (action) async {
            calls++;
            return calls == 1 ? '<html/>' : publicationXml(71);
          },
        );
        await expectLater(
          repository.browse(sort: NovelSort.lastUpdate),
          throwsFormatException,
        );
        expect(
          (await repository.browse(sort: NovelSort.lastUpdate)).items.single.id,
          71,
        );
        expect(calls, 2);
      },
    );
  });
  group('illustrations', () {
    test(
      'original paired image markers survive text normalization and keep order',
      () async {
        final repository = LegacyWenkuRepository(
          request: (_) async =>
              '前文\r\n<!--image-->http://img.wenku8.com/a.jpg<!--image--><!--image-->https://img.wenku8.com/b.jpg<!--image-->\r\n后文',
        );
        final body = await repository.chapterContent(
          71,
          offlineFixtureBook(71).chapters.first,
        );
        final content = await ReaderContent.parse(body);
        expect(content.paragraphs.length, 4);
        expect(content.paragraphs.first, '前文');
        expect(content.illustrations, [
          'https://img.wenku8.com/a.jpg',
          'https://img.wenku8.com/b.jpg',
        ]);
      },
    );
    test(
      'image URLs are not in-chapter search hits or arbitrary remote fetches',
      () async {
        final content = await ReaderContent.parse(
          'img文字\n\n<!--image-->https://img.wenku8.com/a.jpg<!--image-->',
        );
        expect((await findInReader(content, 'img')).matches.length, 1);
        expect(
          readerIllustrationUrl(
            '<!--image-->https://example.org/a.jpg<!--image-->',
          ),
          isNull,
        );
        expect(
          readerIllustrationUrl(
            '<!--image-->https://img.wenku8.com.evil.test/a.jpg<!--image-->',
          ),
          isNull,
        );
        expect(
          readerIllustrationUrl('<!--image-->file:///tmp/a.jpg<!--image-->'),
          isNull,
        );
      },
    );
    test(
      'encoded memory cache is bounded and evicted futures fetch again',
      () async {
        final calls = <String>[];
        final cache = ReaderIllustrationCache(
          maxBytes: 8,
          request: (url) async {
            calls.add(url);
            return Uint8List(4);
          },
        );
        await cache.load('a');
        await cache.load('b');
        await cache.load('a');
        await cache.load('c');
        expect(cache.encodedBytes, 8);
        expect(cache.peek('b'), isNull);
        await cache.load('b');
        expect(calls, ['a', 'b', 'c', 'b']);
      },
    );
    test(
      'pending images deduplicate; failure and clear release requests',
      () async {
        final held = Completer<Uint8List>();
        var calls = 0;
        final cache = ReaderIllustrationCache(
          request: (_) {
            calls++;
            return held.future;
          },
        );
        final first = cache.load('a');
        final second = cache.load('a');
        expect(calls, 1);
        cache.clearMemory();
        held.complete(Uint8List(4));
        await first;
        await second;
        expect(cache.peek('a'), isNull);
        expect(cache.encodedBytes, 0);
        var attempts = 0;
        final retry = ReaderIllustrationCache(
          request: (_) async {
            if (++attempts == 1) throw StateError('offline');
            return Uint8List(4);
          },
        );
        await expectLater(retry.load('a'), throwsStateError);
        await retry.load('a');
        expect(attempts, 2);
      },
    );
  });
  group('legacy record import', () {
    Map<Object?, Object?> bundle(Map<String, String> docs) => {
      'documents': {
        for (final entry in docs.entries)
          entry.key: {'text': entry.value, 'modifiedAt': 1000},
      },
      'skippedFiles': 0,
    };
    test(
      'imports shelf, exact chapter IDs and search; drops individual damage',
      () async {
        final preview = await LegacyImportPreview.parse(
          bundle({
            'bookshelf_local.wk8': '71||72||71||broken',
            'read_saves_v1.wk8': '71:1:71002:20:3||bad',
            'search_history.wk8': '[0魔法][1作者][0魔法]',
          }),
        );
        expect(preview.backup.shelfCount, 2);
        expect(preview.backup.positionCount, 1);
        expect(preview.damagedRecords, 2);
        final position = jsonDecode(
          preview.backup.records['reading_position_71']! as String,
        );
        expect(position['chapterId'], 71002);
        expect(position['offset'], 0);
        expect(preview.backup.records['recentSearches'], ['魔法', '作者']);
      },
    );
    test(
      'vertical progress maps chapter to book using original cached volume index',
      () async {
        final preview = await LegacyImportPreview.parse(
          bundle({
            'bookshelf_local.wk8': '71',
            '71-volume.xml':
                '<metadata><volume><chapter cid="71001">一</chapter><chapter cid="71002">二</chapter></volume></metadata>',
            'read_saves.wk8': '71002,,250,,1000||991,,100,,200',
          }),
        );
        expect(preview.unmappedChapters, 1);
        final state = await LibraryState.load();
        await state.restoreBackup(preview.backup);
        expect(state.positionFor(71)!.chapter, 1);
        expect(state.positionFor(71)!.fraction, .25);
        state.dispose();
      },
    );
    test(
      'legacy merge preserves newer Flutter position and existing bookmarks',
      () async {
        final state = await LibraryState.load();
        final book = offlineFixtureBook(71);
        await state.setShelfMembership(71, true, novel: book);
        await state.savePosition(
          novel: book,
          chapter: 2,
          offset: 300,
          maximum: 1000,
          width: 400,
        );
        await state.addBookmark(novel: book, position: state.positionFor(71)!);
        final saved = state.positionFor(71);
        final preview = await LegacyImportPreview.parse(
          bundle({
            'bookshelf_local.wk8': '72',
            'read_saves_v1.wk8': '71:1:71001:2:3',
          }),
        );
        await state.restoreBackup(preview.backup);
        expect(state.positionFor(71), same(saved));
        expect(state.bookmarksFor(71).length, 1);
        expect(state.shelf, {71, 72});
        state.dispose();
      },
    );
    test(
      'account/cert data and oversized/unrecognized bundles are rejected',
      () async {
        await expectLater(
          LegacyImportPreview.parse(bundle({'cert.wk8': 'secret'})),
          throwsFormatException,
        );
        await expectLater(
          LegacyImportPreview.parse(bundle({'bookshelf_local.wk8': 'broken'})),
          throwsFormatException,
        );
        await expectLater(
          LegacyImportPreview.parse(
            bundle({'bookshelf_local.wk8': 'x' * (8 * 1024 * 1024 + 1)}),
          ),
          throwsFormatException,
        );
      },
    );
  });
}
