import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_library.dart';

void main() {
  test('local novel ids stay in the reserved positive int32 range', () {
    expect(isLocalNovelId(localNovelIdBase), isTrue);
    expect(isLocalNovelId(localNovelIdBase + 12345), isTrue);
    expect(isLocalNovelId(0x7fffffff), isTrue);
    expect(isLocalNovelId(1239), isFalse);
    expect(isLocalNovelId(0), isFalse);
    expect(isLocalNovelId(-1), isFalse);
  });

  test('chapter splitter finds standard chapter headings', () {
    const text = '斗破苍穹\n\n第一章 陨落的天才\n\n正文第一段。\n\n第二章 斗气大陆\n\n正文第二段。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.length, 3);
    expect(chapters.first.title, '前言');
    expect(chapters[1].title, '第一章 陨落的天才');
    expect(chapters[2].title, '第二章 斗气大陆');
    final first = text.substring(
      chapters[1].offset,
      chapters[1].offset + chapters[1].length,
    );
    expect(first, contains('正文第一段'));
    expect(first, isNot(contains('第一章')));
  });

  test('chapter splitter falls back to a single chapter', () {
    const text = '没有章节标题的正文\n第二段\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.length, 1);
    expect(chapters.single.title, '正文');
  });

  test('chapter splitter keeps ambiguous long heading suffix in body', () {
    final text = '第一章 ${'很长的正文' * 20}\n\n第一章 短标题\n\n正文。\n\n第二章 另一章\n\n正文。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.map((c) => c.title), ['第一章', '第一章 短标题', '第二章 另一章']);
    expect(
      text.substring(
        chapters.first.offset,
        chapters.first.offset + chapters.first.length,
      ),
      contains('很长的正文'),
    );
  });

  test('chapter splitter accepts full-width indented headings', () {
    // 标题行以多个全角空格缩进/居中、数字为全角，是用户书库最常见的漏检格式。
    const text = '　　第一章、美艳娇妻\n\n正文。\n\n　　　　　　　　第２章 奸情\n\n正文。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.map((c) => c.title), ['第一章、美艳娇妻', '第２章 奸情']);
  });

  test('chapter splitter accepts longer chapter titles', () {
    const text =
        '第004章 太后寝宫内窃得抹胸绣鞋，稚根初试鞋穴抽送泄薄浆，出屏撞见母后含笑\n\n正文。\n\n第二章 短\n\n正文。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.length, 2);
    expect(chapters[0].title, startsWith('第004章'));
  });

  test('title and author are parsed from common file name patterns', () {
    expect(LocalLibraryStore.titleFromNameForTest('斗破苍穹 - 天蚕土豆.txt'), '斗破苍穹');
    expect(LocalLibraryStore.authorFromNameForTest('斗破苍穹 - 天蚕土豆.txt'), '天蚕土豆');
    expect(LocalLibraryStore.titleFromNameForTest('凡人修仙传.pdf'), '凡人修仙传');
    expect(LocalLibraryStore.authorFromNameForTest('凡人修仙传.pdf'), '');
  });

  test('local book json round trip keeps chapter index', () {
    const book = LocalBook(
      id: localNovelIdBase + 7,
      title: '测试',
      author: '作者',
      fileUri: 'content://doc/1',
      fileName: '测试 - 作者.txt',
      kind: LocalBookKind.txt,
      size: 1024,
      modified: 1720000000000,
      chapters: [LocalChapterIndex('第一章', 10, 100)],
      pageCount: 0,
    );
    final restored = LocalBook.fromJson(
      Map<String, Object?>.from(book.toJson()),
    );
    expect(restored.id, book.id);
    expect(restored.title, '测试');
    expect(restored.kind, LocalBookKind.txt);
    expect(restored.chapters.single.title, '第一章');
    expect(restored.chapters.single.offset, 10);
  });

  test('formatLocalSize renders human sizes', () {
    expect(formatLocalSize(512), '512 B');
    expect(formatLocalSize(2048), '2.0 KB');
    expect(formatLocalSize(5 * 1024 * 1024), '5.0 MB');
  });
}
