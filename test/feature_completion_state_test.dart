import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
}
