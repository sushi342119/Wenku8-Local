import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/chapter_splitter.dart';
import 'package:wenku8_flutter/file_text_anchor.dart';
import 'package:wenku8_flutter/text_anchor.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('file-text-anchor-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'streamed anchors match string anchors across edits and repeated passages',
    () async {
      final padding = '甲😀乙。' * 200000;
      final passage = '独特定位段落保留阅读上下文。' * 15;
      final oldText = '$padding\n\n$passage\n\n$padding';
      final oldFile = await File('${root.path}/old.txt').writeAsString(oldText);
      final old = await FileTextAnchor.open(oldFile.path);
      for (final newText in [
        '前方新增段落。\n$oldText',
        '$padding\n\n${passage.substring(100)}\n\n$padding',
        '$passage\n$padding\n\n$passage\n\n$padding',
      ]) {
        final newFile = await File(
          '${root.path}/new.txt',
        ).writeAsString(newText);
        final updated = await FileTextAnchor.open(newFile.path);
        for (final offset in [
          0,
          65530,
          padding.length + 30,
          padding.length + 150,
          oldText.length,
        ]) {
          expect(
            await updated.relocateFrom(old, offset),
            relocateTextOffset(oldText, newText, offset),
          );
        }
      }
      expect(await old.relocateFrom(old, 12345), 12345);
      expect(await old.slice(65520, 65680), oldText.substring(65520, 65680));
    },
  );

  test(
    'streamed chapter location preserves trimmed paragraphs and bounded reads',
    () async {
      final prefix = '前文😀。' * 200000;
      const body = '  段落甲\n\n段落乙😀\n\n段落丙  ';
      final text = '$prefix$body';
      final file = await File('${root.path}/text.txt').writeAsString(text);
      final anchors = await FileTextAnchor.open(file.path);
      final chapters = [
        LocalChapterIndex('前章', 0, prefix.length),
        LocalChapterIndex('目标章', prefix.length, body.length),
      ];
      for (final offset in [prefix.length, prefix.length + 10, text.length]) {
        expect(
          await anchors.locate(chapters, offset),
          locateTextAnchor(text, chapters, offset),
        );
      }
      final large = await File(
        '${root.path}/large.txt',
      ).open(mode: FileMode.write);
      final block = '甲' * 65536;
      for (var chunk = 0; chunk < 65; chunk++) {
        await large.writeString(block);
      }
      await large.close();
      final bounded = await FileTextAnchor.open('${root.path}/large.txt');
      await expectLater(
        bounded.slice(0, bounded.length),
        throwsFormatException,
      );
    },
  );
}
