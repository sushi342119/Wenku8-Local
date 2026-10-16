import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';

import 'catalog.dart';
import 'legacy_transport.dart';
import 'reader_content.dart' show readerIllustrationUrl;

typedef LegacyRequest = Future<String> Function(String action);

List<NovelChapter> _decodeChapters(String source) {
  final document = XmlDocument.parse(source);
  if (document.rootElement.name.local == 'error') {
    throw const FormatException('目录接口返回错误');
  }
  final ids = <int>{};
  return List.unmodifiable([
    for (final element in document.findAllElements('chapter'))
      if (int.tryParse(element.getAttribute('cid') ?? '') case final int id)
        if (id > 0 && ids.add(id))
          NovelChapter(element.innerText.trim(), '', id: id),
  ]);
}

List<int> _decodeSearchIds(String source) {
  final document = XmlDocument.parse(source);
  if (document.rootElement.name.local != 'result') {
    throw const FormatException('搜索接口返回了非列表内容');
  }
  return [
    for (final item in document.findAllElements('item'))
      if (int.tryParse(item.getAttribute('aid') ?? '') case final int id)
        if (id > 0) id,
  ];
}

String _normalizeBody(String source) => source
    .replaceAllMapped(RegExp(r'<!--image-->(.*?)<!--image-->', dotAll: true), (
      match,
    ) {
      final url = readerIllustrationUrl(
        '<!--image-->${match[1]!.trim()}<!--image-->',
      );
      return '\n\n${url == null ? '[插图]' : '<!--image-->$url<!--image-->'}\n\n';
    })
    .replaceAll(RegExp(r'\r\n?'), '\n')
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('\n\n');

/// Android v1.30 protocol adapter. The bridge keeps the original POST envelope;
/// this class only maps its existing XML responses into Flutter view models.
class LegacyWenkuRepository extends NovelRepository {
  LegacyWenkuRepository({LegacyRequest? request})
    : _request = request ?? LegacyTransport.request;

  final LegacyRequest _request;
  final Map<(NovelSort, int), NovelPage> _pages = {};
  final Map<NovelSort, int> _listVersions = {};
  final Map<(NovelSort, int, int), Future<NovelPage>> _pageRequests = {};
  final Map<String, List<int>> _searchIds = {};
  final Map<String, int> _searchVersions = {};
  final Map<(String, int), Future<List<int>>> _searchRequests = {};
  final Map<int, Novel> _meta = {};
  final Map<int, Future<Novel?>> _metaRequests = {};
  final Map<int, List<NovelChapter>> _indexes = {};
  final Map<int, int> _indexVersions = {};
  final Map<(int, int), Future<List<NovelChapter>>> _indexRequests = {};
  final Map<int, Future<Novel>> _detailRequests = {};

