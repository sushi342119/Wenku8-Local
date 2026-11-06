import 'package:flutter/foundation.dart';

import 'book_tags.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'ui_preferences.dart';

enum BookFormatFilter {
  txt('TXT'),
  epub('EPUB'),
  pdf('PDF');

  const BookFormatFilter(this.label);
  final String label;
}

enum SearchScope {
  all('全部'),
  titleAuthor('书名作者'),
  tags('标签');

  const SearchScope(this.label);
  final String label;
}

/// One filter shared by the shelf, the discovery carousel and random pick
/// (design §5.5). Tags are multi-select with OR (default, same as the old
/// random pick) or AND. Status stays in `LibraryState.shelfFilter`; the
/// AND/OR choice is persisted via `LibraryState.tagMatchMode`.
class LibraryFilter extends ChangeNotifier {
  LibraryFilter._();
  static final shared = LibraryFilter._();

  /// Tests share one isolate; clear selections between cases.
  @visibleForTesting
  void resetForTesting() {
    _tags.clear();
    _formats.clear();
  }

  final Set<String> _tags = {};
  final Set<BookFormatFilter> _formats = {};

  Set<String> get tagIds => Set.unmodifiable(_tags);
  Set<BookFormatFilter> get formats => Set.unmodifiable(_formats);
  bool get hasTags => _tags.isNotEmpty;
  bool get isEmpty => _tags.isEmpty && _formats.isEmpty;

  void toggleTag(String id) {
    if (!_tags.remove(id)) _tags.add(id);
    notifyListeners();
  }

  void setSingleTag(String? id) {
    _tags
      ..clear()
      ..addAll([?id]);
    notifyListeners();
  }

  void toggleFormat(BookFormatFilter format) {
    if (!_formats.remove(format)) _formats.add(format);
    notifyListeners();
  }

  Future<void> clear({LibraryState? state}) async {
    if (state != null) {
      await state.setShelfView(filter: 'all');
    }
    if (isEmpty) return;
    _tags.clear();
    _formats.clear();
    notifyListeners();
  }

  /// Drops tag ids whose definitions were deleted. Silent: it runs during
  /// build, and the deleting TagStore change already triggers the rebuild.
  void prune(TagStore store) =>
      _tags.removeWhere((id) => store.tagById(id) == null);

  bool matchesTags(int bookId, TagMatchMode mode, {TagStore? store}) {
    if (_tags.isEmpty) return true;
    final own = (store ?? TagStore.shared)
        .tagsForBook(bookId)
        .map((tag) => tag.id)
        .toSet();
    return mode == TagMatchMode.all
        ? own.containsAll(_tags)
        : own.any(_tags.contains);
  }

  bool matchesFormat(int bookId, LocalLibraryStore? local) {
    if (_formats.isEmpty) return true;
    final kind = local?.kindFor(bookId);
    final format = switch (kind) {
      LocalBookKind.epub => BookFormatFilter.epub,
      LocalBookKind.pdf => BookFormatFilter.pdf,
      // Online books are text; local TXT and unknown default to TXT.
      _ => BookFormatFilter.txt,
    };
    return _formats.contains(format);
  }
}

/// Search with a scope. Returns ranges for highlighting matched characters.
bool matchesSearch(
  Novel? book,
  int id,
  String term,
  SearchScope scope, {
  TagStore? store,
}) {
  final q = term.trim().toLowerCase();
  if (q.isEmpty) return true;
  final title = (book?.title ?? '').toLowerCase();
  final author = (book?.author ?? '').toLowerCase();
  final titleOrAuthor = title.contains(q) || author.contains(q);
  final tags = (store ?? TagStore.shared)
      .tagsForBook(id)
      .map((tag) => tag.name.toLowerCase())
      .join(' ');
  return switch (scope) {
    SearchScope.titleAuthor => titleOrAuthor,
    SearchScope.tags => tags.contains(q),
    SearchScope.all => titleOrAuthor || '$id'.contains(q) || tags.contains(q),
  };
}

/// Character ranges of [term] inside [text] (case-insensitive).
List<(int, int)> searchHighlights(String text, String term) {
  final q = term.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final lower = text.toLowerCase();
  final out = <(int, int)>[];
  var start = 0;
  while (true) {
    final i = lower.indexOf(q, start);
    if (i < 0) break;
    out.add((i, i + q.length));
    start = i + q.length;
  }
  return out;
}

/// Result of a batch tag operation; failures name the book and the reason.
@immutable
class BatchTagResult {
  const BatchTagResult(this.succeeded, this.failed);
  final List<int> succeeded;
  final List<({int id, String title, String reason})> failed;
}
