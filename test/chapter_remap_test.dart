import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_library.dart';

void main() {
  test('chapter remap task json round trip keeps id and failure info', () {
    final task = LocalChapterRemap.create(
      bookId: 201,
      oldChapters: const [(offset: 0, length: 100)],
      newChapters: const [
        (offset: 0, length: 80),
        (offset: 80, length: 20),
      ],
    );
    final same = LocalChapterRemap.create(
      bookId: 201,
      oldChapters: const [(offset: 0, length: 100)],
      newChapters: const [
        (offset: 0, length: 80),
        (offset: 80, length: 20),
      ],
    );
    expect(same.migrationId, task.migrationId);
    final restored =
        LocalChapterRemap.fromJson(task.toJson() as Object);
    expect(restored.migrationId, task.migrationId);
    expect(restored.bookId, 201);
    expect(restored.oldChapters.single.length, 100);
    expect(restored.newChapters.length, 2);
    final failed = task.withFailure(StateError('boom'));
    expect(failed.status, 'failed');
    expect(failed.attempts, 1);
    expect(failed.lastError, contains('boom'));
    expect(failed.migrationId, task.migrationId);
  });

  test('chapter-only merged chapter keeps remapped fraction in an anchor',
      () async {
    SharedPreferences.setMockInitialValues({'chapter_102': 1});
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      102,
      oldChapters: const [
        (offset: 0, length: 100),
        (offset: 100, length: 100),
      ],
      newChapters: const [(offset: 0, length: 200)],
      migrationId: 'test-remap-merged-chapter',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('reading_position_102'), isNull);
    expect(prefs.getInt('chapter_102'), 0);
    final anchor = jsonDecode(prefs.getString('reading_anchor_102')!)
        as Map<String, dynamic>;
    expect(anchor['chapter'], 0);
    expect(anchor['globalOffset'], 100);
    expect(anchor['fraction'], 0.5);
    final journal = jsonDecode(
      prefs.getString('reading_remap_journal_test-remap-merged-chapter')!,
    ) as Map<String, dynamic>;
    expect(journal['status'], 'done');
  });

  test('replaying the same migration id is idempotent', () async {
    SharedPreferences.setMockInitialValues({'chapter_101': 0});
    final state = await LibraryState.load();
    const oldChapters = [
      (offset: 0, length: 100),
      (offset: 100, length: 100),
    ];
    const newChapters = [(offset: 0, length: 200)];
    await state.remapChapterProgress(
      101,
      oldChapters: oldChapters,
      newChapters: newChapters,
      migrationId: 'test-remap-idempotent',
    );
    final prefs = await SharedPreferences.getInstance();
    final firstAnchor = jsonDecode(prefs.getString('reading_anchor_101')!)
        as Map<String, dynamic>;
    await state.remapChapterProgress(
      101,
      oldChapters: oldChapters,
      newChapters: newChapters,
      migrationId: 'test-remap-idempotent',
    );
    final secondAnchor = jsonDecode(prefs.getString('reading_anchor_101')!)
        as Map<String, dynamic>;
    expect(prefs.getInt('chapter_101'), 0);
    expect(secondAnchor['chapter'], firstAnchor['chapter']);
    expect(secondAnchor['fraction'], firstAnchor['fraction']);
    expect(secondAnchor['globalOffset'], firstAnchor['globalOffset']);
  });

  Future<SharedPreferences> stateWithPosition({
    required int id,
    required int chapter,
    required double fraction,
  }) async {
    final position = ReadingPosition(
      chapter: chapter,
      chapterId: chapter,
      offset: 0,
      fraction: fraction,
      fontSize: 19,
      width: 0,
      updatedAt: 123,
    );
    SharedPreferences.setMockInitialValues({
      'chapter_$id': chapter,
      'reading_position_$id': jsonEncode(position.toJson()),
    });
    await LibraryState.load();
    return SharedPreferences.getInstance();
  }

  test('chapter end anchor stays in the previous chapter', () async {
    final prefs = await stateWithPosition(id: 103, chapter: 0, fraction: 1.0);
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      103,
      oldChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      newChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      migrationId: 'boundary-end',
    );
    expect(prefs.getInt('chapter_103'), 0);
    final position = jsonDecode(prefs.getString('reading_position_103')!)
        as Map<String, dynamic>;
    expect(position['fraction'], 1.0);
  });

  test('near-end fraction uses floor and does not jump to next chapter',
      () async {
    final prefs =
        await stateWithPosition(id: 104, chapter: 0, fraction: 0.999);
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      104,
      oldChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      newChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      migrationId: 'boundary-near-end',
    );
    expect(prefs.getInt('chapter_104'), 0);
    final position = jsonDecode(prefs.getString('reading_position_104')!)
        as Map<String, dynamic>;
    expect(position['fraction'], 0.9);
  });

  test('book end anchor stays in the last non-empty chapter', () async {
    final prefs = await stateWithPosition(id: 106, chapter: 1, fraction: 1.0);
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      106,
      oldChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      newChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      migrationId: 'boundary-book-end',
    );
    expect(prefs.getInt('chapter_106'), 1);
    final position = jsonDecode(prefs.getString('reading_position_106')!)
        as Map<String, dynamic>;
    expect(position['fraction'], 1.0);
  });

  test('no-progress migration leaves a done journal, replay does not remap later progress', () async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    const oldChapters = [
      (offset: 0, length: 100),
      (offset: 100, length: 100),
    ];
    const newChapters = [(offset: 0, length: 200)];
    await state.remapChapterProgress(
      110,
      oldChapters: oldChapters,
      newChapters: newChapters,
      migrationId: 'no-progress-done',
    );
    final prefs = await SharedPreferences.getInstance();
    final journal = jsonDecode(
      prefs.getString('reading_remap_journal_no-progress-done')!,
    ) as Map<String, dynamic>;
    expect(journal['status'], 'done');
    // 用户随后按新表产生进度，再重放同一任务：必须原样保留。
    // 不能用 setMockInitialValues 重置，否则会把刚写的 done 标记清掉。
    await prefs.setInt('chapter_110', 0);
    await prefs.setString(
      'reading_position_110',
      jsonEncode(ReadingPosition(
        chapter: 0,
        chapterId: 0,
        offset: 0,
        fraction: 0.75,
        fontSize: 19,
        width: 0,
        updatedAt: 123,
      ).toJson()),
    );
    final state2 = await LibraryState.load();
    await state2.remapChapterProgress(
      110,
      oldChapters: oldChapters,
      newChapters: newChapters,
      migrationId: 'no-progress-done',
    );
    final position = jsonDecode(prefs.getString('reading_position_110')!)
        as Map<String, dynamic>;
    expect(position['fraction'], 0.75);
  });

  test('stale anchor is ignored once the chapter key has moved on', () async {
    SharedPreferences.setMockInitialValues({
      'chapter_108': 1,
      'reading_anchor_108': jsonEncode({
        'version': 1,
        'chapter': 0,
        'fraction': 0.5,
        'globalOffset': 100,
        'atChapterEnd': false,
      }),
    });
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      108,
      oldChapters: const [
        (offset: 0, length: 200),
        (offset: 200, length: 100),
      ],
      newChapters: const [
        (offset: 0, length: 100),
        (offset: 100, length: 100),
        (offset: 200, length: 100),
      ],
      migrationId: 'stale-anchor',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('chapter_108'), 2);
  });

  test('formal position is not pulled back by an old chapter-end anchor', () async {
    final prefs = await stateWithPosition(id: 109, chapter: 1, fraction: 0.0);
    await prefs.setString(
      'reading_anchor_109',
      jsonEncode({
        'version': 1,
        'chapter': 0,
        'fraction': 1.0,
        'globalOffset': 10,
        'atChapterEnd': true,
      }),
    );
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      109,
      oldChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      newChapters: const [
        (offset: 0, length: 10),
        (offset: 10, length: 10),
      ],
      migrationId: 'formal-over-anchor',
    );
    expect(prefs.getInt('chapter_109'), 1);
    final position = jsonDecode(prefs.getString('reading_position_109')!)
        as Map<String, dynamic>;
    expect(position['fraction'], 0.0);
  });

  test('empty chapter does not participate in offset matching', () async {
    SharedPreferences.setMockInitialValues({'chapter_107': 0});
    final state = await LibraryState.load();
    await state.remapChapterProgress(
      107,
      oldChapters: const [
        (offset: 0, length: 0),
        (offset: 0, length: 10),
      ],
      newChapters: const [
        (offset: 0, length: 0),
        (offset: 0, length: 10),
      ],
      migrationId: 'boundary-empty-chapter',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('chapter_107'), 1);
  });
}
