import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getExternalStoragePath() async => path;
}

Future<String> _fingerprint(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<String> _slice(File file, int offset, int length) async {
  var position = 0;
  final result = StringBuffer();
  await for (final chunk in file.openRead().transform(utf8.decoder)) {
    final next = position + chunk.length;
    if (next > offset && position < offset + length) {
      result.write(
        chunk.substring(
          offset > position ? offset - position : 0,
          offset + length < next ? offset + length - position : chunk.length,
        ),
      );
    }
    position = next;
    if (position >= offset + length) break;
  }
  expect(result.length, length);
  return result.toString().trim();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final previousPaths = PathProviderPlatform.instance;
  late Directory root;
  late LocalLibraryStore store;
  var serial = 0;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    root = await Directory.systemTemp.createTemp('local-large-text-');
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    store = await LocalLibraryStore.load();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    store.dispose();
    PathProviderPlatform.instance = previousPaths;
    messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await root.delete(recursive: true);
  });

  test(
    '48 MiB TXT imports, hashes, splits and reads after restart',
    () async {
      final source = File('${await store.appFolderPath}/large.txt');
      final output = await source.open(mode: FileMode.write);
      final body = '${'甲😀乙。' * 2000}\n';
      try {
        for (var chapter = 1; chapter <= 2200; chapter++) {
          await output.writeString('第$chapter章 测试\n$body');
        }
      } finally {
        await output.close();
      }
      expect(await source.length(), greaterThan(47 * 1024 * 1024));
      final result = await store.scanAppFolder();
      expect(result.failures, isEmpty);
      expect(result.added, 1);
      expect(store.books.single.chapters, hasLength(2200));
      final originalId = store.books.single.id;
      store.dispose();
      store = await LocalLibraryStore.load();
      final unchanged = await store.scanAppFolder();
      expect(unchanged.failures, isEmpty);
      expect(unchanged.refreshed, 0);
      expect(store.books.single.id, originalId);
      final chapters = await store.chapters(originalId);
      for (final index in [2199, 0, 1100, 1101, 2199]) {
        expect(
          await store.chapterContent(originalId, chapters[index]),
          body.trim(),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'empty, malformed and oversized TXT report distinct errors without records',
    () async {
      final folder = await store.appFolderPath;
      await File('$folder/empty.txt').writeAsBytes([]);
      await File('$folder/bom-only.txt').writeAsBytes([0xef, 0xbb, 0xbf]);
      await File('$folder/invalid.txt').writeAsBytes([0xff, 0xff]);
      final oversized = await File(
        '$folder/oversized.txt',
      ).open(mode: FileMode.write);
      await oversized.truncate(localTextMaxSourceBytes + 1);
      await oversized.close();
      final result = await store.scanAppFolder();
      expect(result.skipped, 4);
      expect(result.failures.values, contains(contains('文件为空')));
      expect(result.failures.values, contains(contains('解码失败')));
      expect(result.failures.values, contains(contains('文件过大')));
      expect(store.books, isEmpty);
      await expectLater(store.ensureReady(localNovelIdBase), throwsStateError);
      final internal = Directory('${root.path}/local_books');
      expect(
        await internal
            .list()
            .where((entry) => entry.path.endsWith('.importing'))
            .length,
        0,
      );
    },
  );

  test(
    'rescan keeps an existing book when its TXT becomes BOM-only',
    () async {
      final folder = await store.appFolderPath;
      final file = File('$folder/keep.txt');
      await file.writeAsString('第一章 开始\n这是第一章的正文内容。\n', flush: true);

      // 第一次扫描：正常导入。
      final first = await store.scanAppFolder();
      expect(first.failures, isEmpty);
      expect(store.books, hasLength(1));
      final firstCount = store.books.length;
      final original = store.books.single;
      final id = original.id;
      final title = original.title;
      final sourceKey = original.sourceKey;

      // 覆写为纯 BOM。显式推后 mtime，避免文件系统时间精度导致变更检测跳过重导入。
      await file.writeAsBytes([0xef, 0xbb, 0xbf], flush: true);
      await file.setLastModified(
        DateTime.now().add(const Duration(minutes: 1)),
      );

      // 第二次扫描：重导入失败，但记录必须保留。
      final second = await store.scanAppFolder();
      final failure = second.failures.entries.single;
      expect(failure.key, contains('keep.txt'));
      expect(failure.value, contains('文件为空'));
      expect(second.skipped, 1);

      expect(store.books.length, greaterThanOrEqualTo(firstCount));
      expect(second.total, store.books.length);
      final kept = store.books.where((b) => b.id == id).toList();
      expect(kept, hasLength(1));
      expect(kept.single.title, title);
      expect(kept.single.sourceKey, sourceKey);

      // 持久化层：换用新 store 从同一 root 与 prefs 重新加载。
      store.dispose();
      store = await LocalLibraryStore.load();

      final reloaded = store.books.where((b) => b.id == id).toList();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.title, title);
      expect(reloaded.single.sourceKey, sourceKey);
    },
  );

  test('a huge single chapter is bounded before allocating its body', () async {
    final source = File('${await store.appFolderPath}/single.txt');
    final output = await source.open(mode: FileMode.write);
    final chunk = utf8.encode('正文内容' * 8192);
    for (var block = 0; block < 140; block++) {
      await output.writeFrom(chunk);
    }
    await output.close();
    expect((await store.scanAppFolder()).failures, isEmpty);
    final book = store.books.single;
    final chapters = await store.chapters(book.id);
    await expectLater(
      store.chapterContent(book.id, chapters.single),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('单章正文过大'),
        ),
      ),
    );
  });

  const corpus = [
    '/home/hatch/workspace/novel_split/extracted/小说/古风/《六朝清羽记》 《六朝云龙吟》 《六朝燕歌行》 节.txt',
    '/home/hatch/workspace/novel_split/extracted/小说/未看/呢喃诗章 north 3.5版 xlsz001代整理(无限期停更).txt',
  ];
  for (final path in corpus) {
    test(
      'real large TXT: ${path.split('/').last}',
      () async {
        final source = File(path);
        final originalDigest = await _fingerprint(source);
        final originalStat = await source.stat();
        final copied = await source.copy(
          '${await store.appFolderPath}/corpus.txt',
        );
        final direct = await store.scanAppFolder();
        expect(direct.failures, isEmpty);
        expect(direct.added, 1);
        final book = store.books.single;
        expect(book.sourceFingerprint, originalDigest);
        expect(book.chapters.length, greaterThan(100));
        expect(book.wordCount, greaterThan(1000000));
        store.dispose();
        store = await LocalLibraryStore.load();
        final chapters = await store.chapters(book.id);
        final snapshot = File(store.textPathFor(store.books.single));
        for (final index in [chapters.length - 1, 0, chapters.length ~/ 2, 1]) {
          final ref = book.chapters[index];
          final expected = await _slice(snapshot, ref.offset, ref.length);
          expect(expected, isNotEmpty);
          expect(
            await store.chapterContent(book.id, chapters[index]),
            expected,
          );
        }
        expect((await store.scanAppFolder()).failures, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('local_library_folder', 'content://test/large');
        messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
          if (call.method == 'scanLocalFolder') {
            return {
              'complete': true,
              'entries': [
                {
                  'uri': 'content://test/large/book',
                  'name': 'saf.txt',
                  'size': originalStat.size,
                  'modified': 1,
                },
              ],
            };
          }
          if (call.method == 'prepareLocalText') {
            final prepared = await copied.copy(
              '${root.path}/prepared-${serial++}.txt',
            );
            return {'path': prepared.path, 'fingerprint': originalDigest};
          }
          if (call.method == 'fingerprintLocalText') return originalDigest;
          throw MissingPluginException();
        });
        final saf = await store.scan();
        expect(saf.failures, isEmpty);
        expect(saf.added, 1);
        expect(
          store.books.last.chapters.map((chapter) => chapter.toJson()),
          book.chapters.map((chapter) => chapter.toJson()),
        );
        expect(await _fingerprint(source), originalDigest);
        expect((await source.stat()).modified, originalStat.modified);
        expect((await source.stat()).size, originalStat.size);
        stdout.writeln(
          'CORPUS ${originalStat.size} bytes; ${chapters.length} chapters; ${book.wordCount} words; SHA-256 $originalDigest',
        );
      },
      skip: !File(path).existsSync(),
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
