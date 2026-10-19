/// 书源试验版（source-trial 分支）：123小说网 站点适配器。
///
/// 站点特征（2026-10-19 探查）：
/// - GBK 编码：搜索关键词需 GBK percent-encode，页面按 GBK 解码
/// - 搜索：GET {base}s.php?s={GBK编码关键词}
/// - 详情页：{base}{catId}/{bookId}/，书名在 h1，章节为裸 a 列表
/// - 正文页：{base}{catId}/{bookId}/{chapterId}.html，标题 h1，正文为 h1 后文本块
library;

import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'gbk_codec.dart';
import 'site_adapter.dart';
import 'source_client.dart';
import 'source_config.dart';
import 'source_models.dart';

class Site123Adapter implements SiteAdapter {
@override
String get siteName => '123小说网';

String _base() => SourceConfig.instance.baseUrl;

String _resolve(String url) => SourceConfig.instance.resolve(url);

/// 拉取页面；命中挑战时抛 [SiteNeedVerify]（由上层打开 WebView）。
Future<Document> _fetchDocument(SourceClient client, Uri uri) async {
final page = await client.get(uri);
if (page.challenged) throw const SiteNeedVerify();
if (page.statusCode!= 200) {
throw HttpException('请求失败（${page.statusCode}）');
}
final doc = html_parser.parse(page.html);
final title = doc.querySelector('title')?.text?? '';
if (title.toLowerCase().contains('just a moment')) {
throw const SiteNeedVerify();
}
return doc;
}

@override
Future<List<SourceBook>> search(SourceClient client, String keyword) async {
// 关键词必须 GBK 编码，UTF-8 会返回无结果。
final encoded = gbkPercentEncode(keyword);
final uri = Uri.parse('${_base()}s.php?s=$encoded');
final doc = await _fetchDocument(client, uri);
final results = <SourceBook>[];
final seen = <String>{};
// 书籍详情链接格式：/58/58494/
final detailPattern = RegExp(r'^/\d+/\d+/$');
for (final a in doc.querySelectorAll('a')) {
final href = a.attributes['href']?.trim()?? '';
if (!detailPattern.hasMatch(href)) continue;
if (!seen.add(href)) continue;
final title = a.text.trim();
if (title.isEmpty) continue;
// 作者在条目容器的文本节点中："作者：XXX 字数：NNNNN"
var author = '';
var node = a.parent;
for (var depth = 0; depth < 3 && node!= null; depth++) {
final text = node.text;
final m = RegExp(r'作者：([^\s<]+)').firstMatch(text);
if (m!= null) {
author = m.group(1)!.trim();
break;
}
node = node.parent;
}
results.add(
SourceBook(
title: title,
author: author,
detailUrl: _resolve(href),
),
);
}
return results;
}

@override
Future<SourceBookDetail> detail(SourceClient client, SourceBook book) async {
final baseUri = Uri.parse(book.detailUrl);
final firstDoc = await _fetchDocument(client, baseUri);
final title =
firstDoc.querySelector('h1')?.text.trim()?? book.title;
// 作者/字数在 h1 之后的文本节点："作者：xxx""字数：xxx"
var author = book.author;
final bodyText = firstDoc.body?.text?? '';
final authorMatch = RegExp(r'作者：([^\s<]+)').firstMatch(bodyText);
if (authorMatch!= null) author = authorMatch.group(1)!.trim();
// 简介：取页面中较长的纯文本段落（排除导航）。
final description = _extractDescription(firstDoc);

// 章节列表：h4"XXX章节列表"之后的裸 a 列表；可能分页。
final chapters = <SourceChapter>[];
final seenUrls = <String>{};
var doc = firstDoc;
var pageUri = baseUri;
for (var page = 0; page < 20; page++) {
_collectChapters(doc, chapters, seenUrls);
final nextPage = _findNextCatalogPage(doc, pageUri);
if (nextPage == null) break;
pageUri = nextPage;
doc = await _fetchDocument(client, pageUri);
}
// 按 URL 去重后保持页面顺序；序号按最终顺序重排。
final unique = <SourceChapter>[];
final seen = <String>{};
for (final c in chapters) {
if (seen.add(c.url)) unique.add(c);
}
final ordered = [
for (var i = 0; i < unique.length; i++)
SourceChapter(title: unique[i].title, url: unique[i].url, index: i),
];
return SourceBookDetail(
book: SourceBook(
title: title,
author: author,
detailUrl: book.detailUrl,
description: description,
),
chapters: ordered,
);
}

/// 从详情页提取简介：找较长的文本段落。
String? _extractDescription(Document doc) {
String? best;
for (final el in doc.querySelectorAll('p, div')) {
final text = el.text.trim();
// 简介通常 50~2000 字，且不含大量链接。
if (text.length > 80 &&
text.length < 3000 &&
el.querySelectorAll('a').length <= 2 &&
!text.contains('章节列表') &&
!text.contains('最新章节')) {
if (best == null || text.length > best.length) best = text;
}
}
return best;
}

/// 收集一页目录中的章节链接（href 形如 /58/58494/12443.html）。
void _collectChapters(
Document doc,
List<SourceChapter> out,
Set<String> seenUrls,
) {
final chapterPattern = RegExp(r'^/\d+/\d+/\d+\.html$');
// 定位"章节列表"h4，从其之后收集；找不到 h4 时全页收集。
Element? start;
for (final h4 in doc.querySelectorAll('h4')) {
if (h4.text.contains('章节列表')) {
start = h4;
break;
}
}
final scope = start?.parent?? doc.body;
if (scope == null) return;
final anchors = scope.querySelectorAll('a');
// 如果从 h4 父容器收集，要跳过 h4 之前的链接。
var passedStart = start == null;
for (final a in anchors) {
if (!passedStart) {
if (a == start || _isDescendantOf(a, start)) continue;
// 简单策略：h4 出现后的链接才算。
passedStart = _appearsAfter(a, start);
if (!passedStart) continue;
}
final href = a.attributes['href']?.trim()?? '';
if (!chapterPattern.hasMatch(href)) continue;
final url = _resolve(href);
if (!seenUrls.add(url)) continue;
final title = a.text.trim();
if (title.isEmpty) continue;
out.add(SourceChapter(title: title, url: url, index: out.length));
}
}

bool _isDescendantOf(Element el, Element ancestor) {
var p = el.parent;
while (p!= null) {
if (p == ancestor) return true;
p = p.parent;
}
return false;
}

/// 粗略判断 a 是否在 h4 之后（文档顺序）。
bool _appearsAfter(Element a, Element h4) {
// 用 source code 位置比较：html 包的 Element 没有位置信息，
// 改用遍历文档顺序实现。
var foundH4 = false;
var foundA = false;
void visit(Node node) {
if (foundA) return;
if (node == h4) foundH4 = true;
if (node == a) {
foundA = true;
return;
}
for (final child in node.nodes) {
visit(child);
if (foundA) return;
}
}
final root = h4.ownerDocument?.documentElement;
if (root!= null) visit(root);
return foundH4 && foundA;
}

/// 查找目录下一页链接（分页形如"(第1/N页)"）。
Uri? _findNextCatalogPage(Document doc, Uri current) {
final text = doc.body?.text?? '';
final m = RegExp(r'\(第(\d+)/(\d+)页\)').firstMatch(text);
if (m == null) return null;
final cur = int.tryParse(m.group(1)?? '')?? 1;
final total = int.tryParse(m.group(2)?? '')?? 1;
if (cur >= total) return null;
// 找"下页"/"下一页"链接。
for (final a in doc.querySelectorAll('a')) {
final t = a.text.trim();
if (t == '下页' || t == '下一页' || t == '下页>') {
final href = a.attributes['href']?.trim();
if (href!= null && href.isNotEmpty) {
return current.resolve(href);
}
}
}
return null;
}

@override
Future<SourceChapterContent> content(
SourceClient client,
SourceChapter chapter,
) async {
final doc = await _fetchDocument(client, Uri.parse(chapter.url));
final h1 = doc.querySelector('h1');
final title = h1?.text.trim()?? chapter.title;
final paragraphs = _extractParagraphs(doc, h1);
if (paragraphs.isEmpty) throw const SourceEmptyContent();
return SourceChapterContent(
chapter: chapter,
title: title,
paragraphs: paragraphs,
);
}

/// 提取正文段落：h1 之后的连续文本块，按空行分段。
/// 站点正文为纯文本（段首全角空格缩进），容器标签不固定，
/// 因此按"h1 之后、页脚之前"的文本流提取。
List<String> _extractParagraphs(Document doc, Element? h1) {
final body = doc.body;
if (body == null) return [];
// 策略：找到 h1 的父容器，取 h1 之后所有文本，按空行切分。
Element? container = h1?.parent;
// 向上找包含足够文本的块级容器。
while (container!= null && container!= body) {
if (container.text.trim().length > 200) break;
container = container.parent;
}
container??= body;
final raw = _textAfter(container, h1);
final lines = raw
.split(RegExp(r'\n'))
.map((l) => l.trim())
.where((l) => l.isNotEmpty)
.toList();
// 过滤导航/广告噪音行。
final noise = RegExp(
r'^(上一章|下一章|目录|加入书签|推荐本书|章节目录|<上一章|下一章>|'
r'|第\d+页|\(第\d+/\d+页\)|.*最新章节.*)$',
);
final paragraphs = <String>[];
for (final line in lines) {
if (line.length < 2) continue;
if (noise.hasMatch(line)) continue;
// 跳过纯日期/统计行。
if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(line) && line.length < 30) {
continue;
}
paragraphs.add(line);
}
return paragraphs;
}

/// 取容器内 h1 之后的所有文本（保持 <br> 换行）。
String _textAfter(Element container, Element? h1) {
final buf = StringBuffer();
var passedH1 = h1 == null;
void visit(Node node) {
if (node == h1) {
passedH1 = true;
return;
}
if (!passedH1) {
// 仍要遍历子节点以找到 h1。
for (final child in node.nodes) {
visit(child);
if (passedH1) break;
}
return;
}
if (node is Text) {
buf.write(node.text);
} else if (node is Element) {
if (node.localName == 'br') {
buf.write('\n');
} else if (node.localName == 'p' || node.localName == 'div') {
buf.write('\n');
for (final child in node.nodes) {
visit(child);
}
buf.write('\n');
} else if (node.localName == 'script' ||
node.localName == 'style' ||
node.localName == 'nav' ||
node.localName == 'footer' ||
node.localName == 'header') {
return;
} else {
for (final child in node.nodes) {
visit(child);
}
}
}
}
for (final child in container.nodes) {
visit(child);
}
return buf.toString();
}
}
