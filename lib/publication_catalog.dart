import 'package:xml/xml.dart';

import 'catalog.dart';

class PublicationLibrary {
  const PublicationLibrary(this.id, this.name);
  final int id;
  final String name;
  static List<PublicationLibrary> parse(String source) {
    final root = XmlDocument.parse(source).rootElement;
    if (root.name.local != 'metadata') throw const FormatException('文库分类格式有误');
    final seen = <int>{};
    final libraries = <PublicationLibrary>[];
    for (final item in root.findElements('item')) {
      final id = int.tryParse(item.getAttribute('sort') ?? '');
      final name = item.innerText.trim();
      if (id != null && id > 0 && name.isNotEmpty && seen.add(id)) {
        libraries.add(PublicationLibrary(id, name));
      }
    }
    if (libraries.isEmpty) throw const FormatException('没有读到有效文库分类');
    return List.unmodifiable(libraries);
  }
}

abstract interface class PublicationCatalog {
  Future<List<PublicationLibrary>> publicationLibraries({bool refresh = false});
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  });
}

/// A category feed still uses the normal paging/prefetch/stale-result machinery.
class PublicationNovelRepository extends NovelRepository {
  const PublicationNovelRepository(this.source, this.catalog, this.library);
  final NovelRepository source;
  final PublicationCatalog catalog;
  final PublicationLibrary library;
  @override
  Future<List<Novel>> list() async => (await browse()).items;
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => catalog.browsePublication(library.id, page: page, refresh: refresh);
  @override
  Future<Novel?> find(int id) => source.find(id);
  @override
  Future<List<Novel>> search(String query) => source.search(query);
  @override
  Future<Novel> detail(Novel novel) => source.detail(novel);
  @override
  Future<List<NovelChapter>> chapters(int id) => source.chapters(id);
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      source.chapterContent(novelId, chapter);
}
