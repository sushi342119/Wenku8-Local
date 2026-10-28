import 'dart:convert';
import 'dart:io';
import 'package:wenku8_flutter/chapter_splitter.dart';

final legacy = RegExp(
  r'^[ \t　【\[（(]{0,32}(第[一二三四五六七八九十百千零〇两\d０-９ \t　]+[章节回集卷部篇话幕]|卷[一二三四五六七八九十百千零〇两\d０-９]+|Chapter[ \t]*\d+|序章|序曲|楔子|终章|终曲|番外(?:[ \t]*\d+)?|后记|前言|引子|尾声)[^\n]{0,40}$',
  multiLine: true,
);
final whitespace = RegExp(r'\s', unicode: true);
int words(String s) => s.replaceAll(whitespace, '').runes.length;
List<LocalChapterIndex> before(String text) {
  final matches = legacy
      .allMatches(text)
      .where((m) => m.group(0)!.trim().length <= 64)
      .toList();
  if (matches.length < 2) return [LocalChapterIndex('正文', 0, text.length)];
  return [
    for (var i = 0; i < matches.length; i++)
      LocalChapterIndex(
        matches[i].group(0)!.trim(),
        text.indexOf('\n', matches[i].end) < 0
            ? text.length
            : text.indexOf('\n', matches[i].end) + 1,
        (i + 1 < matches.length ? matches[i + 1].start : text.length) -
            (text.indexOf('\n', matches[i].end) < 0
                ? text.length
                : text.indexOf('\n', matches[i].end) + 1),
      ),
  ];
}

Map<String, Object> measure(
  String text,
  List<LocalChapterIndex> chapters, {
  bool old = false,
}) {
  final sizes = [
    for (final c in chapters)
      words(text.substring(c.offset, c.offset + c.length)),
  ];
  // Measure the actual uncovered prefix. A chapter's header is metadata, so
  // exclude its own line; an inline body starts midway through that same line.
  final firstOffset = chapters.first.offset;
  final firstHeading = old && chapters.first.title != '正文'
      ? legacy.firstMatch(text)?.start ?? 0
      : firstOffset == 0 ? 0 : text.lastIndexOf('\n',
          (firstOffset - (text[firstOffset - 1] == '\n' ? 2 : 1)).clamp(0, text.length - 1)) + 1;
  var biggest = 0;
  for (var i = 1; i < sizes.length; i++) {
    if (sizes[i] > sizes[biggest]) biggest = i;
  }
  return {
    'chapters': chapters.length,
    'maxWords': sizes[biggest],
    'maxTitle': chapters[biggest].title,
    'over50k': sizes.where((v) => v > 50000).length,
    'over100k': sizes.where((v) => v > 100000).length,
    'wholeBody': chapters.length == 1 && chapters.first.title == '正文',
    'empty': sizes.where((v) => v == 0).length,
    'openingOmitted': words(text.substring(0, firstHeading)),
    'valid': validChapterRanges(chapters, text.length),
  };
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError(
      'usage: dart tool/chapter_corpus_audit.dart READ_ONLY_CORPUS OUTPUT.json',
    );
  }
  final files =
      Directory(args[0]).listSync(recursive: true).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final rows = <Map<String, Object>>[];
  var malformed = 0;
  for (final f in files.where((f) => f.path.toLowerCase().endsWith('.txt'))) {
    final bytes = await f.readAsBytes();
    String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      malformed++;
      final decode = await Process.run('python3', [
        '-c',
        'import sys; b=open(sys.argv[1],"rb").read();\ntry:t=b.decode("gb18030")\nexcept UnicodeError:t=b.decode("utf-8",errors="replace")\nsys.stdout.buffer.write(t.encode("utf-8"))',
        f.path,
      ]);
      if (decode.exitCode != 0) throw StateError(decode.stderr);
      source = decode.stdout as String;
    }
    final old = source
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final text = normalizeLocalText(source);
    rows.add({
      'file': f.path.substring(args[0].length),
      'before': measure(old, before(old), old: true),
      'after': measure(text, splitLocalChapters(text)),
    });
    if (rows.length % 100 == 0) stdout.writeln('Audited ${rows.length} TXT');
  }
  Map<String, int> totals(String version) {
    final ms = rows.map((r) => r[version] as Map<String, Object>).toList();
    return {
      'over50kBooks': ms.where((r) => (r['over50k'] as int) > 0).length,
      'over50kChapters': ms.fold(0, (n, r) => n + (r['over50k'] as int)),
      'over100kBooks': ms.where((r) => (r['over100k'] as int) > 0).length,
      'wholeBodyBooks': ms.where((r) => r['wholeBody'] == true).length,
      'emptyBooks': ms.where((r) => (r['empty'] as int) > 0).length,
      'emptyChapters': ms.fold(0, (n, r) => n + (r['empty'] as int)),
      'openingOmittedOver50k': ms
          .where((r) => (r['openingOmitted'] as int) > 50000)
          .length,
      'invalidRanges': ms.where((r) => r['valid'] == false).length,
    };
  }

  final worst = List.of(rows)
    ..sort(
      (a, b) => ((b['after'] as Map)['maxWords'] as int).compareTo(
        (a['after'] as Map)['maxWords'] as int,
      ),
    );
  final report = {
    'files': files.length,
    'txt': rows.length,
    'malformedUtf8': malformed,
    'before': totals('before'),
    'after': totals('after'),
    'worst5': worst.take(5).toList(),
    'books': rows,
  };
  await File(
    args[1],
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode({...report}..remove('books')));
}
