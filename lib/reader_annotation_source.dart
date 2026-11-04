import 'package:flutter/widgets.dart' show Locale;

import 'app_language.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'offline_repository.dart';
import 'reader_annotation_range.dart';
import 'reader_content.dart';
import 'reader_underline.dart';

/// Reads only an already-imported original, an offline body or source-owned
/// inline text. This action never calls remote find/chapters/chapterContent.
Future<ReaderAnnotationContext?> loadOfflineReaderAnnotationContext({
  required LibraryState state,
  required NovelRepository repository,
  required int novelId,
  required List<ReaderUnderlineRange> ranges,
  required ReadingPosition anchor,
  Novel? novel,
  Locale? locale,
}) async {
  final offline = repository is OfflineNovelRepository ? repository : null;
  if (offline != null) await offline.cache.load();
  final localStore = state.localLibrary;
  final localBook = localStore?.bookFor(novelId);
  novel =
      novel ??
      (localBook == null ? null : localStore!.toNovel(localBook)) ??
      offline?.cache.book(novelId)?.novel ??
      state.cachedNovel(novelId);
  if (novel == null || novel.id != novelId || novel.chapters.isEmpty) {
    return null;
  }
  if (isLocalNovelId(novelId) && localBook == null) {
    return null;
  }
  final requiredIds = ranges.isEmpty
      ? <int>{
          if (anchor.chapterId > 0)
            anchor.chapterId
          else if (anchor.chapter >= 0 &&
              anchor.chapter < novel.chapters.length)
            novel.chapters[anchor.chapter].id,
        }
      : ranges.map((range) => range.chapterId).toSet();
  if (requiredIds.isEmpty ||
      requiredIds.any((id) => !novel!.chapters.any((c) => c.id == id))) {
    return null;
  }
  final candidates = <int>{...requiredIds};
  for (final id in requiredIds) {
    final index = novel.chapters.indexWhere((c) => c.id == id);
    if (index > 0) candidates.add(novel.chapters[index - 1].id);
    if (index + 1 < novel.chapters.length) {
      candidates.add(novel.chapters[index + 1].id);
    }
  }
  final sources = <ReaderAnnotationChapterSource>[];
  for (final chapter in novel.chapters.where(
    (c) => candidates.contains(c.id),
  )) {
    String? body;
    if (localStore != null && isLocalNovelId(novelId)) {
      body = await localStore.chapterContent(novelId, chapter);
    } else if (offline != null) {
      body = await offline.cache.readChapter(novelId, chapter.id);
    } else if (chapter.content.trim().isNotEmpty) {
      body = chapter.content;
    }
    if (body == null || body.trim().isEmpty) {
      if (requiredIds.contains(chapter.id)) return null;
      continue;
    }
    final source = await (await ReaderContent.parse(
      body,
    )).localizedAsync(chineseLocale(locale));
    sources.add(
      ReaderAnnotationChapterSource(
        chapterId: chapter.id,
        title: chapter.title,
        content: source,
      ),
    );
  }
  return ReaderAnnotationContext(
    novelId: novelId,
    novel: novel,
    chapters: sources,
  );
}