  @override
  Future<List<Novel>> list() async => (await browse()).items;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (refresh && page == 1) {
      _listVersions[sort] = (_listVersions[sort] ?? 0) + 1;
      _pages.removeWhere((key, _) => key.$1 == sort);
    } else if (refresh) {
      _pages.remove((sort, page));
    }
    final cached = _pages[(sort, page)];
    if (cached != null) return cached;
    final version = _listVersions[sort] ?? 0;
    final key = (sort, page, version);
    final pending = _pageRequests[key];
    if (pending != null) return pending;
    final request = _loadPage(sort, page, version);
    _pageRequests[key] = request;
    try {
      return await request;
    } finally {
      _pageRequests.remove(key);
    }
  }

  Future<NovelPage> _loadPage(NovelSort sort, int page, int version) async {
    final source = await _request(
      'action=novellist&sort=${sort.apiKey}&page=$page&t=0',
    );
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.local != 'result') {
      throw const FormatException('书目接口返回了非列表内容');
    }
    final novels = <Novel>[];
    for (final item in document.findAllElements('item')) {
      final id = int.tryParse(item.getAttribute('aid') ?? '');
      if (id == null || id <= 0) continue;
      final values = _fields(item);
      final novel = _makeNovel(id, values);
      novels.add(novel);
      if ((_listVersions[sort] ?? 0) == version) {
        final previous = _meta[id];
        if (previous?.lastUpdate != novel.lastUpdate) {
          _indexes.remove(id);
          _indexVersions[id] = (_indexVersions[id] ?? 0) + 1;
        }
        _meta[id] = novel;
      }
    }
    final pageElements = document.findAllElements('page');
    final total = pageElements.isEmpty
        ? null
        : int.tryParse(pageElements.first.getAttribute('num') ?? '');
    if (pageElements.isNotEmpty && (total == null || total < 0)) {
      throw const FormatException('书目接口页数无效');
    }
    if (novels.isEmpty && total == null) {
      throw const FormatException('书目列表缺少书籍或页数');
    }
    final result = NovelPage(
      items: List.unmodifiable(novels),
      page: page,
      totalPages: total,
    );
    if ((_listVersions[sort] ?? 0) == version) _pages[(sort, page)] = result;
    return result;
  }

  @override
  Future<Novel?> find(int id) async {
    if (_meta.containsKey(id)) return _meta[id];
    if (id <= 0) return null;
    final pending = _metaRequests[id];
    if (pending != null) return pending;
    final request = _loadMeta(id);
    _metaRequests[id] = request;
    try {
      return await request;
    } finally {
      _metaRequests.remove(id);
    }
  }

  Future<Novel?> _loadMeta(int id) async {
    final source = await _request('action=book&do=meta&aid=$id&t=0');
    final document = XmlDocument.parse(source);
    final values = _fields(document.rootElement);
    if ((values['Title'] ?? '').isEmpty) return null;
    final novel = _makeNovel(id, values);
    _meta[id] = novel;
    return novel;
  }

  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    final term = query.trim();
    if (term.isEmpty) return browse(page: page, refresh: refresh);
    if (refresh && page == 1) {
      _searchIds.remove(term);
      _searchVersions[term] = (_searchVersions[term] ?? 0) + 1;
    }
    final version = _searchVersions[term] ?? 0;
    final ids = _searchIds[term] ?? await _matchingIds(term, version);
    final matches = ids.skip((page - 1) * 20).take(20).toList();
    final found = <Novel>[];
    for (var start = 0; start < matches.length; start += 4) {
      final batch = matches.skip(start).take(4);
      final novels = await Future.wait(batch.map(find));
      found.addAll(novels.whereType<Novel>());
    }
    return NovelPage(
      items: List.unmodifiable(found),
      page: page,
      totalItems: ids.length,
      totalPages: (ids.length / 20).ceil(),
    );
  }

  Future<List<int>> _matchingIds(String term, int version) async {
    final key = (term, version);
    final pending = _searchRequests[key];
    if (pending != null) return pending;
    final request = _loadMatchingIds(term, version);
    _searchRequests[key] = request;
    try {
      return await request;
    } finally {
      _searchRequests.remove(key);
    }
  }

  Future<List<int>> _loadMatchingIds(String term, int version) async {
    final encoded = Uri.encodeQueryComponent(term);
    final responses = await Future.wait([
      _request('action=search&searchtype=articlename&searchkey=$encoded&t=0'),
      _request('action=search&searchtype=author&searchkey=$encoded&t=0'),
    ]);
    final ids = <int>{};
    for (final response in responses) {
      ids.addAll(
        response.length > 64 * 1024
            ? await compute(_decodeSearchIds, response)
            : _decodeSearchIds(response),
      );
    }
    final result = List<int>.unmodifiable(ids);
    if ((_searchVersions[term] ?? 0) == version) _searchIds[term] = result;
    return result;
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final pending = _detailRequests[novel.id];
    if (pending != null) return pending;
    // Opening a book is also the directory refresh boundary. Saved books must
    // discover newly published chapters without depending on the current list.
    _indexes.remove(novel.id);
    _indexVersions[novel.id] = (_indexVersions[novel.id] ?? 0) + 1;
    final request = _loadDetail(novel);
    _detailRequests[novel.id] = request;
    try {
      return await request;
    } finally {
      _detailRequests.remove(novel.id);
    }
  }

  Future<Novel> _loadDetail(Novel novel) async {
    final meta = await find(novel.id) ?? novel;
    try {
      final source = await _request('action=book&do=intro&aid=${novel.id}&t=0');
      String intro;
      try {
        intro = XmlDocument.parse(source).rootElement.innerText.trim();
      } on XmlException {
        intro = source.trim();
      }
      if (intro.isEmpty) return meta;
      return Novel(
        id: meta.id,
        title: meta.title,
        author: meta.author,
        genre: meta.genre,
        summary: intro,
        colors: meta.colors,
        isComplete: meta.isComplete,
        coverUrl: meta.coverUrl,
        lastUpdate: meta.lastUpdate,
        chapterCount: meta.chapterCount,
      );
    } catch (_) {
      return meta;
    }
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    if (_indexes.containsKey(id)) return _indexes[id]!;
    final version = _indexVersions[id] ?? 0;
    final key = (id, version);
    final pending = _indexRequests[key];
    if (pending != null) return pending;
    final request = _loadChapters(id, version);
    _indexRequests[key] = request;
    try {
      return await request;
    } finally {
      _indexRequests.remove(key);
    }
  }

  Future<List<NovelChapter>> _loadChapters(int id, int version) async {
    final source = await _request('action=book&do=list&aid=$id&t=0');
    final result = source.length > 64 * 1024
        ? await compute(_decodeChapters, source)
        : _decodeChapters(source);
    if ((_indexVersions[id] ?? 0) == version) _indexes[id] = result;
    return result;
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (chapter.id == 0) return chapter.content;
    final source = await _request(
      'action=book&do=text&aid=$novelId&cid=${chapter.id}&t=0',
    );
    return source.length > 64 * 1024
        ? compute(_normalizeBody, source)
        : _normalizeBody(source);
  }

  static Map<String, String> _fields(XmlElement element) {
    final result = <String, String>{};
    for (final data in element.findAllElements('data')) {
      final name = data.getAttribute('name');
      if (name == null) continue;
      result[name] = (data.getAttribute('value') ?? data.innerText).trim();
    }
    return result;
  }

  static Novel _makeNovel(int id, Map<String, String> values) {
    const palettes = <List<Color>>[
      [Color(0xFF5E87B8), Color(0xFF222C5B)],
      [Color(0xFF66C9BC), Color(0xFF276A8F)],
      [Color(0xFFE6A5B7), Color(0xFF8F658E)],
      [Color(0xFFE9B277), Color(0xFFB76E6E)],
    ];
    final status = values['BookStatus'] ?? '';
    final intro = (values['IntroPreview'] ?? '').replaceAll(
      RegExp(r'[\s\u3000]+'),
      ' ',
    );
    return Novel(
      id: id,
      title: values['Title']?.isNotEmpty == true ? values['Title']! : '书籍 $id',
      author: values['Author'] ?? '佚名',
      genre: values['Tags']?.isNotEmpty == true ? values['Tags']! : '轻小说',
      summary: intro.isEmpty ? '点击查看作品介绍与目录。' : intro,
      colors: palettes[id % palettes.length],
      isComplete:
          status == '1' ||
          (!status.contains('未') &&
              !status.contains('连载') &&
              (status.contains('完结') || status.contains('已完成'))),
      coverUrl: 'https://img.wenku8.com/image/${id ~/ 1000}/$id/${id}s.jpg',
      lastUpdate: values['LastUpdate'],
    );
  }
}
