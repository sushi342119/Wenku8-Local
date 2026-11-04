/// File imports stream TXT and EPUB entries off the UI isolate.
const maxLocalTextBytes = 128 * 1024 * 1024;
const maxLocalEpubBytes = 512 * 1024 * 1024;
const maxLocalArchiveBytes = 512 * 1024 * 1024;
const bookFormatLabels = <String, String>{
  'epub': 'EPUB',
  'txt': 'TXT',
  'kindle': 'Kindle',
  'pdf': 'PDF',
  'fb2': 'FB2',
  'docx': 'DOCX',
  'doc': 'DOC',
  'rtf': 'RTF',
  'html': 'HTML',
  'markdown': 'Markdown',
  'zip': 'ZIP',
};
String bookFormatKey(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'mobi' || 'azw' || 'azw3' || 'prc' => 'kindle',
      'html' || 'htm' || 'xhtml' => 'html',
      'md' || 'markdown' => 'markdown',
      final value => value,
    };
Set<String> bookFormatExtensions(Iterable<String> formats) => {
  for (final format in formats)
    ...switch (format) {
      'kindle' => ['mobi', 'azw', 'azw3', 'prc'],
      'html' => ['html', 'htm', 'xhtml'],
      'markdown' => ['md', 'markdown'],
      _ => [format],
    },
};
const bookImportFormatsSummary =
    'TXT、EPUB、Kindle（MOBI / AZW / AZW3 / PRC）、FB2、PDF、DOC / DOCX、RTF、HTML 和 Markdown，支持 ZIP 批量导入';
const iosBookImportFormatsSummary =
    'TXT、EPUB、Kindle（MOBI / AZW / AZW3 / PRC）、FB2、PDF、DOCX、RTF、HTML 和 Markdown，支持 ZIP 批量导入';
const bookImportLimitsSummary =
    'EPUB / PDF / DOCX / ZIP：512 MiB；Kindle：256 MiB；TXT / FB2 / RTF / DOC：128 MiB；HTML / Markdown：32 MiB。ZIP 展开后合计不超过 1 GiB。';
const iosBookImportLimitsSummary =
    'EPUB / PDF / DOCX / ZIP：512 MiB；Kindle：256 MiB；TXT / FB2 / RTF：128 MiB；HTML / Markdown：32 MiB。ZIP 展开后合计不超过 1 GiB。';

bool supportsBookImport(String name) => RegExp(
  r'\.(txt|epub|mobi|azw|azw3|prc|fb2|pdf|docx?|rtf|html?|xhtml|md|markdown|zip)$',
  caseSensitive: false,
).hasMatch(name);

int localBookByteLimit(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'zip' => maxLocalArchiveBytes,
      'epub' || 'pdf' || 'docx' => maxLocalEpubBytes,
      'mobi' || 'azw' || 'azw3' || 'prc' => 256 * 1024 * 1024,
      'html' || 'htm' || 'xhtml' || 'md' || 'markdown' => 32 * 1024 * 1024,
      _ => maxLocalTextBytes,
    };

String localBookSizeMessage(String name) =>
    '单个 ${name.split('.').last.toUpperCase()} 不能超过 ${localBookByteLimit(name) ~/ (1024 * 1024)} MiB';
