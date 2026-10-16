import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('原版 v1.30 接口可返回最近更新 XML', (tester) async {
    const channel = MethodChannel('org.mewx.wenku8/legacy_api');
    final response = await channel.invokeMethod<String>('request', {
      'action': 'action=novellist&sort=lastupdate&page=1&t=0',
    });
    expect(response, isNotNull);
    expect(response, contains('<result'));
    expect(response, contains('<item'));
  });

  testWidgets('真实目录与章节正文可加载', (tester) async {
    final repository = LegacyWenkuRepository();
    final books = await repository.list();
    expect(books, isNotEmpty);
    const channel = MethodChannel('org.mewx.wenku8/legacy_api');
    final image = await channel.invokeMethod<Uint8List>('cover', {
      'aid': books.first.id,
    });
    expect(image, isNotNull);
    expect(image!.length, greaterThan(1000));
    expect(image[0], 0xFF);
    expect(image[1], 0xD8);
    final detail = await repository.detail(books.first);
    expect(detail.title, isNotEmpty);
    final chapters = await repository.chapters(detail.id);
    expect(chapters, isNotEmpty);
    final content = await repository.chapterContent(detail.id, chapters.first);
    expect(content, isNotEmpty);
    expect(content, isNot(contains('\n\n\n')));
  });

  testWidgets('原版书名和作者搜索接口可返回结果', (tester) async {
    final repository = LegacyWenkuRepository();
    final found = await repository.search('侦探');
    expect(found, isNotEmpty);
  });

  testWidgets('原版十三种榜单和第二页可加载', (tester) async {
    final repository = LegacyWenkuRepository();
    for (final sort in NovelSort.values) {
      final first = await repository.browse(sort: sort);
      expect(first.items, isNotEmpty, reason: sort.apiKey);
      expect(first.totalPages, greaterThan(0));
      debugPrint(
        'API_BROWSE sort=${sort.apiKey} page=1 books=${first.items.length} pages=${first.totalPages}',
      );
    }
    final second = await repository.browse(page: 2);
    expect(second.items, isNotEmpty);
    expect(second.page, 2);
    final firstIds = (await repository.browse()).items.map((b) => b.id).toSet();
    expect(second.items.any((b) => !firstIds.contains(b.id)), isTrue);
    debugPrint(
      'API_BROWSE sort=lastupdate page=2 books=${second.items.length} first_id=${second.items.first.id}',
    );
  });

  testWidgets('真实搜索续页覆盖前二十条以外的书籍', (tester) async {
    final repository = LegacyWenkuRepository();
    final first = await repository.searchPage('魔法');
    expect(first.totalItems, greaterThan(20));
    expect(first.items.length, 20);
    final second = await repository.searchPage('魔法', page: 2);
    expect(second.items, isNotEmpty);
    final firstIds = first.items.map((b) => b.id).toSet();
    expect(second.items.any((b) => firstIds.contains(b.id)), isFalse);
    debugPrint(
      'API_SEARCH query=魔法 total=${first.totalItems} first=${first.items.length} second=${second.items.length}',
    );
  });

  testWidgets('Android 实际存储可重载真实收藏元数据和阅读位置', (tester) async {
    final repository = LegacyWenkuRepository();
    final preview = (await repository.list()).first;
    final detail = await repository.detail(preview);
    final chapters = await repository.chapters(preview.id);
    expect(chapters, isNotEmpty);
    final novel = detail.withChapters(chapters);
    final prefs = await SharedPreferences.getInstance();
    final state = LibraryState(prefs);
    if (!state.contains(novel.id)) {
      await state.toggleShelf(novel.id, novel: novel);
    }
    await state.savePosition(
      novel: novel,
      chapter: 0,
      offset: 300,
      maximum: 3000,
      width: 411,
    );
    await prefs.reload();
    final restored = LibraryState(prefs);
    expect(restored.contains(novel.id), isTrue);
    expect(restored.cachedNovel(novel.id)!.title, novel.title);
    expect(restored.cachedNovel(novel.id)!.chapterCount, chapters.length);
    expect(restored.positionFor(novel.id)!.chapterId, chapters.first.id);
    expect(restored.positionFor(novel.id)!.offset, 300);
    expect(restored.positionFor(novel.id)!.fraction, .1);
    debugPrint(
      'ANDROID_PERSISTENCE aid=${novel.id} chapters=${chapters.length} cid=${chapters.first.id} offset=300',
    );
  });
}
