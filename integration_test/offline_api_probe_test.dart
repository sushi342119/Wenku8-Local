import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';

class _Disconnected extends DemoNovelRepository {
  int bodyCalls = 0;
  @override
  Future<Novel?> find(int id) async =>
      throw StateError('network disabled for reread');
  @override
  Future<Novel> detail(Novel novel) async =>
      throw StateError('network disabled for reread');
  @override
  Future<List<NovelChapter>> chapters(int id) async =>
      throw StateError('network disabled for reread');
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    bodyCalls++;
    throw StateError('network disabled for reread');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real legacy chapter persists and rereads with remote access disabled',
    (tester) async {
      final cache = await OfflineCacheStore.forApp();
      await cache.clear();
      final online = OfflineNovelRepository(
        remote: LegacyWenkuRepository(),
        cache: cache,
      );
      final preview = (await online.browse()).items.first;
      final meta = await online.detail(preview);
      final chapters = await online.chapters(meta.id);
      expect(chapters, isNotEmpty);
      final original = await online.chapterContent(meta.id, chapters.first);
      expect(original.trim(), isNotEmpty);
      expect(cache.book(meta.id)!.cachedCount, 1);
      online.dispose();
      cache.dispose();

      final reopened = await OfflineCacheStore.forApp();
      await reopened.load();
      final disconnected = _Disconnected();
      final offline = OfflineNovelRepository(
        remote: disconnected,
        cache: reopened,
      );
      final restored = await offline.find(meta.id);
      expect(restored, isNotNull);
      final directory = await offline.chapters(meta.id);
      expect(directory.map((c) => c.id), chapters.map((c) => c.id));
      expect(await offline.chapterContent(meta.id, directory.first), original);
      expect(disconnected.bodyCalls, 0);
      debugPrint(
        'OFFLINE_REAL_API ${jsonEncode({'aid': meta.id, 'cid': chapters.first.id, 'directory_chapters': chapters.length, 'cached_chapters': 1, 'utf8_bytes': utf8.encode(original).length, 'reread_equal': true, 'remote_body_calls_on_reread': disconnected.bodyCalls})}',
      );
      await offline.clearCache();
      offline.dispose();
      reopened.dispose();
    },
  );
}
