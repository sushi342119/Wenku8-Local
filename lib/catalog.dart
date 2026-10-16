import 'package:flutter/material.dart';

/// A source-neutral book model shared by the Android legacy API and local tests.
class Novel {
  const Novel({
    required this.id,
    required this.title,
    required this.author,
    required this.genre,
    required this.summary,
    required this.colors,
    this.chapters = const [],
    this.isComplete = false,
    this.coverUrl,
    this.lastUpdate,
    this.chapterCount = 0,
  });

  final int id;
  final String title;
  final String author;
  final String genre;
  final String summary;
  final List<Color> colors;
  final List<NovelChapter> chapters;
  final bool isComplete;
  final String? coverUrl;
  final String? lastUpdate;
  final int chapterCount;

  Novel withChapters(List<NovelChapter> items) => Novel(
    id: id,
    title: title,
    author: author,
    genre: genre,
    summary: summary,
    colors: colors,
    chapters: items,
    isComplete: isComplete,
    coverUrl: coverUrl,
    lastUpdate: lastUpdate,
    chapterCount: items.length,
  );

  Map<String, Object?> toSnapshot() => {
    'id': id,
    'title': title,
    'author': author,
    'genre': genre,
    'summary': summary,
    'colors': colors.map((color) => color.toARGB32()).toList(),
    'isComplete': isComplete,
    'coverUrl': coverUrl,
    'lastUpdate': lastUpdate,
    'chapterCount': chapters.isNotEmpty ? chapters.length : chapterCount,
  };

  factory Novel.fromSnapshot(Map<String, dynamic> value) {
    final id = value['id'];
    final title = value['title'];
    if (id is! int || id <= 0 || title is! String || title.trim().isEmpty) {
      throw const FormatException('书籍快照缺少标识或标题');
    }
    final colors = value['colors'];
    return Novel(
      id: id,
      title: title,
      author: value['author'] is String ? value['author'] : '',
      genre: value['genre'] is String ? value['genre'] : '',
      summary: value['summary'] is String ? value['summary'] : '',
      colors:
          colors is List && colors.length >= 2 && colors.every((v) => v is int)
          ? colors.map((v) => Color(v as int)).toList()
          : const [Color(0xFF202020), Color(0xFF333333)],
      isComplete: value['isComplete'] == true,
      coverUrl: value['coverUrl'] is String ? value['coverUrl'] : null,
      lastUpdate: value['lastUpdate'] is String ? value['lastUpdate'] : null,
      chapterCount: value['chapterCount'] is int
          ? (value['chapterCount'] as int).clamp(0, 100000)
          : 0,
    );
  }
}

class NovelChapter {
  const NovelChapter(this.title, this.content, {this.id = 0});

  final String title;
  final String content;
  final int id;
}

abstract class NovelRepository {
  const NovelRepository();
  Future<List<Novel>> list();
  Future<Novel?> find(int id);
  Future<List<Novel>> search(String query);
  Future<Novel> detail(Novel novel);
  Future<List<NovelChapter>> chapters(int id);
  Future<String> chapterContent(int novelId, NovelChapter chapter);

  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    final books = await list();
    final selected = sort == NovelSort.fullFlag
        ? books.where((book) => book.isComplete).toList()
        : books;
    return NovelPage.fromItems(selected, page);
  }

  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async => NovelPage.fromItems(await search(query), page);
}

enum NovelSort {
  lastUpdate('最近更新', 'lastupdate'),
  postDate('最新入库', 'postdate'),
  allVisit('总人气', 'allvisit'),
  allVote('总推荐', 'allvote'),
  monthVisit('月人气', 'monthvisit'),
  monthVote('月推荐', 'monthvote'),
  weekVisit('周人气', 'weekvisit'),
  weekVote('周推荐', 'weekvote'),
  dayVisit('日人气', 'dayvisit'),
  dayVote('日推荐', 'dayvote'),
  goodNum('收藏榜', 'goodnum'),
  size('字数榜', 'size'),
  fullFlag('完结作品', 'fullflag');

  const NovelSort(this.label, this.apiKey);
  final String label;
  final String apiKey;
}

class NovelPage {
  const NovelPage({
    required this.items,
    required this.page,
    this.totalPages,
    this.totalItems,
  });
  final List<Novel> items;
  final int page;
  final int? totalPages;
  final int? totalItems;
  bool get hasMore =>
      totalPages == null ? items.isNotEmpty : page < totalPages!;

  factory NovelPage.fromItems(
    List<Novel> items,
    int page, {
    int pageSize = 20,
  }) {
    if (page < 1) throw ArgumentError.value(page, 'page');
    return NovelPage(
      items: List.unmodifiable(
        items.skip((page - 1) * pageSize).take(pageSize),
      ),
      page: page,
      totalPages: (items.length / pageSize).ceil(),
      totalItems: items.length,
    );
  }
}

class DemoNovelRepository extends NovelRepository {
  const DemoNovelRepository();

  @override
  Future<List<Novel>> list() async => demoNovels;

  @override
  Future<Novel?> find(int id) async {
    for (final novel in demoNovels) {
      if (novel.id == id) return novel;
    }
    return null;
  }

  @override
  Future<List<Novel>> search(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return demoNovels;
    return demoNovels.where((novel) {
      return '${novel.title} ${novel.author} ${novel.genre} ${novel.summary}'
          .toLowerCase()
          .contains(needle);
    }).toList();
  }

  @override
  Future<Novel> detail(Novel novel) async => novel;

