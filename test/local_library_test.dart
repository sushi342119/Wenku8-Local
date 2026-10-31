import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_epub.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';

import 'support/cover_fixture.dart';

class _EpubTestPaths extends PathProviderPlatform {
  _EpubTestPaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getExternalStoragePath() async => root;
}

class _EpubTestFile extends Fake implements File {
  _EpubTestFile(this.handle);

  final RandomAccessFile? handle;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      handle ?? (throw const FileSystemException('permission denied'));
}

class _EpubTestHandle extends Fake implements RandomAccessFile {
  _EpubTestHandle(this.file, {this.failLength = false, this.failClose = false});

  final RandomAccessFile file;
  final bool failLength;
  final bool failClose;
  bool closed = false;
  bool syncCloseCalled = false;

  @override
  int lengthSync() {
    if (failLength) throw const FileSystemException('length failed');
    return file.lengthSync();
  }

  @override
  int positionSync() => file.positionSync();

  @override
  void setPositionSync(int position) => file.setPositionSync(position);

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) =>
      file.readIntoSync(buffer, start, end);

  @override
  Future<RandomAccessFile> close() async {
    if (failClose) throw const FileSystemException('close failed');
    await file.close();
    closed = true;
    return this;
  }

  @override
  void closeSync() {
    syncCloseCalled = true;
    file.closeSync();
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local novel ids stay in the reserved positive int32 range', () {
    expect(isLocalNovelId(localNovelIdBase), isTrue);
    expect(isLocalNovelId(localNovelIdBase + 12345), isTrue);
    expect(isLocalNovelId(0x7fffffff), isTrue);
    expect(isLocalNovelId(1239), isFalse);
    expect(isLocalNovelId(0), isFalse);
    expect(isLocalNovelId(-1), isFalse);
  });

  test('chapter splitter finds standard chapter headings', () {
    const text = '斗破苍穹\n\n第一章 陨落的天才\n\n正文第一段。\n\n第二章 斗气大陆\n\n正文第二段。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.length, 3);
    expect(chapters.first.title, '前言');
    expect(chapters[1].title, '第一章 陨落的天才');
    expect(chapters[2].title, '第二章 斗气大陆');
    final first = text.substring(
      chapters[1].offset,
      chapters[1].offset + chapters[1].length,
    );
    expect(first, contains('正文第一段'));
    expect(first, isNot(contains('第一章')));
  });

  test('chapter splitter falls back to a single chapter', () {
    const text = '没有章节标题的正文\n第二段\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.length, 1);
    expect(chapters.single.title, '正文');
  });

  test('chapter splitter keeps ambiguous long heading suffix in body', () {
    final text = '第一章 ${'很长的正文' * 20}\n\n第一章 短标题\n\n正文。\n\n第二章 另一章\n\n正文。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.map((c) => c.title), ['第一章', '第一章 短标题', '第二章 另一章']);
    expect(
      text.substring(
        chapters.first.offset,
        chapters.first.offset + chapters.first.length,
      ),
      contains('很长的正文'),
    );
  });

  test('chapter splitter accepts full-width indented headings', () {
    // 标题行以多个全角空格缩进/居中、数字为全角，是用户书库最常见的漏检格式。
    const text = '　　第一章、美艳娇妻\n\n正文。\n\n　　　　　　　　第２章 奸情\n\n正文。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.map((c) => c.title), ['第一章、美艳娇妻', '第２章 奸情']);
  });

  test('chapter splitter accepts longer chapter titles', () {
    const text =
        '第004章 太后寝宫内窃得抹胸绣鞋，稚根初试鞋穴抽送泄薄浆，出屏撞见母后含笑\n\n正文。\n\n第二章 短\n\n正文。\n';
    final chapters = LocalLibraryStore.splitChaptersForTest(text);
    expect(chapters.length, 2);
    expect(chapters[0].title, startsWith('第004章'));
  });

  test('title and author are parsed from common file name patterns', () {
    expect(LocalLibraryStore.titleFromNameForTest('斗破苍穹 - 天蚕土豆.txt'), '斗破苍穹');
    expect(LocalLibraryStore.authorFromNameForTest('斗破苍穹 - 天蚕土豆.txt'), '天蚕土豆');
    expect(LocalLibraryStore.titleFromNameForTest('凡人修仙传.pdf'), '凡人修仙传');
    expect(LocalLibraryStore.authorFromNameForTest('凡人修仙传.pdf'), '');
  });

  test('local book json round trip keeps chapter index', () {
    const book = LocalBook(
      id: localNovelIdBase + 7,
      title: '测试',
      author: '作者',
      fileUri: 'content://doc/1',
      fileName: '测试 - 作者.txt',
      kind: LocalBookKind.txt,
      size: 1024,
      modified: 1720000000000,
      chapters: [LocalChapterIndex('第一章', 10, 100)],
      pageCount: 0,
    );
    final restored = LocalBook.fromJson(
      Map<String, Object?>.from(book.toJson()),
    );
    expect(restored.id, book.id);
    expect(restored.title, '测试');
    expect(restored.kind, LocalBookKind.txt);
    expect(restored.chapters.single.title, '第一章');
    expect(restored.chapters.single.offset, 10);
  });

  test('formatLocalSize renders human sizes', () {
    expect(formatLocalSize(512), '512 B');
    expect(formatLocalSize(2048), '2.0 KB');
    expect(formatLocalSize(5 * 1024 * 1024), '5.0 MB');
  });

  // ---- 第 5 块：EPUB 相关测试 ----

  Future<Directory> makeTempDir() async {
    final dir = await Directory.systemTemp.createTemp('local_epub_test_');
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
    return dir;
  }

  const imgAbBytes = <int>[0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03];
  const picBytes = <int>[0xFF, 0xD8, 0xFF, 0x04, 0x05];
  const coverBytes = <int>[0xFF, 0xD8, 0xFF, 0x06];

  Map<String, List<int>> baseEpubFiles() {
    const container = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

    const opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试书</dc:title>
    <dc:creator>作者</dc:creator>
    <dc:identifier id="uid">test-uid</dc:identifier>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch4" href="ch4.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="cover.jpg" media-type="image/jpeg"/>
    <item id="img-ab" href="../Images/a%20b.jpg" media-type="image/jpeg"/>
    <item id="pic" href="pic.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="ch3"/>
    <itemref idref="ch4"/>
  </spine>
</package>''';

    const ncx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-uid"/></head>
  <docTitle><text>测试书</text></docTitle>
  <navMap>
    <navPoint id="np1" playOrder="1">
      <navLabel><text>第一章</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
    <navPoint id="np2" playOrder="2">
      <navLabel><text>第二章</text></navLabel>
      <content src="ch2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';

    const ch1 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head></head>
<body>
  <p>正文段落&nbsp;一</p>
  <div><img src="../Images/a%20b.jpg" alt=""/></div>
  <p>正文段落二</p>
</body>
</html>''';

    const ch2 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head></head>
<body>
  <div>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100">
      <image width="100" height="100" xlink:href="pic.jpg"/>
    </svg>
  </div>
  <p>正文段落</p>
</body>
</html>''';

    const ch3 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>第三章</title></head>
<body>
  <p>正文段落</p>
</body>
</html>''';

    const ch4 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head></head>
<body>
  <p>正文段落</p>
</body>
</html>''';

    return {
      'mimetype': utf8.encode('application/epub+zip'),
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/toc.ncx': utf8.encode(ncx),
      'OEBPS/ch1.xhtml': utf8.encode(ch1),
      'OEBPS/ch2.xhtml': utf8.encode(ch2),
      'OEBPS/ch3.xhtml': utf8.encode(ch3),
      'OEBPS/ch4.xhtml': utf8.encode(ch4),
      'OEBPS/cover.jpg': coverBytes,
      'OEBPS/pic.jpg': picBytes,
      'Images/a b.jpg': imgAbBytes,
    };
  }

  Future<String> buildEpub(Directory root, Map<String, List<int>> files) async {
    final src = Directory('${root.path}/src');
    await src.create(recursive: true);
    for (final entry in files.entries) {
      final file = File('${src.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value);
    }
    final epubPath = '${root.path}/book.epub';
    final encoder = ZipFileEncoder();
    await encoder.zipDirectory(src, filename: epubPath);
    return epubPath;
  }

  List<int> epubBytes(Map<String, List<int>> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(
        ArchiveFile.noCompress(entry.key, entry.value.length, entry.value),
      );
    }
    return ZipEncoder().encode(archive, modified: DateTime(2026));
  }

  Map<String, List<int>> changedEpubFiles() {
    final files = baseEpubFiles();
    files['OEBPS/ch1.xhtml'] = utf8.encode(
      utf8.decode(files['OEBPS/ch1.xhtml']!).replaceAll('正文', '新版'),
    );
    return files;
  }

  group('EPUB 书库生产路径', () {
    const tree = 'content://test/tree/books';
    const document = '$tree/document/book';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory root;
    late PathProviderPlatform previousPaths;
    late List<int> sourceBytes;
    late Map<String, Object?> entry;
    final copies = <String>[];
    Future<void> Function(String)? copyOverride;

    setUp(() async {
      root = await makeTempDir();
      previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _EpubTestPaths(root.path);
      SharedPreferences.setMockInitialValues({'local_library_folder': tree});
      await TagStore.load();
      sourceBytes = epubBytes(baseEpubFiles());
      entry = {
        'uri': document,
        'name': '测试书 - 作者.epub',
        'size': sourceBytes.length,
        'modified': 1000,
      };
      copies.clear();
      copyOverride = null;
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
        switch (call.method) {
          case 'scanLocalFolder':
            return {'complete': true, 'entries': [entry]};
          case 'copyDocumentToFile':
            final arguments = call.arguments as Map;
            expect(arguments['docUri'], document);
            final destination = arguments['destPath'] as String;
            copies.add(destination);
            if (copyOverride case final copy?) {
              await copy(destination);
            } else {
              await File(destination).writeAsBytes(sourceBytes);
            }
            return destination;
        }
        throw MissingPluginException(call.method);
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
      PathProviderPlatform.instance = previousPaths;
    });

    Future<LocalLibraryStore> loadStore() async {
      final store = await LocalLibraryStore.load();
      addTearDown(store.dispose);
      return store;
    }

    File cacheFor(LocalBook book) =>
        File('${root.path}/cache/local_epub/${book.id}.epub');

    Future<void> expectCacheFiles(List<String> names) async {
      final directory = Directory('${root.path}/cache/local_epub');
      final actual = await directory.exists()
          ? await directory.list().map((file) => file.path.split('/').last).toList()
          : <String>[];
      expect(actual, unorderedEquals(names));
    }

    Future<File> localSource({String name = '测试书 - 作者.epub'}) async {
      final file = File('${root.path}/novels/$name');
      await file.parent.create(recursive: true);
      return file.writeAsBytes(sourceBytes);
    }

    Future<void> writeIndex(LocalBook book) async {
      final index = File('${root.path}/local_books/index.json');
      await index.parent.create(recursive: true);
      await index.writeAsString(jsonEncode({'books': [book.toJson()]}));
    }

    for (final force in [false, true]) {
      test('SAF 同长度${force ? '强制刷新' : '修改时间变化'}重新复制 EPUB', () async {
        final store = await loadStore();
        expect((await store.scan()).added, 1);
        final original = store.books.single;
        final updatedBytes = epubBytes(changedEpubFiles());
        expect(updatedBytes.length, sourceBytes.length);
        sourceBytes = updatedBytes;
        if (!force) entry['modified'] = 2000;
        final result = await store.scan(force: force);
        final updated = store.books.single;
        expect(result.refreshed, 1);
        expect(result.failures, isEmpty);
        expect(copies, hasLength(2));
        expect(copies.toSet(), hasLength(2));
        expect(updated.id, original.id);
        expect(updated.modified, entry['modified']);
        expect(updated.sourceFingerprint, sha256.convert(sourceBytes).toString());
        expect(updated.sourceFingerprint, isNot(original.sourceFingerprint));
        expect(await cacheFor(updated).readAsBytes(), sourceBytes);
        final chapter = await store.epubChapter(updated.id, 0);
        expect(chapter.blocks.map((block) => block.text).join(), contains('新版'));
        expect(copies, hasLength(2));
        await expectCacheFiles(['${updated.id}.epub']);
      });
    }

    test('SAF 同长度缓存损坏按指纹重复制一次，正确缓存复用', () async {
      final store = await loadStore();
      await store.scan();
      final book = store.books.single;
      await store.epubChapter(book.id, 0);
      expect(copies, hasLength(1));
      final corrupted = epubBytes(changedEpubFiles());
      expect(corrupted.length, book.size);
      await cacheFor(book).writeAsBytes(corrupted);
      await store.epubChapter(book.id, 0);
      expect(copies, hasLength(2));
      expect(await cacheFor(book).readAsBytes(), sourceBytes);
      expect((await store.scan()).refreshed, 0);
      expect(copies, hasLength(2));
      await expectCacheFiles(['${book.id}.epub']);
    });

    void failImport(String failure) {
      switch (failure) {
        case '打开失败':
          sourceBytes = [1, 2, 3];
        case '解析失败':
          sourceBytes = epubBytes(
            baseEpubFiles()..['OEBPS/content.opf'] = utf8.encode('<package>'),
          );
        case '空 spine':
          final files = baseEpubFiles();
          files['OEBPS/content.opf'] = utf8.encode(
            utf8.decode(files['OEBPS/content.opf']!).replaceAll(
              RegExp(r'<itemref[^>]*/>'),
              '',
            ),
          );
          sourceBytes = epubBytes(files);
        case '输入失败':
          copyOverride = (_) async => throw PlatformException(code: 'input');
        case '写入失败':
          copyOverride = (path) async {
            await File(path).writeAsBytes([1, 2, 3]);
            throw PlatformException(code: 'write');
          };
        case '长度不符':
          copyOverride = (path) async {
            await File(path).writeAsBytes([1]);
          };
        case '超过 256 MiB':
          entry['size'] = localTextMaxSourceBytes + 1;
          return;
      }
      entry['size'] = sourceBytes.length;
    }

    for (final failure in [
      '打开失败',
      '解析失败',
      '空 spine',
      '输入失败',
      '写入失败',
      '长度不符',
      '超过 256 MiB',
    ]) {
      test('SAF EPUB 新导入$failure不遗留缓存', () async {
        final store = await loadStore();
        failImport(failure);
        final result = await store.scan();
        expect(result.added, 0);
        expect(result.skipped, 1);
        expect(result.failures, hasLength(1));
        expect(store.books, isEmpty);
        expect(copies, hasLength(failure == '超过 256 MiB' ? 0 : 1));
        await expectCacheFiles([]);
      });

      test('SAF EPUB 刷新$failure保留既有正确缓存', () async {
        final store = await loadStore();
        await store.scan();
        final original = store.books.single;
        final originalBytes = List<int>.of(sourceBytes);
        failImport(failure);
        final result = await store.scan(force: true);
        expect(result.refreshed, 0);
        expect(result.skipped, 1);
        expect(result.failures, hasLength(1));
        expect(store.books.single.toJson(), original.toJson());
        expect(await cacheFor(original).readAsBytes(), originalBytes);
        expect(copies, hasLength(failure == '超过 256 MiB' ? 1 : 2));
        expect((await store.epubChapter(original.id, 0)).blocks, isNotEmpty);
        await expectCacheFiles(['${original.id}.epub']);
      });
    }

    Future<Directory> blockIndexWrite() async {
      final blocker = Directory('${root.path}/local_books/index.json.tmp');
      await blocker.create(recursive: true);
      addTearDown(() async {
        if (await blocker.exists()) await blocker.delete(recursive: true);
      });
      return blocker;
    }

    test('SAF EPUB 新导入索引写入失败回滚正式缓存', () async {
      final store = await loadStore();
      final blocker = await blockIndexWrite();

      await expectLater(store.scan(), throwsA(isA<FileSystemException>()));

      expect(copies, hasLength(1));
      expect(store.books, isEmpty);
      await expectCacheFiles([]);
      final restored = await loadStore();
      expect(restored.books, isEmpty);
      await expectCacheFiles([]);

      await blocker.delete(recursive: true);
      expect((await restored.scan()).added, 1);
      final book = restored.books.single;
      expect(copies, hasLength(2));
      expect(await cacheFor(book).readAsBytes(), sourceBytes);
      expect((await restored.epubChapter(book.id, 0)).blocks, isNotEmpty);
      await expectCacheFiles(['${book.id}.epub']);
    });

    test('SAF EPUB 刷新索引写入失败恢复旧缓存与指纹且可阅读', () async {
      final store = await loadStore();
      await store.scan();
      final original = store.books.single;
      final originalBytes = List<int>.of(sourceBytes);
      sourceBytes = epubBytes(changedEpubFiles());
      expect(sourceBytes.length, originalBytes.length);
      expect(
        sha256.convert(sourceBytes).toString(),
        isNot(original.sourceFingerprint),
      );
      entry['modified'] = 2000;
      final blocker = await blockIndexWrite();

      await expectLater(store.scan(), throwsA(isA<FileSystemException>()));

      expect(copies, hasLength(2));
      expect(store.books.single.toJson(), original.toJson());
      expect(await cacheFor(original).readAsBytes(), originalBytes);
      expect(
        sha256.convert(await cacheFor(original).readAsBytes()).toString(),
        original.sourceFingerprint,
      );
      for (final readableStore in [store, await loadStore()]) {
        expect(readableStore.books.single.toJson(), original.toJson());
        final chapter = await readableStore.epubChapter(original.id, 0);
        expect(
          chapter.blocks.map((block) => block.text).join(),
          contains('正文段落'),
        );
        expect(
          chapter.blocks.map((block) => block.text).join(),
          isNot(contains('新版')),
        );
      }
      expect(copies, hasLength(2));
      await expectCacheFiles(['${original.id}.epub']);

      await blocker.delete(recursive: true);
      expect((await store.scan()).refreshed, 1);
      expect(await cacheFor(original).readAsBytes(), sourceBytes);
      expect(
        store.books.single.sourceFingerprint,
        sha256.convert(sourceBytes).toString(),
      );
      await expectCacheFiles(['${original.id}.epub']);
    });

    test('本地 EPUB 文件名含 # ? % 和空格编码往返并可阅读', () async {
      final file = await localSource(name: '书#问?百分%20 空格.epub');
      final store = await loadStore();
      expect((await store.scanAppFolder()).added, 1);
      final book = store.books.single;
      expect(book.fileUri, Uri.file(file.path).toString());
      expect(Uri.parse(book.fileUri).toFilePath(), file.path);
      expect(book.sourceKey, file.path);
      expect((await store.epubChapter(book.id, 0)).blocks, isNotEmpty);
      expect((await store.scanAppFolder(force: true)).refreshed, 1);
      expect(store.books.single.id, book.id);
      expect(store.books.single.fileUri, book.fileUri);
    });

    for (final hasSourceKey in [false, true]) {
      test('旧未编码 EPUB URI 兼容${hasSourceKey ? '来源路径' : '原始路径'}并重扫迁移', () async {
        final file = await localSource(name: '旧书#问?百分%20 空格.epub');
        final store = await loadStore();
        await store.scanAppFolder();
        final original = store.books.single;
        await writeIndex(original.copyWith(
          fileUri: 'file://${file.path}',
          sourceId: '',
          sourceKey: hasSourceKey ? file.path : '',
        ));
        final restored = await loadStore();
        expect((await restored.epubChapter(original.id, 0)).blocks, isNotEmpty);
        final result = await restored.scanAppFolder(force: true);
        expect(result.added, 0);
        expect(result.refreshed, 1);
        expect(restored.books.single.id, original.id);
        expect(restored.books.single.sourceKey, file.path);
        expect(restored.books.single.fileUri, Uri.file(file.path).toString());
      });
    }

    for (final change in ['spine 顺序', '章节数量']) {
      test('EPUB 无旧指纹时仍拒绝$change变化', () async {
        final file = await localSource();
        final store = await loadStore();
        await store.scanAppFolder();
        final original = store.books.single;
        await writeIndex(original.copyWith(sourceFingerprint: ''));
        final restored = await loadStore();
        final files = baseEpubFiles();
        final opf = utf8.decode(files['OEBPS/content.opf']!);
        files['OEBPS/content.opf'] = utf8.encode(
          change == 'spine 顺序'
              ? opf.replaceAll(
                  '<itemref idref="ch1"/>\n    <itemref idref="ch2"/>',
                  '<itemref idref="ch2"/>\n    <itemref idref="ch1"/>',
                )
              : opf.replaceAll('<itemref idref="ch4"/>', ''),
        );
        final changedBytes = epubBytes(files);
        if (change == 'spine 顺序') expect(changedBytes.length, original.size);
        await file.writeAsBytes(changedBytes);
        await expectLater(
          restored.epubChapter(original.id, 0),
          throwsA(isA<StateError>().having(
            (error) => error.message,
            'message',
            'EPUB 章节对应关系已变化，请重新扫描',
          )),
        );
      });
    }

    test('本地 EPUB href 不变但指纹变化拒绝读取', () async {
      final file = await localSource();
      final store = await loadStore();
      await store.scanAppFolder();
      final book = store.books.single;
      await file.writeAsBytes(epubBytes(changedEpubFiles()));
      await expectLater(
        store.epubChapter(book.id, 0),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          'EPUB 源文件已变化，请重新扫描',
        )),
      );
    });

    test('EPUB 图片字节换章复用缓存，指纹缓存在文件变化后失效', () async {
      final file = await localSource();
      final store = await loadStore();
      await store.scanAppFolder();
      final book = store.books.single;
      final first = await store.epubChapter(book.id, 0);
      final image = first.images['Images/a b.jpg'];
      expect(image, imgAbBytes);
      await store.epubChapter(book.id, 1);
      final again = await store.epubChapter(book.id, 0);
      expect(identical(again.images['Images/a b.jpg'], image), isTrue);

      // 同长度改写并推后修改时间：必须重算指纹并走“请重新扫描”，不读旧缓存。
      final changed = epubBytes(changedEpubFiles());
      expect(changed.length, book.size);
      await file.writeAsBytes(changed);
      await file.setLastModified(DateTime.now().add(const Duration(minutes: 1)));
      await expectLater(
        store.epubChapter(book.id, 0),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          'EPUB 源文件已变化，请重新扫描',
        )),
      );

      expect((await store.scanAppFolder(force: true)).refreshed, 1);
      final refreshed = store.books.single;
      expect(refreshed.sourceFingerprint, isNot(book.sourceFingerprint));
      final reread = await store.epubChapter(refreshed.id, 0);
      expect(reread.blocks.map((block) => block.text).join(), contains('新版'));
      expect(reread.images['Images/a b.jpg'], imgAbBytes);
      expect(identical(reread.images['Images/a b.jpg'], image), isFalse);
    });

    for (final missingCache in [false, true]) {
      test('SAF ${missingCache ? '缓存被清除' : '缓存损坏'}且源指纹变化拒绝读取且只重试一次', () async {
        final store = await loadStore();
        await store.scan();
        final book = store.books.single;
        sourceBytes = epubBytes(changedEpubFiles());
        if (missingCache) {
          await cacheFor(book).delete();
        } else {
          await cacheFor(book).writeAsBytes(sourceBytes);
        }
        await expectLater(
          store.epubChapter(book.id, 0),
          throwsA(isA<StateError>().having(
            (error) => error.message,
            'message',
            'EPUB 源文件已变化，请重新扫描',
          )),
        );
        expect(copies, hasLength(2));
        await expectCacheFiles(missingCache ? [] : ['${book.id}.epub']);
        expect(store.books.single.sourceFingerprint, book.sourceFingerprint);
      });
    }

    test('EPUB 标签生产改名保留来源身份，备份导出导入恢复进度和标签', () async {
      final file = await localSource();
      final store = await loadStore();
      await store.scanAppFolder();
      final original = store.books.single;
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.savePosition(
        novel: store.toNovel(original).withChapters(
          await store.chapters(original.id),
        ),
        chapter: 2,
        offset: 120,
        maximum: 480,
        width: 400,
      );
      final position = state.positionFor(original.id)!.toJson();
      final tagId = await TagStore.shared.createTag('待读');
      await store.setTagsForBook(original.id, [tagId]);
      await store.renameTag(tagId, '已读');
      final renamed = store.books.single;
      final newFile = File('${file.parent.path}/测试书 - 作者 ✦已读.epub');
      expect(await file.exists(), isFalse);
      expect(await newFile.readAsBytes(), sourceBytes);
      expect(renamed.sourceKey, newFile.path);
      expect(renamed.fileName, '测试书 - 作者 ✦已读.epub');
      expect(renamed.fileUri, Uri.file(newFile.path).toString());
      expect(renamed.sourceId, original.sourceId);
      expect(renamed.id, original.id);
      expect(renamed.kind, LocalBookKind.epub);
      expect(renamed.title, original.title);
      expect(renamed.author, original.author);
      expect(renamed.chapters.map((chapter) => chapter.toJson()).toList(),
          original.chapters.map((chapter) => chapter.toJson()).toList());
      expect(renamed.epubChapterHrefs, original.epubChapterHrefs);
      expect(renamed.coverEntry, original.coverEntry);
      expect(renamed.sourceFingerprint, original.sourceFingerprint);
      expect(TagStore.shared.tagNamesForBook(original.id), ['已读']);
      expect(state.chapterFor(original.id), 2);
      expect(state.positionFor(original.id)!.toJson(), position);
      expect((await store.epubChapter(original.id, 2)).blocks, isNotEmpty);
      expect((await store.scanAppFolder()).added, 0);
      final reloaded = await loadStore();
      expect(reloaded.books.single.toJson(), renamed.toJson());

      final exported = await (await state.createBackup()).encode();
      final imported = await LibraryBackup.parse(exported);
      SharedPreferences.setMockInitialValues({});
      await TagStore.load();
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.chapterFor(original.id), 0);
      expect(restored.positionFor(original.id), isNull);
      expect(TagStore.shared.tagNamesForBook(original.id), isEmpty);
      await restored.restoreBackup(imported);
      expect(restored.chapterFor(original.id), 2);
      expect(restored.positionFor(original.id)!.toJson(), position);
      expect(TagStore.shared.tagNamesForBook(original.id), ['已读']);
      final restoredPrefs = await SharedPreferences.getInstance();
      expect(restoredPrefs.getInt('chapter_${original.id}'), 2);
      expect(
        jsonDecode(restoredPrefs.getString('reading_position_${original.id}')!),
        position,
      );
      await TagStore.load();
      expect(TagStore.shared.tagNamesForBook(original.id), ['已读']);
    });
  });

  testWidgets('FutureBuilder 换章等待保留旧 snapshot，完成后替换', (tester) async {
    // 协调人修正：原测试在 Completer 完成后续只 pump() 一次，
    // Future 回调未及送达就断言，导致第一阶段数据为 null 而失败；
    // 改为 pumpAndSettle 后，切换后等待态仍保留旧数据、完成后替换，
    // 与小胖原断言一致。生产阅读器在 connectionState != done 时
    // 显示加载指示，不会把旧章正文当成新章显示。
    final first = Completer<Map<String, Uint8List>>();
    final second = Completer<Map<String, Uint8List>>();
    final oldImages = {'old.jpg': Uint8List.fromList(picBytes)};
    final newImages = {'new.jpg': Uint8List.fromList(coverBytes)};
    late AsyncSnapshot<Map<String, Uint8List>> snapshot;
    Widget content(Future<Map<String, Uint8List>> future) =>
        FutureBuilder<Map<String, Uint8List>>(
          future: future,
          builder: (context, current) {
            snapshot = current;
            return const SizedBox.shrink();
          },
        );
    await tester.pumpWidget(content(first.future));
    first.complete(oldImages);
    await tester.pumpAndSettle();
    expect(snapshot.data, same(oldImages));
    await tester.pumpWidget(content(second.future));
    expect(snapshot.connectionState, ConnectionState.waiting);
    expect(snapshot.data, same(oldImages));
    second.complete(newImages);
    await tester.pumpAndSettle();
    expect(snapshot.connectionState, ConnectionState.done);
    expect(snapshot.data, same(newImages));
  });

  testWidgets('Image.memory 移除后 ImageCache 仍可持有图片', (tester) async {
    final bytes = (await tester.runAsync(coverFixtureBytes))!;
    final provider = MemoryImage(bytes);
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() => provider.evict());
    late BuildContext imageContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        imageContext = context;
        return Image.memory(bytes);
      }),
    ));
    await tester.runAsync(() => precacheImage(provider, imageContext));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(cache.statusForKey(provider).keepAlive, isTrue);
    expect(cache.statusForKey(provider).live, isFalse);
  });

  test('localBookKindForFileName 识别后缀', () {
    expect(localBookKindForFileName('a.epub'), LocalBookKind.epub);
    expect(localBookKindForFileName('a.EPUB'), LocalBookKind.epub);
    expect(localBookKindForFileName('a.txt'), LocalBookKind.txt);
    expect(localBookKindForFileName('a.pdf'), LocalBookKind.pdf);
    expect(localBookKindForFileName('a.zip'), isNull);
    expect(localBookKindForFileName('a'), isNull);
  });

  test('LocalBook JSON 往返 epub 字段与旧 JSON 兼容', () {
    final epubBook = LocalBook(
      id: localNovelIdBase + 11,
      title: '测试书',
      author: '作者',
      fileUri: 'content://doc/epub',
      fileName: '测试书 - 作者.epub',
      kind: LocalBookKind.epub,
      size: 1024,
      modified: 1720000000000,
      chapters: [LocalChapterIndex('第一章', 0, 0)],
      pageCount: 0,
      epubChapterHrefs: const ['OEBPS/ch1.xhtml', 'OEBPS/ch2.xhtml'],
      coverEntry: 'OEBPS/cover.jpg',
    );
    final epubBack = LocalBook.fromJson(
      Map<String, Object?>.from(epubBook.toJson()),
    );
    expect(epubBack.kind, LocalBookKind.epub);
    expect(epubBack.epubChapterHrefs, ['OEBPS/ch1.xhtml', 'OEBPS/ch2.xhtml']);
    expect(epubBack.coverEntry, 'OEBPS/cover.jpg');

    final txtBook = LocalBook(
      id: localNovelIdBase + 12,
      title: '测试书',
      author: '作者',
      fileUri: 'content://doc/txt',
      fileName: '测试书 - 作者.txt',
      kind: LocalBookKind.txt,
      size: 1024,
      modified: 1720000000000,
      chapters: [LocalChapterIndex('第一章', 10, 100)],
      pageCount: 0,
    );
    final oldJson = Map<String, Object?>.from(txtBook.toJson());
    oldJson.removeWhere((key, _) {
      final k = key.toLowerCase();
      return k.contains('epub') || k.contains('cover');
    });
    final oldBack = LocalBook.fromJson(oldJson);
    expect(oldBack.kind, LocalBookKind.txt);
    expect(oldBack.epubChapterHrefs, isEmpty);
    expect(oldBack.coverEntry, isNull);
  });

  test('epub 文件名解析标题与作者', () {
    expect(LocalLibraryStore.titleFromNameForTest('测试书 ✦标签.epub'), '测试书');
    expect(LocalLibraryStore.authorFromNameForTest('测试书 - 作者.epub'), '作者');
  });

  test('EpubPackage 解析小 EPUB：spine 顺序、标题回退、封面、图片块', () async {
    final root = await makeTempDir();
    final epubPath = await buildEpub(root, baseEpubFiles());

    final pkg = await EpubPackage.open(epubPath);
    try {
      final chapters = pkg.chapters;
      expect(chapters.length, 4);
      expect(chapters[0].href, endsWith('ch1.xhtml'));
      expect(chapters[1].href, endsWith('ch2.xhtml'));
      expect(chapters[2].href, endsWith('ch3.xhtml'));
      expect(chapters[3].href, endsWith('ch4.xhtml'));

      expect(chapters[0].title, '第一章');
      expect(chapters[1].title, '第二章');
      expect(chapters[2].title, '第三章');
      expect(chapters[3].title, '第 4 章');

      expect(pkg.coverEntry, 'OEBPS/cover.jpg');

      final ch1Blocks = await pkg.chapterBlocks(0);
      expect(ch1Blocks.map((b) => b.kind).toList(), [
        EpubBlockKind.text,
        EpubBlockKind.image,
        EpubBlockKind.text,
      ]);
      expect(ch1Blocks[0].text ?? '', isNot(contains('&nbsp;')));
      expect(ch1Blocks[0].text ?? '', contains('正文段落 一'));
      expect(ch1Blocks[1].entryPath, 'Images/a b.jpg');

      final imgBytes = await pkg.readEntry('Images/a b.jpg');
      expect(imgBytes, imgAbBytes);

      final ch2Blocks = await pkg.chapterBlocks(1);
      final svgImages = ch2Blocks
          .where((b) => b.kind == EpubBlockKind.image)
          .toList();
      expect(svgImages, isNotEmpty);
      expect(svgImages.first.entryPath, 'OEBPS/pic.jpg');
      expect(
        ch2Blocks.any(
          (b) =>
              b.kind == EpubBlockKind.text && (b.text ?? '').contains('正文段落'),
        ),
        isTrue,
      );
    } finally {
      await pkg.close();
    }
  });

  test('EpubPackage 加密、已关闭、缺失条目抛 StateError', () async {
    final root = await makeTempDir();

    final encRoot = Directory('${root.path}/enc');
    await encRoot.create();
    final encFiles = baseEpubFiles()
      ..['META-INF/encryption.xml'] = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<encryption xmlns="http://www.w3.org/2001/04/xmlenc#">'
        '<EncryptedData><CipherData><CipherReference URI="OEBPS/ch1.xhtml"/>'
        '</CipherData></EncryptedData></encryption>',
      );
    final encPath = await buildEpub(encRoot, encFiles);
    await expectLater(
      () async => await EpubPackage.open(encPath),
      throwsA(isA<StateError>()),
    );

    final okRoot = Directory('${root.path}/ok');
    await okRoot.create();
    final okPath = await buildEpub(okRoot, baseEpubFiles());

    final pkg = await EpubPackage.open(okPath);
    try {
      await expectLater(
        () async => await pkg.readEntry('OEBPS/missing.jpg'),
        throwsA(isA<StateError>()),
      );
    } finally {
      await pkg.close();
    }
    await expectLater(
      () async => await pkg.chapterBlocks(0),
      throwsA(isA<StateError>()),
    );
  });

  test('EPUB 仅字体混淆时放行正文', () async {
    for (final algorithm in [
      'http://www.idpf.org/2008/embedding',
      'http://ns.adobe.com/pdf/enc#RC',
    ]) {
      final files = baseEpubFiles()
        ..['OEBPS/fonts/font.ttf'] = const [0, 1, 2, 3]
        ..['META-INF/encryption.xml'] = utf8.encode(
          '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
          '<enc:EncryptionMethod Algorithm="$algorithm"/>'
          '<enc:CipherData><enc:CipherReference URI="OEBPS/fonts/font.ttf"/>'
          '</enc:CipherData></enc:EncryptedData></encryption>',
        );
      files['OEBPS/content.opf'] = utf8.encode(
        utf8
            .decode(files['OEBPS/content.opf']!)
            .replaceFirst(
              '</manifest>',
              '<item id="font" href="fonts/font.ttf" media-type="font/ttf"/></manifest>',
            ),
      );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        expect(pkg.chapters, hasLength(4));
        final blocks = await pkg.chapterBlocks(0);
        expect(blocks.any((b) => (b.text ?? '').contains('正文段落')), isTrue);
        expect(blocks.any((b) => b.entryPath == 'Images/a b.jpg'), isTrue);
        expect(await pkg.readEntry('OEBPS/fonts/font.ttf'), [0, 1, 2, 3]);
      } finally {
        await pkg.close();
      }
    }
  });

  test('EPUB 仅 CSS 加密时放行正文和图片', () async {
    final files = baseEpubFiles()
      ..['OEBPS/styles/main.css'] = const [0, 1, 2, 3]
      ..['META-INF/encryption.xml'] = utf8.encode(
        '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
        '<enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes256-cbc"/>'
        '<enc:CipherData><enc:CipherReference URI="OEBPS/styles/main.css"/>'
        '</enc:CipherData></enc:EncryptedData></encryption>',
      );
    files['OEBPS/content.opf'] = utf8.encode(
      utf8.decode(files['OEBPS/content.opf']!).replaceFirst(
        '</manifest>',
        '<item id="style" href="styles/main.css" media-type="text/css"/></manifest>',
      ),
    );
    final pkg = await EpubPackage.open(
      await buildEpub(await makeTempDir(), files),
    );
    addTearDown(pkg.close);
    expect(pkg.chapters, hasLength(4));
    final blocks = await pkg.chapterBlocks(0);
    expect(blocks.any((block) => (block.text ?? '').contains('正文段落')), isTrue);
    expect(blocks.any((block) => block.entryPath == 'Images/a b.jpg'), isTrue);
    expect(await pkg.readEntry('Images/a b.jpg'), imgAbBytes);
  });

  test('EPUB 加密项缺少可识别目标时保守拒绝', () async {
    for (final reference in [
      '',
      '<CipherReference/>',
      '<CipherReference URI="../../outside.css"/>',
      '<CipherReference URI="https://example.invalid/style.css"/>',
      '<CipherReference URI="OEBPS/missing.css"/>',
    ]) {
      final files = baseEpubFiles()
        ..['META-INF/encryption.xml'] = utf8.encode(
          '<encryption><EncryptedData>'
          '<EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>'
          '<CipherData>$reference</CipherData>'
          '</EncryptedData></encryption>',
        );
      await expectLater(
        EpubPackage.open(await buildEpub(await makeTempDir(), files)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '不支持加密的 EPUB',
          ),
        ),
      );
    }
  });

  test('EPUB 加密目标包含正文或图片时拒绝', () async {
    for (final algorithm in [
      'http://www.idpf.org/2008/embedding',
      'http://www.w3.org/2001/04/xmlenc#aes256-cbc',
    ]) {
      for (final target in [
        'OEBPS/ch1.xhtml',
        'OEBPS/cover.jpg',
        'Images/a%20b.jpg',
      ]) {
        final files = baseEpubFiles();
        files['META-INF/encryption.xml'] = utf8.encode(
          '<encryption xmlns="http://www.w3.org/2001/04/xmlenc#">'
          '<EncryptedData><EncryptionMethod Algorithm="$algorithm"/>'
          '<CipherData><CipherReference URI="$target"/></CipherData>'
          '</EncryptedData></encryption>',
        );
        await expectLater(
          EpubPackage.open(await buildEpub(await makeTempDir(), files)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              '不支持加密的 EPUB',
            ),
          ),
        );
      }
    }
  });

  test('空 encryption.xml 不误判整本加密', () async {
    final files = baseEpubFiles()
      ..['META-INF/encryption.xml'] = utf8.encode('<encryption/>');
    final pkg = await EpubPackage.open(
      await buildEpub(await makeTempDir(), files),
    );
    addTearDown(pkg.close);
    expect(pkg.chapters, hasLength(4));
  });

  test('resolveEpubHref 路径解析', () {
    expect(resolveEpubHref('OEBPS', '../Images/a%20b.jpg'), 'Images/a b.jpg');
    expect(resolveEpubHref('OEBPS', 'images/x.jpg'), 'OEBPS/images/x.jpg');
    expect(resolveEpubHref('OEBPS', '/x.jpg'), 'x.jpg');
    expect(resolveEpubHref('OEBPS', 'a.jpg#frag'), 'OEBPS/a.jpg');
    expect(resolveEpubHref('', '../../x.jpg'), isNull);
    expect(resolveEpubHref('OEBPS', 'https://example.com/x.jpg'), isNull);
  });

  test('href 非法编码不抛错并解码非 ASCII 段中的空格', () async {
    expect(resolveEpubHref('OEBPS', '%FF.jpg'), isNull);
    expect(resolveEpubHref('OEBPS', '%G1.jpg'), isNull);
    expect(resolveEpubHref('OEBPS', '封面%20图.jpg'), 'OEBPS/封面 图.jpg');
    final files = baseEpubFiles()
      ..['OEBPS/封面 图.jpg'] = picBytes
      ..['OEBPS/ch1.xhtml'] = utf8.encode(
        '<html><body><p>前</p><img src="%FF.jpg"/>'
        '<img src="封面%20图.jpg"/><p>后</p></body></html>',
      );
    final pkg = await EpubPackage.open(
      await buildEpub(await makeTempDir(), files),
    );
    addTearDown(pkg.close);
    final blocks = await pkg.chapterBlocks(0);
    expect(blocks.map((block) => block.text ?? block.entryPath), [
      '前',
      'OEBPS/封面 图.jpg',
      '后',
    ]);
  });

  test('href 解码斜杠后重新检查越根', () {
    expect(resolveEpubHref('', '%2e%2e%2fcover.jpg'), isNull);
    expect(resolveEpubHref('OEBPS', '%2e%2e%2f%2e%2e%2fcover.jpg'), isNull);
    expect(
      resolveEpubHref('OEBPS', '%2e%2e%2fImages/a%20b.jpg'),
      'Images/a b.jpg',
    );
    expect(resolveEpubHref('', 'safe%2F..%2F..%2Fcover.jpg'), isNull);
  });

  test('href 拒绝 authority 引用并剥离查询串', () async {
    expect(resolveEpubHref('', '//cdn.example/cover.jpg'), isNull);
    expect(resolveEpubHref('OEBPS', '//cdn.example/cover.jpg'), isNull);
    expect(resolveEpubHref('OEBPS', 'cover.jpg?v=1#x'), 'OEBPS/cover.jpg');
    expect(
      resolveEpubHref('OEBPS', 'cover%3Fv.jpg?ignored#x'),
      'OEBPS/cover?v.jpg',
    );
    final files = baseEpubFiles()
      ..['cdn.example/cover.jpg'] = picBytes
      ..['OEBPS/ch1.xhtml'] = utf8.encode(
        '<html><body><img src="//cdn.example/cover.jpg"/>'
        '<img src="cover.jpg?v=1#x"/></body></html>',
      );
    final pkg = await EpubPackage.open(
      await buildEpub(await makeTempDir(), files),
    );
    addTearDown(pkg.close);
    expect((await pkg.chapterBlocks(0)).map((block) => block.entryPath), [
      'OEBPS/cover.jpg',
    ]);
  });

  group('EpubPackage 6A 阻塞修复', () {
    List<int> xhtml(String title, String body) => utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head>'
      '<body><p>$body</p></body></html>',
    );

    List<int> utf16(String source, {required bool bigEndian}) {
      final bytes = <int>[bigEndian ? 0xfe : 0xff, bigEndian ? 0xff : 0xfe];
      for (final codeUnit in source.codeUnits) {
        if (bigEndian) {
          bytes.add(codeUnit >> 8);
          bytes.add(codeUnit & 0xff);
        } else {
          bytes.add(codeUnit & 0xff);
          bytes.add(codeUnit >> 8);
        }
      }
      return bytes;
    }

    int centralHeader(List<int> bytes, [int start = 0]) {
      for (var offset = start; offset + 3 < bytes.length; offset++) {
        if (bytes[offset] == 0x50 &&
            bytes[offset + 1] == 0x4b &&
            bytes[offset + 2] == 0x01 &&
            bytes[offset + 3] == 0x02) {
          return offset;
        }
      }
      throw StateError('测试 EPUB 缺少中央目录');
    }

    void writeLe16(List<int> bytes, int offset, int value) {
      bytes[offset] = value & 0xff;
      bytes[offset + 1] = (value >> 8) & 0xff;
    }

    void writeLe32(List<int> bytes, int offset, int value) {
      for (var index = 0; index < 4; index++) {
        bytes[offset + index] = (value >> (index * 8)) & 0xff;
      }
    }

    List<int> navDoc(String ch1Title) => utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>目录</title></head><body>'
      '<nav epub:type="landmarks"><ol><li><a href="ch2.xhtml">地标</a></li></ol></nav>'
      '<nav epub:type="toc"><ol>'
      '<li><a href="ch1.xhtml">$ch1Title</a></li>'
      '<li><a href="ch2.xhtml">第二章</a></li>'
      '<li><a href="ch2.xhtml#sec">重复</a></li>'
      '</ol></nav></body></html>',
    );

    test('截断的 zip 抛 StateError', () async {
      final src = await buildEpub(await makeTempDir(), baseEpubFiles());
      final bytes = File(src).readAsBytesSync();
      final root = await makeTempDir();
      final p = '${root.path}/truncated.epub';
      File(p).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      await expectLater(() => EpubPackage.open(p), throwsA(isA<StateError>()));
    });

    test('不存在的 EPUB 路径也统一抛 StateError', () async {
      final root = await makeTempDir();
      await expectLater(
        EpubPackage.open('${root.path}/missing.epub'),
        throwsA(isA<StateError>()),
      );
    });

    test('EPUB 打开权限错误统一抛 StateError', () async {
      final root = await makeTempDir();
      await IOOverrides.runZoned(
        () => expectLater(
          EpubPackage.open('${root.path}/denied.epub'),
          throwsA(isA<StateError>()),
        ),
        createFile: (_) => _EpubTestFile(null),
      );
    });

    test('EPUB 流初始化失败关闭已打开的文件', () async {
      final path = await buildEpub(await makeTempDir(), baseEpubFiles());
      final handle = _EpubTestHandle(File(path).openSync(), failLength: true);
      addTearDown(() {
        if (!handle.closed) handle.closeSync();
      });
      await IOOverrides.runZoned(
        () => expectLater(EpubPackage.open(path), throwsA(isA<StateError>())),
        createFile: (_) => _EpubTestFile(handle),
      );
      expect(handle.closed, isTrue);
    });

    test('EPUB 关闭失败保留原始错误并同步释放文件', () async {
      final files = baseEpubFiles()..remove('META-INF/container.xml');
      final path = await buildEpub(await makeTempDir(), files);
      final handle = _EpubTestHandle(File(path).openSync(), failClose: true);
      addTearDown(() {
        if (!handle.closed) handle.closeSync();
      });
      await IOOverrides.runZoned(
        () => expectLater(
          EpubPackage.open(path),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              '无效的 EPUB：缺少 META-INF/container.xml',
            ),
          ),
        ),
        createFile: (_) => _EpubTestFile(handle),
      );
      expect(handle.syncCloseCalled, isTrue);
      expect(handle.closed, isTrue);
    });

    test('解压前拒绝超大展开与符号链接条目', () async {
      final source = await buildEpub(await makeTempDir(), baseEpubFiles());
      final bytes = File(source).readAsBytesSync();
      final central = centralHeader(bytes);
      final nextCentral = centralHeader(bytes, central + 46);

      final oversized = List<int>.from(bytes);
      writeLe32(oversized, central + 24, epubMaxDecodedBytes ~/ 2 + 1);
      writeLe32(oversized, nextCentral + 24, epubMaxDecodedBytes ~/ 2 + 1);
      final oversizedPath = '${(await makeTempDir()).path}/oversized.epub';
      File(oversizedPath).writeAsBytesSync(oversized);
      await expectLater(
        EpubPackage.open(oversizedPath),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'EPUB 解压后大小超过上限',
          ),
        ),
      );

      final symlink = List<int>.from(bytes);
      writeLe16(symlink, central + 4, 0x0314);
      writeLe32(symlink, central + 38, 0xa0000000);
      final data = ByteData.sublistView(bytes);
      final localHeader = data.getUint32(central + 42, Endian.little);
      final payload =
          localHeader +
          30 +
          data.getUint16(localHeader + 26, Endian.little) +
          data.getUint16(localHeader + 28, Endian.little);
      writeLe16(symlink, localHeader + 6, 0);
      writeLe16(symlink, localHeader + 8, 0);
      writeLe32(symlink, central + 20, 1);
      writeLe32(symlink, central + 24, 1);
      symlink[payload] = 0xff;
      expect(() => ZipDecoder().decodeBytes(symlink), throwsFormatException);
      final symlinkPath = '${(await makeTempDir()).path}/symlink.epub';
      File(symlinkPath).writeAsBytesSync(symlink);
      await expectLater(
        EpubPackage.open(symlinkPath),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '不支持含符号链接的 EPUB',
          ),
        ),
      );
    });

    test('非 zip 随机字节抛 StateError', () async {
      final rnd = Random(42);
      final bytes = List<int>.generate(200, (_) => rnd.nextInt(256));
      bytes[0] = 0;
      final root = await makeTempDir();
      final p = '${root.path}/random.epub';
      File(p).writeAsBytesSync(bytes);
      await expectLater(() => EpubPackage.open(p), throwsA(isA<StateError>()));
    });

    test('畸形 OPF 抛 StateError', () async {
      final files = baseEpubFiles();
      files['OEBPS/content.opf'] = utf8.encode('<package><broken');
      final p = await buildEpub(await makeTempDir(), files);
      await expectLater(() => EpubPackage.open(p), throwsA(isA<StateError>()));
    });

    test('spine 跟随多级 fallback 链读取 XHTML', () async {
      final base = baseEpubFiles();
      final fallbackFiles = <String, List<int>>{
        'mimetype': base['mimetype']!,
        'META-INF/container.xml': base['META-INF/container.xml']!,
        'OEBPS/content.opf': utf8.encode(
          '<?xml version="1.0" encoding="utf-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>'
          '<manifest><item id="wrapped" href="wrapped.bin" media-type="application/octet-stream" fallback="middle"/>'
          '<item id="middle" href="missing.xhtml" media-type="application/xhtml+xml" fallback="ch1"/>'
          '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>'
          '<spine><itemref idref="wrapped"/></spine></package>',
        ),
        'OEBPS/wrapped.bin': const [1, 2, 3],
        'OEBPS/ch1.xhtml': xhtml('回退章节', '回退正文'),
      };
      final fallbackPkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), fallbackFiles),
      );
      try {
        expect(fallbackPkg.chapters.map((c) => c.href), ['OEBPS/ch1.xhtml']);
        expect((await fallbackPkg.chapterBlocks(0)).single.text, '回退正文');
      } finally {
        await fallbackPkg.close();
      }
    });

    test('spine 无效映射、缺失章节及 fallback 环路拒绝空包或丢章', () async {
      for (final spine in [
        '',
        '<spine/>',
        '<spine><itemref/></spine>',
        '<spine><itemref idref="unknown"/></spine>',
        '<spine><itemref idref="remote"/></spine>',
        '<spine><itemref idref="lost"/></spine>',
        '<spine><itemref idref="no-href"/></spine>',
        '<spine><itemref idref="cycle"/></spine>',
        '<spine><itemref idref="ch1"/><itemref idref="lost"/></spine>',
      ]) {
        final files = baseEpubFiles();
        files['OEBPS/content.opf'] = utf8.encode(
          utf8
              .decode(files['OEBPS/content.opf']!)
              .replaceFirst(RegExp(r'<spine\b.*?</spine>', dotAll: true), spine)
              .replaceFirst(
                '</manifest>',
                '<item id="remote" href="https://example.com/ch.xhtml" media-type="application/xhtml+xml"/>'
                    '<item id="lost" href="missing.xhtml" media-type="application/xhtml+xml"/>'
                    '<item id="no-href" media-type="application/xhtml+xml"/>'
                    '<item id="cycle" href="cycle.bin" media-type="application/octet-stream" fallback="cycle2"/>'
                    '<item id="cycle2" href="cycle2.bin" media-type="application/octet-stream" fallback="cycle"/></manifest>',
              ),
        );
        await expectLater(
          EpubPackage.open(await buildEpub(await makeTempDir(), files)),
          throwsA(isA<StateError>()),
          reason: spine,
        );
      }
    });

    test('UTF-16LE 与 UTF-16BE 章节按 BOM 解码', () async {
      for (final bigEndian in [false, true]) {
        final files = baseEpubFiles();
        final label = bigEndian ? 'BE' : 'LE';
        files['OEBPS/ch4.xhtml'] = utf16(
          '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
          '<head><title>UTF16标题 $label 📖</title></head>'
          '<body><p>UTF16正文 $label 📖</p><img src="pic.jpg"/></body></html>',
          bigEndian: bigEndian,
        );
        final pkg = await EpubPackage.open(
          await buildEpub(await makeTempDir(), files),
        );
        try {
          final blocks = await pkg.chapterBlocks(3);
          expect(pkg.chapters[3].title, 'UTF16标题 $label 📖');
          expect(blocks.map((block) => block.text ?? block.entryPath), [
            'UTF16正文 $label 📖',
            'OEBPS/pic.jpg',
          ]);
        } finally {
          await pkg.close();
        }
      }
    });

    test('CDATA 在 XML、降级正文与标题回退中保留原文', () async {
      final files = baseEpubFiles();
      files['OEBPS/toc.ncx'] = utf8.encode(
        '<?xml version="1.0"?><ncx><navMap/></ncx>',
      );
      files['OEBPS/ch1.xhtml'] = utf8.encode(
        '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
        '<body><p>前<![CDATA[A&nbsp;B <raw>]]>后</p></body></html>',
      );
      files['OEBPS/ch2.xhtml'] = utf8.encode(
        '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
        '<head><title><![CDATA[降级&nbsp;标题 <!--字面-->]]></title></head>'
        '<body><p>前<![CDATA[降级&nbsp;正文 <raw> <!--字面--> <head>字面</head> </body>]]>后</p>'
        '<p>普通&amp;实体&nbsp;尾</p></body></html><broken',
      );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        final normal = await pkg.chapterBlocks(0);
        expect(normal.map((b) => b.text).join(), contains('A&nbsp;B <raw>'));
        expect(pkg.chapters[1].title, '降级&nbsp;标题 <!--字面-->');
        final fallback = await pkg.chapterBlocks(1);
        expect(
          fallback.map((b) => b.text).join(),
          '前降级&nbsp;正文 <raw> <!--字面--> <head>字面</head> </body>后普通&实体 尾',
        );
      } finally {
        await pkg.close();
      }
    });

    test('降级标签识别尊重引号并只取真实 src 属性', () async {
      final files = baseEpubFiles()
        ..['OEBPS/real.jpg'] = const [1, 2, 3]
        ..['OEBPS/fake.jpg'] = const [4, 5, 6]
        ..['OEBPS/ch1.xhtml'] = utf8.encode(
          '<?xml version="1.0"?><html><body>'
          '<img alt="1 > 0" src="real.jpg">'
          '<img alt=" src=\'fake.jpg\' " src="real.jpg">'
          '<img src="%FF.jpg">'
          '</body></html><broken',
        );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        final blocks = await pkg.chapterBlocks(0);
        expect(
          blocks.where((block) => block.kind == EpubBlockKind.text),
          isEmpty,
        );
        final images = blocks
            .where((b) => b.kind == EpubBlockKind.image)
            .map((b) => b.entryPath)
            .toList();
        expect(images, ['OEBPS/real.jpg', 'OEBPS/real.jpg']);
      } finally {
        await pkg.close();
      }
    });

    test('降级先删除注释再截取 body', () async {
      final files = baseEpubFiles()
        ..['OEBPS/real.jpg'] = const [1, 2, 3]
        ..['OEBPS/fake.jpg'] = const [4, 5, 6]
        ..['OEBPS/ch1.xhtml'] = utf8.encode(
          '<!-- <body><img src="fake.jpg"></body> -->'
          '<body><img src="real.jpg"></body><broken',
        );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        final blocks = await pkg.chapterBlocks(0);
        expect(
          blocks
              .where((b) => b.kind == EpubBlockKind.image)
              .map((b) => b.entryPath),
          ['OEBPS/real.jpg'],
        );
        expect(blocks.where((b) => b.kind == EpubBlockKind.text), isEmpty);
      } finally {
        await pkg.close();
      }
    });

    test('降级嵌套 SVG 用深度计数并提取外层后续图片', () async {
      final files = baseEpubFiles()
        ..['OEBPS/a.jpg'] = const [1]
        ..['OEBPS/b.jpg'] = const [2]
        ..['OEBPS/ch1.xhtml'] = utf8.encode(
          '<body><svg><svg/><image href="b.jpg"/>'
          '<svg><image href="a.jpg"/></svg><svg/>'
          '<image href="b.jpg"/></svg><p>SVG之后</p></body><broken',
        );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        expect(
          (await pkg.chapterBlocks(0))
              .where((b) => b.kind == EpubBlockKind.image)
              .map((b) => b.entryPath),
          ['OEBPS/b.jpg', 'OEBPS/a.jpg', 'OEBPS/b.jpg'],
        );
        expect((await pkg.chapterBlocks(0)).last.text, 'SVG之后');
      } finally {
        await pkg.close();
      }
    });

    test('SVG 同时存在 xlink href 时优先无前缀 href', () async {
      final files = baseEpubFiles()
        ..['OEBPS/old.jpg'] = const [1]
        ..['OEBPS/new.jpg'] = const [2]
        ..['OEBPS/ch1.xhtml'] = utf8.encode(
          '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
          '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
          '<image xlink:href="old.jpg" href="new.jpg"/></svg></body></html>',
        )
        ..['OEBPS/ch2.xhtml'] = utf8.encode(
          '<body><svg xmlns:xlink="http://www.w3.org/1999/xlink">'
          '<image xlink:href="old.jpg" href="new.jpg"/></svg></body><broken',
        );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        for (final index in [0, 1]) {
          expect(
            (await pkg.chapterBlocks(index))
                .where((b) => b.kind == EpubBlockKind.image)
                .map((b) => b.entryPath),
            ['OEBPS/new.jpg'],
          );
        }
      } finally {
        await pkg.close();
      }
    });

    test('标题回退先去注释并识别带前缀的 title、h1、head、body', () async {
      final files = baseEpubFiles()
        ..['OEBPS/ch3.xhtml'] = utf8.encode(
          '<!-- <x:title>旧标题</x:title> -->'
          '<x:html xmlns:x="http://www.w3.org/1999/xhtml"><x:head><x:title>真标题</x:title></x:head>'
          '<x:body><p>正文</p></x:body></x:html><broken',
        )
        ..['OEBPS/ch4.xhtml'] = utf8.encode(
          '<!-- <h1>旧标题</h1> -->'
          '<x:html xmlns:x="http://www.w3.org/1999/xhtml">'
          '<x:head><x:p>隐藏内容</x:p></x:head>'
          '<x:h1>真章名</x:h1><x:p>无 body 正文</x:p></x:html><broken>',
        );
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      try {
        expect(pkg.chapters[2].title, '真标题');
        final blocks = await pkg.chapterBlocks(2);
        expect(blocks.map((b) => b.text).join(), '正文');
        expect(pkg.chapters[3].title, '真章名');
        expect((await pkg.chapterBlocks(3)).map((block) => block.text), [
          '真章名',
          '无 body 正文',
        ]);
      } finally {
        await pkg.close();
      }
    });

    test('spine linear="no" 的章节被跳过', () async {
      final basePkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), baseEpubFiles()),
      );
      final baseHrefs = basePkg.chapters.map((c) => c.href).toList();
      await basePkg.close();

      final files = baseEpubFiles();
      final opf = utf8.decode(files['OEBPS/content.opf']!);
      final re = RegExp(r'(<itemref\b[^>]*\bidref="ch2")');
      expect(re.hasMatch(opf), isTrue);
      files['OEBPS/content.opf'] = utf8.encode(
        opf.replaceFirstMapped(re, (m) => '${m[1]} linear="no"'),
      );

      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      final hrefs = pkg.chapters.map((c) => c.href).toList();
      await pkg.close();

      expect(hrefs.any((h) => h.endsWith('ch2.xhtml')), isFalse);
      expect(hrefs, baseHrefs.where((h) => !h.endsWith('ch2.xhtml')).toList());
    });

    test('无 NCX 时标题取自 nav 的 toc', () async {
      final base = baseEpubFiles();
      final files = <String, List<int>>{
        'mimetype': base['mimetype']!,
        'META-INF/container.xml': base['META-INF/container.xml']!,
        'OEBPS/content.opf': utf8.encode(
          '<?xml version="1.0" encoding="utf-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:identifier id="id">nav-only</dc:identifier><dc:title>T</dc:title></metadata>'
          '<manifest>'
          '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
          '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest>'
          '<spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>'
          '</package>',
        ),
        'OEBPS/nav.xhtml': navDoc('第一章'),
        'OEBPS/ch1.xhtml': xhtml('文件标题一', '一'),
        'OEBPS/ch2.xhtml': xhtml('文件标题二', '二'),
      };
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      final titles = pkg.chapters.map((c) => c.title).toList();
      await pkg.close();
      expect(titles, ['第一章', '第二章']);
    });

    test('NCX 已有标题不被 nav 覆盖，缺失的由 nav 补', () async {
      final base = baseEpubFiles();
      final files = <String, List<int>>{
        'mimetype': base['mimetype']!,
        'META-INF/container.xml': base['META-INF/container.xml']!,
        'OEBPS/content.opf': utf8.encode(
          '<?xml version="1.0" encoding="utf-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:identifier id="id">ncx-nav</dc:identifier><dc:title>T</dc:title></metadata>'
          '<manifest>'
          '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
          '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
          '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest>'
          '<spine toc="ncx"><itemref idref="ch1"/><itemref idref="ch2"/></spine>'
          '</package>',
        ),
        'OEBPS/toc.ncx': utf8.encode(
          '<?xml version="1.0" encoding="utf-8"?>'
          '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
          '<head/><docTitle><text>T</text></docTitle><navMap>'
          '<navPoint id="p1" playOrder="1"><navLabel><text>NCX第一章</text></navLabel>'
          '<content src="ch1.xhtml"/></navPoint>'
          '</navMap></ncx>',
        ),
        'OEBPS/nav.xhtml': navDoc('NAV第一章'),
        'OEBPS/ch1.xhtml': xhtml('文件标题一', '一'),
        'OEBPS/ch2.xhtml': xhtml('文件标题二', '二'),
      };
      final pkg = await EpubPackage.open(
        await buildEpub(await makeTempDir(), files),
      );
      final titles = pkg.chapters.map((c) => c.title).toList();
      await pkg.close();
      expect(titles, ['NCX第一章', '第二章']);
    });
  });
}
