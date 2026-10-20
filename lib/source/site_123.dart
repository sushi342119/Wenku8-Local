/// 书源试验版（source-trial 分支）：123小说网 站点适配器。
///
/// 站点特征（2026-10-19 探查）：
/// - GBK 编码：搜索关键词需 GBK percent-encode，页面按 GBK 解码
/// - 搜索：GET {base}s.php?s={GBK编码关键词}
/// - 详情页：{base}{catId}/{bookId}/，书名在 h1，章节为 h4"章节列表"后的 a 链接
/// - 正文页：{base}{catId}/{bookId}/{chapterId}.html，标题 h1，正文为 h1 后文本块
library;

import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'gbk_codec.dart';
import 'site_adapter.dart';
import 'source_client.dart';
import 'source_config.dart';
import 'source_download.dart';
import 'source_models.dart';

class Site123Adapter implements SiteAdapter {
@override
String get siteName => '123小说网';

String _base() => SourceConfig.instance.baseUrl;

String _resolve(String url) => SourceConfig.instance.resolve(url);

bool _isSameSite(Uri uri) {
final baseHost = Uri.parse(_base()).host.toLowerCase();
final host = uri.host.toLowerCase();
return host == baseHost || host.endsWith('.$baseHost');
}

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

static final _detailPathPattern = RegExp(r'^/(\d+)/(\d+)/$');
static final _chapterPathPattern = RegExp(r'^/(\d+)/(\d+)/(\d+)\.html$');

@override
Future<SourceSearchResult> search(SourceClient client, String keyword) async {
// 关键词必须 GBK 编码，UTF-8 会返回无结果。
final encoded = gbkPercentEncode(keyword);
final pageUri = Uri.parse(_base()).resolve('s.php?s=$encoded');
return _fetchSearchPage(client, pageUri);
}

@override
Future<SourceSearchResult> searchMore(
SourceClient client,
String nextPageUrl,
) {
return _fetchSearchPage(client, Uri.parse(nextPageUrl));
}

/// 取一页搜索结果并解析（书目 + 下一页链接）。
Future<SourceSearchResult> _fetchSearchPage(
SourceClient client,
Uri pageUri,
) async {
final doc = await _fetchDocument(client, pageUri);
final results = <SourceBook>[];
final seen = <String>{};
for (final a in doc.querySelectorAll('a')) {
final rawHref = a.attributes['href']?.trim()?? '';
if (rawHref.isEmpty) continue;
// 先 resolve 再校验 path，兼容绝对 URL 与相对路径。
final resolved = pageUri.resolve(rawHref);
if (!_isSameSite(resolved)) continue;
if (!_detailPathPattern.hasMatch(resolved.path)) continue;
final title = a.text.trim();
// 先验证标题再去重：封面链接（图片、无文本）不应占用去重位。
if (title.isEmpty) continue;
final detailUrl = resolved.toString();
if (!seen.add(detailUrl)) continue;
results.add(
SourceBook(
title: title,
author: _findEntryAuthor(a),
detailUrl: detailUrl,
),
);
}
return SourceSearchResult(
books: results,
nextPageUrl: _findSearchNextPage(doc, pageUri),
);
}

/// 找搜索结果页的"下一页"链接（本站文字为「下一页」或「下页」）。
/// 校验同站，且不能指回当前页。
String? _findSearchNextPage(Document doc, Uri current) {
const nextTexts = {'下一页', '下页', '下一页>', '下页>', '下一页»', '下页»'};
for (final a in doc.querySelectorAll('a')) {
final t = a.text.trim();
if (!nextTexts.contains(t)) continue;
final href = a.attributes['href']?.trim()?? '';
if (href.isEmpty) continue;
final resolved = current.resolve(href).removeFragment();
if (!_isSameSite(resolved)) continue;
if (resolved.toString() == current.removeFragment().toString()) continue;
return resolved.toString();
}
return null;
}

/// 在条目边界内找作者：从链接向上找最近的容器，找到作者即停；
/// 遇到含多本不同书籍链接的祖先、或容器文本过大时停止，避免串书。
String _findEntryAuthor(Element link) {
Element? container = link.parent;
while (container!= null) {
final bookLinks = <String>{};
for (final a in container.querySelectorAll('a')) {
final href = a.attributes['href']?.trim()?? '';
final path = Uri.tryParse(href)?.path?? href;
if (_detailPathPattern.hasMatch(path)) bookLinks.add(path);
}
if (bookLinks.length > 1) break;
final text = container.text;
if (text.length > 2000) break;
final author = _extractAuthor(text);
if (author.isNotEmpty) return author;
container = container.parent;
}
return '';
}

/// 从文本提作者：以"字数/状态/更新"等字段或文本结束为终点，
/// 避免把后续字段吞进作者名。
static String _extractAuthor(String text) {
final m = RegExp(
r'作者[：:]\s*(\S+?)\s*(?:字数|状态|更新|连载|点击|推荐|收藏|人气|$)',
).firstMatch(text);
return m?.group(1)?.trim()?? '';
}

@override
Future<SourceBookDetail> detail(SourceClient client, SourceBook book) async {
final baseUri = Uri.parse(book.detailUrl);
final bookId = _detailPathPattern.firstMatch(baseUri.path)?.group(2)?? '';
var doc = await _fetchDocument(client, baseUri);
final title = doc.querySelector('h1')?.text.trim()?? book.title;
final bodyText = doc.body?.text?? '';
final author = _extractAuthor(bodyText).ifEmpty(book.author);
final description = _extractDescription(doc);

// 章节收集：按 DOM 文档顺序遍历，只收属于本书的章节链接，
// 遇到目录结束边界（下一个 h4 / 不属于本书的章节区）即停。
final chapters = <SourceChapter>[];
final seenUrls = <String>{};
var pageUri = baseUri;
for (var page = 0; page < 20; page++) {
_collectChapters(doc, pageUri, bookId, chapters, seenUrls);
final nextPage = _findNextCatalogPage(doc, pageUri);
if (nextPage == null) break;
pageUri = nextPage;
doc = await _fetchDocument(client, pageUri);
}
final ordered = [
for (var i = 0; i < chapters.length; i++)
SourceChapter(
title: chapters[i].title,
url: chapters[i].url,
index: i,
),
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

/// 按 DOM 文档顺序收集章节：
/// - 起点：h4"章节列表"（找不到时从 body 开始，但要求更严格的归属校验）
/// - 只收 path 匹配且 bookId 与当前书一致的链接
/// - 遇到下一个 h4（新的区块）或连续 30 个非章节链接后停止，避免串入推荐区
void _collectChapters(
Document doc,
Uri pageUri,
String bookId,
List<SourceChapter> out,
Set<String> seenUrls,
) {
Element? marker;
for (final h4 in doc.querySelectorAll('h4')) {
if (h4.text.contains('章节列表')) {
marker = h4;
break;
}
}
var passedMarker = marker == null;
var nonChapterStreak = 0;
var ended = false;

void visit(Node node) {
if (ended) return;
if (node == marker) {
passedMarker = true;
return;
}
if (node is Element) {
// 新的 h4 区块 = 目录结束。
if (passedMarker &&
node.localName == 'h4' &&
node!= marker &&
node.text.trim().isNotEmpty) {
ended = true;
return;
}
if (node.localName == 'a') {
final href = node.attributes['href']?.trim()?? '';
if (href.isNotEmpty) {
final resolved = pageUri.resolve(href);
final m = _chapterPathPattern.firstMatch(resolved.path);
if (m!= null && _isSameSite(resolved)) {
// 归属校验：章节必须属于当前书。
if (bookId.isEmpty || m.group(2) == bookId) {
nonChapterStreak = 0;
if (passedMarker) {
final url = resolved.toString();
final title = node.text.trim();
if (title.isNotEmpty && seenUrls.add(url)) {
out.add(
SourceChapter(title: title, url: url, index: out.length),
);
}
}
}
} else {
nonChapterStreak++;
// 目录后连续大量非章节链接：可能已进入推荐区，停止。
if (passedMarker && nonChapterStreak > 30) ended = true;
}
}
return;
}
}
for (final child in node.nodes) {
visit(child);
if (ended) return;
}
}

final root = doc.documentElement;
if (root!= null) visit(root);
}

/// 查找目录下一页链接（分页形如"(第1/N页)"）。
Uri? _findNextCatalogPage(Document doc, Uri current) {
final text = doc.body?.text?? '';
final m = RegExp(r'\(第(\d+)/(\d+)页\)').firstMatch(text);
if (m == null) return null;
final cur = int.tryParse(m.group(1)?? '')?? 1;
final total = int.tryParse(m.group(2)?? '')?? 1;
if (cur >= total) return null;
for (final a in doc.querySelectorAll('a')) {
final t = a.text.trim();
if (t == '下页' || t == '下一页' || t == '下页>') {
final href = a.attributes['href']?.trim();
if (href!= null && href.isNotEmpty) return current.resolve(href);
}
}
return null;
}

@override
Future<SourceChapterContent> content(
SourceClient client,
SourceChapter chapter,
) async {
final firstUri = Uri.parse(chapter.url);
final doc = await _fetchDocument(client, firstUri);
final h1 = doc.querySelector('h1');
final title = h1?.text.trim()?? chapter.title;
final paragraphs = _extractParagraphs(doc, h1);
// 章内分页：【1】【2】…，href 如 12443_2.html，需合并。
// 子页失败则整章按失败处理（可重试），不静默缺页。
final extraPages = _findChapterSubPages(doc, firstUri);
for (final sub in extraPages) {
final subDoc = await _fetchDocument(client, sub.uri);
final subH1 = subDoc.querySelector('h1');
final subParagraphs = _extractParagraphs(subDoc, subH1);
if (subParagraphs.isEmpty) throw const SourceEmptyContent();
paragraphs.addAll(subParagraphs);
}
if (paragraphs.isEmpty) throw const SourceEmptyContent();
return SourceChapterContent(
chapter: chapter,
title: title,
paragraphs: paragraphs,
);
}

/// 查找章内分页面链接（文本形如【2】【3】，href 如 12443_2.html）。
/// 按整数页码排序；去 fragment 后去重；校验本站且非当前页。
List<_ChapterSubPage> _findChapterSubPages(Document doc, Uri current) {
final candidates = <_ChapterSubPage>[];
final seen = <String>{};
final pagePattern = RegExp(r'^【(\d+)】$');
// 子页 URL 规律：当前页 /书名号.html → 子页 /书名号_N.html
final currentPath = current.path;
final subUrlPattern = RegExp(
  '^' +
      RegExp.escape(currentPath.replaceAll(RegExp(r'\.html$'), '')) +
      r'_(\d+)\.html$',
);
final currentNoFrag = current.removeFragment().toString();
for (final a in doc.querySelectorAll('a')) {
final href = a.attributes['href']?.trim();
if (href == null || href.isEmpty) continue;
final resolved = current.resolve(href);
if (!_isSameSite(resolved)) continue;
final key = resolved.removeFragment().toString();
if (key == currentNoFrag) continue;
int? num;
final t = a.text.trim();
final m = pagePattern.firstMatch(t);
if (m != null) {
  num = int.tryParse(m.group(1) ?? '');
} else {
  // 文字不是【N】时，按 URL 规律兜底识别（如"下一页"链接指向 _2.html）
  final um = subUrlPattern.firstMatch(resolved.path);
  if (um != null) num = int.tryParse(um.group(1) ?? '');
}
if (num == null || num <= 1) continue; // 第 1 页是当前页
if (seen.add(key)) candidates.add(_ChapterSubPage(num, resolved));
}
// 按整数页码排序（字符串排序会把 10 排在 2 前面）。
candidates.sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
return candidates.take(20).toList();
}

/// 提取正文段落：h1 之后的连续文本块，按空行分段，过滤噪音行。
List<String> _extractParagraphs(Document doc, Element? h1) {
final body = doc.body;
if (body == null) return [];
Element? container = h1?.parent;
while (container!= null && container!= body) {
if (container.text.trim().length > 200) break;
container = container.parent;
}
container??= body;
final raw = _textAfter(container, h1);
final noise = RegExp(
r'^(上一章|下一章|目录|加入书签|推荐本书|章节目录|<上一章|下一章>|'
r'|第\d+页|\(第\d+/\d+页\))$',
);
final paragraphs = <String>[];
for (final line in raw.split(RegExp(r'\n'))) {
final t = line.trim();
if (t.length < 2) continue;
if (noise.hasMatch(t)) continue;
if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(t) && t.length < 30) continue;
paragraphs.add(t);
}
return paragraphs;
}

/// 取容器内 h1 之后的所有文本（保持 <br> 换行，跳过 script/style 等）。
String _textAfter(Element container, Element? h1) {
final buf = StringBuffer();
var passedH1 = h1 == null;

void visit(Node node) {
if (node == h1) {
passedH1 = true;
return;
}
if (!passedH1) {
for (final child in node.nodes) {
visit(child);
if (passedH1) break;
}
return;
}
if (node is Text) {
buf.write(node.text);
} else if (node is Element) {
switch (node.localName) {
case 'br':
buf.write('\n');
case 'p':
case 'div':
buf.write('\n');
for (final child in node.nodes) {
visit(child);
}
buf.write('\n');
case 'script':
case 'style':
case 'nav':
case 'footer':
case 'header':
return;
default:
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

extension _IfEmpty on String {
String ifEmpty(String fallback) => isEmpty? fallback: this;
}

/// 章内子页：页码 + URI。
class _ChapterSubPage {
final int pageNumber;
final Uri uri;
_ChapterSubPage(this.pageNumber, this.uri);
}
