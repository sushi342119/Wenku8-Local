import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

typedef PreparedBookDocument = ({String name, String? path, String? error});
typedef PreparedCloudBook = ({String name, Uint8List? epubBytes, String? text});

class PortableBookPreparer {
  PortableBookPreparer({
    required this.directory,
    required this.textCodecToken,
    required this.decodeNames,
    required this.convert,
    required this.extractKindle,
    this.extractPdf,
  });

  final Directory directory;
  final RootIsolateToken textCodecToken;
  final Future<List<String>> Function(List<List<int>> names) decodeNames;
  final Future<List<PreparedBookDocument>> Function(String name, String path)
  convert;
  final Future<int> Function(String source, String output) extractKindle;
  final Future<void> Function(String name, String source, String output)?
  extractPdf;

  static Future<void> clearPreviousRuns(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException catch (_) {}
  }

  Future<List<PreparedBookDocument>> prepare(String name, String path) =>
      convert(name, path);

  Future<void> releasePaths(Iterable<String> paths) async {}

  static Future<List<PreparedCloudBook>> prepareFile(
    String name,
    String path,
  ) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final bytes = await File(path).readAsBytes();
    return _prepareBytes(name, ext, bytes);
  }

  static List<PreparedCloudBook> _prepareBytes(
    String name,
    String ext,
    Uint8List bytes,
  ) {
    switch (ext) {
      case 'epub':
        return [(name: name, epubBytes: bytes, text: null)];
      case 'txt':
      case 'md':
      case 'markdown':
        return [
          (
            name: name,
            epubBytes: null,
            text: utf8.decode(bytes, allowMalformed: true),
          ),
        ];
      case 'html':
      case 'htm':
      case 'xhtml':
        final doc = html_parser.parse(utf8.decode(bytes, allowMalformed: true));
        return [
          (name: name, epubBytes: null, text: doc.body?.text ?? doc.text ?? ''),
        ];
      case 'fb2':
        try {
          final xml = XmlDocument.parse(
            utf8.decode(bytes, allowMalformed: true),
          );
          final paragraphs = xml
              .findAllElements('p')
              .map((e) => e.innerText.trim())
              .where((s) => s.isNotEmpty)
              .join('\n\n');
          return [(name: name, epubBytes: null, text: paragraphs)];
        } catch (_) {
          return [
            (
              name: name,
              epubBytes: null,
              text: utf8.decode(bytes, allowMalformed: true),
            ),
          ];
        }
      case 'docx':
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          final docEntry = archive.findFile('word/document.xml');
          if (docEntry == null) return const [];
          final xml = XmlDocument.parse(
            utf8.decode(docEntry.content as List<int>, allowMalformed: true),
          );
          final lines = <String>[];
          for (final p in xml.descendants.whereType<XmlElement>().where(
            (e) => e.name.local == 'p',
          )) {
            final line = p.descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 't')
                .map((e) => e.innerText)
                .join()
                .trim();
            if (line.isNotEmpty) lines.add(line);
          }
          return [(name: name, epubBytes: null, text: lines.join('\n\n'))];
        } catch (_) {
          return const [];
        }
      case 'rtf':
        final raw = latin1.decode(bytes, allowInvalid: true);
        final stripped = raw
            .replaceAll(RegExp(r'\\par\b\s*'), '\n')
            .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d*\s?'), '')
            .replaceAll(RegExp(r'[{}]'), '');
        return [(name: name, epubBytes: null, text: stripped.trim())];
      case 'zip':
        try {
          final archive = ZipDecoder().decodeBytes(bytes);
          final results = <PreparedCloudBook>[];
          for (final entry in archive) {
            if (!entry.isFile) continue;
            final entryName = entry.name.split('/').last;
            if (entryName.isEmpty || entryName.startsWith('.')) continue;
            final entryExt = entryName.contains('.')
                ? entryName.split('.').last.toLowerCase()
                : '';
            if (entryExt == 'zip') continue;
            final entryBytes = entry.readBytes();
            if (entryBytes == null) continue;
            results.addAll(_prepareBytes(entryName, entryExt, entryBytes));
          }
          return results;
        } catch (_) {
          return const [];
        }
      default:
        return [
          (
            name: name,
            epubBytes: null,
            text: utf8.decode(bytes, allowMalformed: true),
          ),
        ];
    }
  }
}
