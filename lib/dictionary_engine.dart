import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dict_reader/dict_reader.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'dictionary_models.dart';
import 'dictionary_mobi.dart';
import 'dictionary_stardict.dart';
import 'dictionary_validation.dart';

const dictionaryIndexMaxBytes = 64 * 1024 * 1024;
const _definitionMaxBytes = 2 * 1024 * 1024;

/// Builds once, beside the private source. Reopening imports this index instead
/// of decompressing/scanning the entire source dictionary again.
Future<(int entries, String title)> buildDictionaryIndex(String path) async {
  await validateMdictFile(path);
  final reader = DictReader(path);
  try {
    await reader.initDict();
    final cache = await reader.exportCacheAsString();
    if (cache.length * 2 > dictionaryIndexMaxBytes) {
      throw const FormatException('词典索引超过 64 MiB，暂不能导入');
    }
    final index = File('$path.index');
    await index.writeAsString(cache, flush: true);
    if (await index.length() > dictionaryIndexMaxBytes) {
      throw const FormatException('词典索引超过 64 MiB，暂不能导入');
    }
    final title = (html.parseFragment(reader.header['Title'] ?? '').text ?? '')
        .trim();
    return (reader.numEntries, title);
  } finally {
    await reader.close();
  }
}

/// A single background worker owns file readers and a bounded two-reader LRU.
/// No parsing, decompression or full index sorting runs on the Flutter isolate.
class DictionaryEngine {
  Isolate? _isolate;
  ReceivePort? _messages, _failures;
  SendPort? _port;
  Future<void>? _starting;
  final _pending = <int, Completer<Object?>>{};
  final _sessions = <int, int>{};
  int _nextSession = 0;
  int _nextId = 0;
  bool _disposed = false;

  int createSession() {
    final id = ++_nextSession;
    _sessions[id] = 0;
    return id;
  }

  int get activeSessionCount => _sessions.length;

  bool _stale(String action, Object? payload) =>
      action == 'lookup' &&
      payload is Map &&
      payload['session'] is int &&
      (_sessions[payload['session']] == null ||
          (payload['generation'] as int) < _sessions[payload['session']]!);

  Future<void> _start() => _starting ??= () async {
    if (_disposed) throw StateError('词典已关闭');
    final ready = Completer<void>();
    final messages = _messages = ReceivePort();
    final failures = _failures = ReceivePort();
    messages.listen((message) {
      if (message is SendPort) {
        _port = message;
        ready.complete();
      } else if (message is List && message.length == 3) {
        final request = _pending.remove(message[0]);
        if (request == null) return;
        if (message[1] == true) {
          request.complete(message[2]);
        } else {
          request.completeError(FormatException(message[2] as String));
        }
      }
    });
    failures.listen((_) {
      final error = const FormatException('词典解析已中断，请关闭弹窗后重试');
      if (!ready.isCompleted) ready.completeError(error);
      for (final value in _pending.values) {
        value.completeError(error);
      }
      _pending.clear();
      _isolate?.kill();
      _isolate = null;
      _port = null;
      _starting = null;
      messages.close();
      failures.close();
    });
    _isolate = await Isolate.spawn(
      _dictionaryWorker,
      messages.sendPort,
      onError: failures.sendPort,
      onExit: failures.sendPort,
    );
    await ready.future;
  }();

  Future<Object?> _request(String action, Object? payload) async {
    if (_stale(action, payload)) return <Object>[];
    await _start();
    if (_disposed) throw StateError('词典已关闭');
    if (_stale(action, payload)) return <Object>[];
    final id = ++_nextId;
    final result = Completer<Object?>();
    _pending[id] = result;
    _port!.send([id, action, payload]);
    return result.future;
  }

  Future<List<DictionaryDefinition>> lookup(
    String query,
    Map<String, Object> source, {
    int? session,
    int generation = 0,
  }) async {
    if (session != null) {
      final current = _sessions[session];
      if (current == null || generation < current) return const [];
      _sessions[session] = generation;
    }
    final payload = <String, Object>{
      'query': query,
      ...source,
      'generation': generation,
    };
    if (session != null) {
      payload['session'] = session;
    }
    final raw = await _request('lookup', payload) as List;
    if (_stale('lookup', payload)) return const [];
    return raw
        .map((item) {
          final value = item as Map;
          return DictionaryDefinition(
            value['word'] as String,
            value['text'] as String,
            images: List<Uint8List>.from(value['images'] as List),
            related: List<String>.from(value['related'] as List),
            resourceWarning: value['resourceWarning'] == true,
          );
        })
        .toList(growable: false);
  }

