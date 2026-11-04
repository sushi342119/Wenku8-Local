import '../catalog.dart';
import '../library_state.dart';
import '../reader_listening_follow.dart';
import 'controller.dart';

/// A click-time source position, independent of the reader's saved position or
/// a local book's subsequently enriched chapter order.
class ListeningReaderTarget {
  const ListeningReaderTarget(this.novel, this.position);
  final Novel novel;
  final ReadingPosition position;
}

ListeningReaderTarget? currentListeningReaderTarget(
  ListeningController controller,
) {
  final state = controller.snapshot.value;
  final novel = state.novel, current = state.current;
  if (!state.active ||
      novel == null ||
      current == null ||
      state.chapter < 0 ||
      state.chapter >= novel.chapters.length) {
    return null;
  }
  return ListeningReaderTarget(
    novel,
    ReadingPosition(
      chapter: state.chapter,
      chapterId: novel.chapters[state.chapter].id,
      offset: 0,
      fraction: 0,
      fontSize: 19,
      width: 0,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      paragraphIndex: current.paragraph,
      textOffset: readerListeningOffset(current, controller.progress.value),
    ),
  );
}
