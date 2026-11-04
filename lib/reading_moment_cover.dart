import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import 'catalog.dart';
import 'legacy_cover.dart';
import 'reading_moments.dart';

const _directoryName = 'reading-moment-covers-v1';
const _maxSourceBytes = 16 * 1024 * 1024;
const _maxSnapshotBytes = 4 * 1024 * 1024;
const _maxWidth = 500;
const _maxHeight = 1000;
final _captures = <String, Future<String?>>{};

String _reference(int bookId, DateTime completedAt) =>
    '$_directoryName/completion-$bookId-${completedAt.millisecondsSinceEpoch}.png';

Future<Directory> _directory() async => Directory(
  '${(await getApplicationSupportDirectory()).path}/$_directoryName',
);

/// Copies the cover available at the actual completion boundary. Remote books
/// use already-cached bytes only; earning a moment never starts a cover request.
/// The returned app-support-relative reference survives sandbox relocation.
Future<String?> captureReadingMomentCover({
  required Novel book,
  required DateTime completedAt,
}) {
  final reference = _reference(book.id, completedAt);
  return _captures.putIfAbsent(reference, () async {
    try {
      return await _capture(book, reference);
    } catch (_) {
      // Only cover acquisition/storage is optional. The caller still persists
      // the completion separately, and its persistence errors must propagate.
      return null;
    } finally {
      _captures.remove(reference);
    }
  });
}

Future<String?> _capture(Novel book, String reference) async {
  final directory = await _directory();
  final file = File('${directory.parent.path}/$reference');
  final kind = await FileSystemEntity.type(file.path, followLinks: false);
  if (kind != FileSystemEntityType.notFound) {
    // An event owns its first saved pixels, even if the library changes later.
    return await _readSnapshot(file) == null ? null : reference;
  }

  final url = book.coverUrl;
  Uint8List? source;
  if (url != null && url.startsWith('file://')) {
    final coverFile = File(Uri.parse(url).toFilePath());
    if (await coverFile.exists()) {
      source = await coverFile.readAsBytes();
    }
  } else {
    source = LegacyCover.peek(book.id);
  }
  if (source == null || source.isEmpty || source.length > _maxSourceBytes) {
    return null;
  }
  final bytes = await _thumbnail(source);
  if (bytes == null || bytes.length > _maxSnapshotBytes) return null;
  await directory.create(recursive: true);
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return null;
  }

  final temporary = await directory.createTemp('.capture-');
  try {
    final pending = File('${temporary.path}/cover.png');
    await pending.writeAsBytes(bytes, flush: true);
    await pending.rename(file.path);
    return reference;
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// Reads only this event's immutable owned file. Missing historical covers are
/// not reconstructed from a current book, local source, cache or remote URL.
Future<Uint8List?> loadReadingMomentCover(
  ReadingCompletionSnapshot completion,
) async {
  try {
    final file = await _storedFile(completion);
    return file == null ? null : await _readSnapshot(file);
  } catch (_) {
    return null;
  }
}

/// Resolves a readable owned file, not its pixels. Native image decoding keeps
/// its existing failure path; repeated widget publications need no Dart decode.
Future<String?> resolveReadingMomentCoverPath(
  ReadingCompletionSnapshot completion,
) async {
  try {
    final file = await _storedFile(completion);
    if (file == null ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return null;
    }
    final stat = await file.stat();
    return stat.size > 0 && stat.size <= _maxSnapshotBytes ? file.path : null;
  } catch (_) {
    return null;
  }
}

bool isReadingMomentCoverReference(String? path) =>
    path?.startsWith('$_directoryName/') ?? false;

Future<File?> _storedFile(ReadingCompletionSnapshot completion) async {
  return _storedFileFor(
    bookId: completion.bookId,
    completedAt: completion.completedAt,
    path: completion.coverPath,
  );
}

/// Removes only this attempt's owned snapshot when its completion did not save.
/// A failed cleanup does not replace the original completion-store error.
Future<void> discardReadingMomentCover({
  required int bookId,
  required DateTime completedAt,
  required String? coverPath,
}) async {
  try {
    final file = await _storedFileFor(
      bookId: bookId,
      completedAt: completedAt,
      path: coverPath,
    );
    if (file != null &&
        await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
      await file.delete();
    }
  } catch (_) {
    // Cover cleanup is best-effort; persistence failure is handled by the caller.
  }
}

Future<File?> _storedFileFor({
  required int bookId,
  required DateTime completedAt,
  required String? path,
}) async {
  if (path == null || path.isEmpty) return null;
  final reference = _reference(bookId, completedAt);
  // Reject unrelated files before even asking the platform for its root.
  if (path != reference && !path.endsWith('/$reference')) return null;
  final directory = await _directory();
  final file = File('${directory.parent.path}/$reference');
  // Retain compatibility with a previously saved absolute owned path, but do
  // not follow arbitrary external roots or traversal aliases from imports.
  if (path != reference && path != file.path) return null;
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return null;
  }
  return file;
}

Future<Uint8List?> _readSnapshot(File file) async {
  if (await FileSystemEntity.type(file.parent.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() > _maxSnapshotBytes) {
    return null;
  }
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width > _maxWidth || descriptor.height > _maxHeight) {
        return null;
      }
      final codec = await descriptor.instantiateCodec();
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  return bytes;
}

Future<Uint8List?> _thumbnail(Uint8List source) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(source);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final scale = math.min(
        1.0,
        math.min(_maxWidth / descriptor.width, _maxHeight / descriptor.height),
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          return data?.buffer.asUint8List();
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