  Future<void> drop(List<String> paths) async {
    if (_port != null) await _request('drop', paths);
  }

  Future<void> cancelSession(int session) async {
    if (_sessions.remove(session) == null) return;
    if (_port != null) await _request('cancel', session);
  }

  void dispose() {
    _disposed = true;
    _isolate?.kill();
    _messages?.close();
    _failures?.close();
    for (final value in _pending.values) {
      value.completeError(StateError('词典已关闭'));
    }
    _pending.clear();
    _sessions.clear();
  }
}

void _dictionaryWorker(SendPort main) {
  final commands = ReceivePort();
  final readers = <String, DictReader>{};
  final starReaders = <String, StarDictReader>{};
  final mobiReaders = <String, MobiDictionaryReader>{};
  final order = <String>[];
  final latest = <int, int>{};
  Future<void> pending = Future.value();
  main.send(commands.sendPort);

  Future<void> touch(String path) async {
    order.remove(path);
    order.add(path);
    while (order.length > 2) {
      final oldest = order.removeAt(0);
      await readers.remove(oldest)?.close();
      await starReaders.remove(oldest)?.close();
      await mobiReaders.remove(oldest)?.close();
    }
  }

  Future<DictReader> open(String path) async {
    if (readers.remove(path) case final DictReader existing) {
      readers[path] = existing;
      await touch(path);
      return existing;
    }
    final reader = DictReader(path);
    try {
      final index = File('$path.index');
      if (!await index.exists()) {
        throw const FormatException('离线索引缺失，请重新导入这部词典');
      }
      if (await index.length() > dictionaryIndexMaxBytes) {
        throw const FormatException('词典索引过大，请重新导入');
      }
      await reader.importCacheFromString(await index.readAsString());
      readers[path] = reader;
      await touch(path);
      return reader;
    } catch (_) {
      await reader.close();
      rethrow;
    }
  }

  commands.listen((message) {
    if (message is! List || message.length != 3) return;
    final id = message[0], action = message[1], payload = message[2];
    if (action == 'lookup' && payload is Map && payload['session'] is int) {
      final session = payload['session'] as int;
      final generation = payload['generation'] as int;
      if (generation > (latest[session] ?? -1)) latest[session] = generation;
    } else if (action == 'cancel' && payload is int) {
      latest[payload] = 0x7fffffffffffffff;
    }
    pending = pending.then((_) async {
      try {
        if (action == 'cancel') {
          // This same-port marker follows all older jobs. Closed sessions
          // cannot enqueue a later lookup from the main isolate.
          latest.remove(payload);
          main.send([id, true, null]);
          return;
        }
        if (action == 'drop') {
          for (final path in payload as List) {
            order.remove(path);
            await readers.remove(path)?.close();
            await starReaders.remove(path)?.close();
            await mobiReaders.remove(path)?.close();
          }
          main.send([id, true, null]);
          return;
        }
        final job = payload as Map;
        if (job['session'] is int &&
            job['generation'] < latest[job['session']]!) {
          main.send([id, true, <Object>[]]);
          return;
        }
        final path = job['path'] as String;
        final query = job['query'] as String;
        final resources = List<String>.from(job['resources'] as List);
        final records = <(String, String)>[];
        if (job['format'] == 'stardict') {
          var reader = starReaders.remove(path);
          reader ??= await StarDictReader.open(path);
          starReaders[path] = reader;
          await touch(path);
          var values = await reader.lookup(query);
          if (values.isEmpty && query.toLowerCase() != query) {
            values = await reader.lookup(query.toLowerCase());
          }
          for (final value in values.take(8)) {
            records.add((query, value));
          }
        } else if (job['format'] == 'mobi') {
          var reader = mobiReaders.remove(path);
          reader ??= await MobiDictionaryReader.open(path);
          mobiReaders[path] = reader;
          await touch(path);
          records.addAll((await reader.lookup(query)).take(8));
        } else {
          final reader = await open(path);
          var offsets = await reader.locateAll(query);
          if (offsets.isEmpty && query.toLowerCase() != query) {
            offsets = await reader.locateAll(query.toLowerCase());
          }
          for (final offset in offsets.take(8)) {
            var current = offset;
            var word = query;
            final visited = <String>{query};
            var raw = '';
            for (var link = 0; link < 8; link++) {
              _checkRecordLength(current, _definitionMaxBytes);
              raw = (await reader.readOneMdx(current)).trim();
              if (!raw.startsWith('@@@LINK=')) break;
              word = raw.substring(8).trim();
              if (!visited.add(word)) {
                throw const FormatException('词条链接循环，无法读取');
              }
              final target = await reader.locate(word);
              if (target == null) throw const FormatException('词条指向的内容不存在');
              current = target;
            }
            if (raw.startsWith('@@@LINK=')) {
              throw const FormatException('词条链接层级过多');
            }
            records.add((word, raw));
          }
        }
        final definitions = <Map<String, Object>>[];
        for (final (word, raw) in records) {
          final fragment = html.parseFragment(raw);
          for (final unsafe in fragment.querySelectorAll(
            'script,style,iframe,object,embed,form,noscript',
          )) {
            unsafe.remove();
          }
          final imageKeys = fragment
              .querySelectorAll('img')
              .map((element) => _resourceKey(element.attributes['src'] ?? ''))
              .whereType<String>()
              .toSet()
              .take(6);
          final images = <Uint8List>[];
          var imageBytes = 0;
          for (final key in imageKeys) {
            for (final resource in resources) {
              try {
                final mdd = await open(resource);
                final found =
                    await mdd.locate(key) ??
                    await mdd.locate(key.replaceAll('\\', '/'));
                if (found == null) continue;
                _checkRecordLength(found, 8 * 1024 * 1024);
                final bytes = Uint8List.fromList(await mdd.readOneMdd(found));
                imageBytes += bytes.length;
                if (imageBytes > 16 * 1024 * 1024) break;
                images.add(bytes);
                break;
              } catch (_) {
                // A missing/broken resource pack must not hide the definition.
              }
            }
            if (imageBytes > 16 * 1024 * 1024) break;
          }
          final related = fragment
              .querySelectorAll('a')
              .map((a) => a.attributes['href'] ?? '')
              .where((href) => href.startsWith('entry://'))
              .map((href) => Uri.decodeComponent(href.substring(8)).trim())
              .where((word) => word.isNotEmpty && word.runes.length <= 128)
              .toSet()
              .take(12)
              .toList();
          definitions.add({
            'word': word,
            'text': _definitionText(fragment),
            'images': images,
            'related': related,
            'resourceWarning':
                imageKeys.length > images.length ||
                (job['format'] == 'mobi' &&
                    fragment.querySelectorAll('img').isNotEmpty),
          });
        }
        main.send([id, true, definitions]);
      } catch (error) {
        main.send([
          id,
          false,
          error is FormatException
              ? error.message
              : error is UnsupportedError
              ? error.message
              : '这部词典未能读取，请重新导入后重试',
        ]);
      }
    });
  });
}

