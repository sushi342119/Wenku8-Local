import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/chapter_splitter.dart';

void main() {
  String body(String text, LocalChapterIndex c) =>
      text.substring(c.offset, c.offset + c.length);
  test(
    'format families, decorations and arbitrary indentation keep UTF16 offsets',
    () {
      final families = <List<String>>[
        ['（01）晨钟', '（02）夜雨'],
        ['1.暗室', '2.明灯'],
        ['九章：画', '十章：梦'],
        ['01 标题', '02 标题'],
        ['一、起点', '二、终点'],
        ['百花盛放 第01章', '百花盛放 第02章'],
        ['正文 第002章', '【正文】第三章'],
        ['【书名】（13）', '【书名】（14）'],
        ['Chapter IV', 'CHAPTER V'],
        ['chapter １', 'CHAPTER ２'],
        ['第一節', '第兩話'],
        ['第壹章', '第贰章'],
        ['第一折', '第二折'],
        ['序幕', '后日谈'],
        ['外篇：早春', '外传：暮夏'],
        ['上篇', '下篇（END）'],
        ['【美母的信念】（1-128）第零章', '【美母的信念】（1-128）第一章'],
      ];
      for (final headings in families) {
        final text =
            '${' ' * 120}\uFEFF\u00a0#🍎 ${headings[0]}\n这是第一段独立正文，完整保留😀。\n\n'
            '${'　' * 70}${headings[1]}\n这是第二段独立正文，完整保留。\n';
        final chapters = splitLocalChapters(text);
        expect(chapters.length, 2, reason: headings.toString());
        expect(body(text, chapters.first), contains('第一段独立正文'));
        expect(body(text, chapters.last), contains('第二段独立正文'));
        expect(validChapterRanges(chapters, text.length), isTrue);
      }
    },
  );
  test('long titles, forum suffix and glued prose take distinct body ranges', () {
    final longTitle = '第一章 ${'标题' * 24}';
    const glued = '第30章：包装才女马车带着烟尘，向南而去我怔了一会儿，忽然一道动听悦耳的声音从我背后传来。';
    final text =
        '$longTitle\n正文甲。\n$glued\n正文乙。\n第31章 [bbs]viewthread.php?tid=10904118&page=1#pid107855814[/bbs]\n正文丙。';
    final chapters = splitLocalChapters(text);
    expect(chapters.first.title, longTitle);
    expect(chapters[1].title, '第30章');
    expect(body(text, chapters[1]), startsWith('：包装才女马车'));
    expect(body(text, chapters[1]), contains('从我背后传来。'));
    expect(chapters.last.title, '第31章');
    expect(body(text, chapters.last), '正文丙。');
  });
  test(
    'TOC entries and empty volumes do not open chapters; volume is metadata',
    () {
      const text =
          '目录\n第一卷\n第一章 起点\n第二章 终点\n\n第一卷\n第一章 起点\n真实正文一。\n第二章 终点\n真实正文二。\n【第一卷完】\n';
      final chapters = splitLocalChapters(text);
      expect(chapters.map((c) => c.title), ['前言', '第一章 起点', '第二章 终点']);
      expect(chapters[1].volume, '第一卷');
      expect(chapters[2].volume, '第一卷');
      expect(chapters.every((c) => body(text, c).trim().isNotEmpty), isTrue);
    },
  );
  test('whole-word prose and inline lists never create chapters', () {
    final text =
        '第一章 早晨\n${['第一回来此，手忙脚乱难免有些差池。', '第三回合的比赛前认真准备。', '第一节课是数学课', '第一部分内容继续', '尾声渐渐消失。', '三部AV里出现了长长的正文。', '一、甲', '二、乙', '三、丙'].join('\n')}\n第二章 夜晚\n结束。';
    final chapters = splitLocalChapters(text);
    expect(chapters.map((c) => c.title), ['第一章 早晨', '第二章 夜晚']);
  });
  test('unheaded opening and single heading both remain readable', () {
    final opening = '开场😀\n' * 60000;
    final text = '$opening第一章 唯一\n末尾正文';
    final chapters = splitLocalChapters(text);
    expect(chapters.map((c) => c.title), ['前言', '第一章 唯一']);
    expect(body(text, chapters.first), opening);
  });
  test(
    'streaming chunk boundaries never change headings or surrogate coordinates',
    () {
      final text = normalizeLocalText(
        '\uFEFF开场😀\r\n${'　' * 5000}第一章 首\u2028正文\u2029第二章 尾\r末尾',
      );
      final expected = splitLocalChapters(text).map((c) => c.toJson()).toList();
      for (final size in [1, 2, 3, 7, 1024, 65536]) {
        final index = ChapterTextIndex();
        for (var i = 0; i < text.length; i += size) {
          index.add(text.substring(i, (i + size).clamp(0, text.length)));
        }
        expect(
          index.finish().map((c) => c.toJson()),
          expected,
          reason: 'chunk $size',
        );
      }
    },
  );
}
