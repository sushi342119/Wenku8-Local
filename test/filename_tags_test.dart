import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/filename_tags.dart';
import 'package:wenku8_flutter/local_library.dart';

void main() {
  test('parses only final consecutive tags and preserves extension case', () {
    final parsed = parseFilenameTags('《仙绿》星河渐晓 ✦古风 ✦已读.TxT');
    expect(parsed.baseFilename, '《仙绿》星河渐晓.TxT');
    expect(parsed.tags, ['古风', '已读']);
    expect(stripFilenameTags('书 ✦甲 ✦乙.pdf'), '书.pdf');
    expect(parseFilenameTags('书 ✦甲').tags, ['甲']);
  });

  for (final filename in [
    '书.txt',
    '书 #已读【下载】(完结).txt',
    '书✦标签.txt',
    '书 ✦.txt',
    '书 ✦甲 ✦.txt',
    '书 ✦甲 乙.txt',
    '书 ✦甲 .txt',
    '书 ✦甲\t乙.txt',
    '书 ✦甲\u3000乙.txt',
    '书 ✦甲\u0085乙.txt',
    '书 ✦甲✦乙.txt',
    '书 ✦甲 后记.txt',
    '',
    '.txt',
    '书.第一版.TXT',
  ]) {
    test('does not strip ordinary/invalid filename: $filename', () {
      expect(stripFilenameTags(filename), filename);
      expect(parseFilenameTags(filename).tags, isEmpty);
      expect(appendFilenameTags(filename, []), filename);
    });
  }

  test('earlier invalid segment stops suffix parsing without eating title', () {
    final parsed = parseFilenameTags('书 ✦非 标签 ✦古风 ✦已读.txt');
    expect(parsed.baseFilename, '书 ✦非 标签.txt');
    expect(parsed.tags, ['古风', '已读']);
  });

  test(
    'append merges in order, deduplicates, clears via stripped filename',
    () {
      expect(
        appendFilenameTags('书 #【】().TXT', ['古风', '已读', '古风']),
        '书 #【】() ✦古风 ✦已读.TXT',
      );
      expect(appendFilenameTags('书 ✦古风.txt', ['古风', '已读']), '书 ✦古风 ✦已读.txt');
      expect(appendFilenameTags('书 ✦甲 ✦甲.txt', []), '书 ✦甲 ✦甲.txt');
      expect(appendFilenameTags(stripFilenameTags('书 ✦甲.txt'), []), '书.txt');
      expect(appendFilenameTags('无扩展名', ['已读']), '无扩展名 ✦已读');
      expect(parseFilenameTags(appendFilenameTags('书.txt', ['v1.2'])).tags, [
        'v1.2',
      ]);
    },
  );

  test('append rejects empty tags, all whitespace and reserved marker', () {
    for (final name in [
      '',
      ' ',
      '古 风',
      '古\t风',
      '古\n风',
      '古\u00a0风',
      '古\u0085风',
      '古\u2009风',
      '古\u3000风',
      ' 古风',
      '古风 ',
      '✦',
      '古✦风',
    ]) {
      expect(() => appendFilenameTags('书.txt', [name]), throwsArgumentError);
    }
  });

  test('title/author parsing retains download markers and drops only tags', () {
    for (final stem in ['《仙绿》星河渐晓', '书 #已读【精校版】(下载)', '【网站】书(完结)#']) {
      expect(LocalLibraryStore.titleFromNameForTest('$stem ✦古风.txt'), stem);
    }
    expect(LocalLibraryStore.titleFromNameForTest('书 - 作者 ✦已读.txt'), '书');
    expect(LocalLibraryStore.authorFromNameForTest('书 - 作者 ✦已读.txt'), '作者');
    expect(
      LocalLibraryStore.safeFileNameForTitle('书 ✦古风.TxT', '新书'),
      '新书 ✦古风.TxT',
    );
  });
}