void _checkRecordLength(RecordOffsetInfo record, int maximum) {
  final length = record.segments.isEmpty
      ? record.endOffset - record.startOffset
      : record.segments.fold<int>(
          0,
          (sum, segment) => sum + segment.$3 - segment.$2,
        );
  if (length < 0 || length > maximum) {
    throw const FormatException('该词条内容过大，无法显示');
  }
}

String? _resourceKey(String source) {
  final value = source.replaceAll('\\', '/');
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final parts = uri.pathSegments;
  if (parts.any((part) => part == '..' || part == '.')) return null;
  final path = parts.where((part) => part.isNotEmpty).join('\\');
  if (!RegExp(
    r'\.(png|jpe?g|gif|webp)$',
    caseSensitive: false,
  ).hasMatch(path)) {
    return null;
  }
  return '\\$path';
}

String _definitionText(dom.Node node) {
  final result = StringBuffer();
  void visit(dom.Node node) {
    if (node is dom.Text) {
      result.write(node.data);
      return;
    }
    if (node is dom.Element && node.localName == 'br') {
      result.writeln();
      return;
    }
    for (final child in node.nodes) {
      visit(child);
    }
    if (node is dom.Element &&
        const {
          'p',
          'div',
          'li',
          'dt',
          'dd',
          'h1',
          'h2',
          'h3',
          'tr',
          'section',
        }.contains(node.localName)) {
      result.writeln();
    }
  }

  visit(node);
  return result
      .toString()
      .replaceAll('\u0000', '')
      .replaceAll(RegExp(r'\n[ \t]*\n[ \t]*\n+'), '\n\n')
      .trim();
}