  @override
  Future<List<NovelChapter>> chapters(int id) async =>
      (await find(id))?.chapters ?? const [];

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async =>
      chapter.content;
}

const demoNovels = <Novel>[
  Novel(
    id: 1,
    title: '月光航线',
    author: '林见舟',
    genre: '都市 · 治愈',
    summary: '在城市最后一班渡轮上，两个素不相识的人交换了写给未来的信。关于失去、重新出发，以及那些未曾熄灭的微光。',
    colors: [Color(0xFF5E87B8), Color(0xFF222C5B)],
    chapters: [
      NovelChapter('第一章 · 末班渡轮', '''海面在夜色里慢慢变成深蓝。码头的灯一盏一盏亮起，像有人沿着岸线写下了一串安静的句号。

顾遥赶上末班渡轮时，船舱里只剩下靠窗的两个座位。她随手坐下，从背包里抽出一封没有收件人的信。信纸折过三次，边缘已经有些柔软。

“你也写信吗？”旁边的人问。

她抬头，看见一个抱着旧相机的年轻人。他没有等待答案，只是将相机放在膝上，望向窗外。两岸的光在水面上拉成长长的线，随着船身起伏，又悄悄断开。

顾遥把信收回包里。她想，或许有些话并不是为了寄出，而是为了让自己在某个夜晚，终于有勇气读懂。'''),
      NovelChapter('第二章 · 写给明天', '''第二天的雨来得毫无征兆。顾遥站在书店门口，看着玻璃上的水痕互相追逐。

柜台旁摆着一只木盒，盒盖上写着：写给明天。她想起昨夜渡轮上的那句话，犹豫了一会儿，还是拿起一张淡蓝色的卡片。

“如果明天仍然下雨，”她写道，“就试着为自己留一把伞。”

窗外的车灯从街角掠过，雨声没有变小，但那一刻，她忽然觉得前方的路并不那么遥远。'''),
      NovelChapter('第三章 · 微光', '''周末的渡轮比工作日热闹。孩子们挤在栏杆前，寻找水面上偶尔闪出的银色鱼影。

顾遥再一次坐到靠窗的位置。那个抱相机的人没有出现。她却不再像过去那样，觉得每一次错过都意味着故事结束。

远处的云裂开一道细缝，月光落在河面。她打开记事本，写下这段航线新的名字：微光。'''),
    ],
  ),
  Novel(
    id: 2,
    title: '玻璃海纪事',
    author: '闻溪',
    genre: '幻想 · 冒险',
    summary: '一片会记录记忆的海，一座只在退潮时出现的城市。年轻的制图师沿着潮汐，寻找消失的故乡。',
    colors: [Color(0xFF66C9BC), Color(0xFF276A8F)],
    chapters: [
      NovelChapter('第一章 · 潮汐地图', '''退潮后的沙滩上，出现了一条昨天还不存在的路。

南舟蹲下身，掏出随身的铅笔，在地图空白的边角画下第一道线。海风掀起纸张，他用掌心压住，忽然看见浅水里映出一座城的轮廓。

那轮廓不是倒影。城市的钟声从水下传来，清晰得像就在身边。'''),
      NovelChapter('第二章 · 水下的钟', '''钟声响了七次，潮水却没有回来。

南舟沿着新出现的石阶向下走。每一步都像走进别人的回忆：一扇亮着灯的窗，一把遗落在门口的伞，还有母亲年轻时哼过的曲子。

他明白，这片海保存的并非地图，而是所有人不愿忘记的事。'''),
    ],
  ),
  Novel(
    id: 3,
    title: '星尘邮局',
    author: '夏槿',
    genre: '科幻 · 日常',
    summary: '宇宙边缘的小小邮局，每周只收一封无法投递的信。一个见习邮差发现，信封上的星图正在变化。',
    colors: [Color(0xFFE6A5B7), Color(0xFF8F658E)],
    chapters: [
      NovelChapter('第一章 · 第七封信', '''邮局的门铃在清晨六点响起，桌上却没有客人，只有一只银色信封。

见习邮差阿澄核对地址。收件地是一颗已经熄灭的恒星，寄件日期却写着明天。

她把信放到窗边。阳光照上去的瞬间，信封表面的星点开始缓缓移动。'''),
      NovelChapter('第二章 · 不存在的地址', '''阿澄找来了最旧的星图。那颗恒星原本的位置，被新的航道覆盖了。

“也许地址没有错。”老邮差说，“只是寄信的人还在等我们找到正确的时间。”

窗外，一艘货船正从晨雾里驶来。'''),
    ],
    isComplete: true,
  ),
  Novel(
    id: 4,
    title: '风经过山谷',
    author: '迟野',
    genre: '青春 · 成长',
    summary: '毕业那年，四个朋友约好在山谷合开一间咖啡馆。多年后，一张泛黄的合照让他们再次启程。',
    colors: [Color(0xFFE9B277), Color(0xFFB76E6E)],
    chapters: [
      NovelChapter('第一章 · 回声', '''山谷里的风总比城里慢半拍。许栀下车时，太阳刚越过远处的松林。

旧咖啡馆的招牌还在，木门却已经上了锁。她从背包里拿出那张合照，四个人的笑容停在很多年前的夏天。

她沿着石阶走上去，听见有人在身后叫她的名字。'''),
      NovelChapter('第二章 · 再见', '''“你还是第一个到。”

许栀转身，看见周屿提着一袋刚出炉的面包，像从前无数个清晨一样。

两人谁也没有急着谈离开的这些年。他们只是推开窗，让风吹进积了灰的屋子。'''),
    ],
  ),
];
