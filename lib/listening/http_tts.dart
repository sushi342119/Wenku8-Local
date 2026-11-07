import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_interactions.dart';
import '../app_ui.dart';
import 'models.dart';

const String _httpTtsStorageKey = 'listening.http_tts.engines.v1';

@immutable
class HttpTtsEngineConfig {
  const HttpTtsEngineConfig({
    required this.id,
    required this.name,
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.bodyTemplate = '',
    this.contentType = 'application/json; charset=utf-8',
  });

  final String id;
  final String name;
  final String url;
  final String method;
  final Map<String, String> headers;
  final String bodyTemplate;
  final String contentType;

  SpeechVoice toSpeechVoice() => SpeechVoice(
    id: id,
    label: '$name · 自定义HTTP',
    source: ListeningSource.custom,
    engine: 'http_tts',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'method': method,
    'headers': headers,
    'bodyTemplate': bodyTemplate,
    'contentType': contentType,
  };

  /// Supports both Shuyu native JSON and Legado `httpTTS` JSON format:
  /// Legado often stores `url` as `"https://... , {\"method\":\"POST\",\"body\":\"...\"}"`.
  factory HttpTtsEngineConfig.fromJson(Map<String, dynamic> json) {
    final rawId = '${json['id'] ?? DateTime.now().microsecondsSinceEpoch}';
    final rawName = (json['name'] as String?)?.trim();
    var rawUrl = (json['url'] as String?)?.trim() ?? '';
    var method = ((json['method'] as String?) ?? 'GET').toUpperCase();
    var bodyTemplate = (json['bodyTemplate'] ?? json['body'] ?? '').toString();
    var contentType =
        (json['contentType'] as String?) ?? 'application/json; charset=utf-8';
    final headers = <String, String>{};

    if (json['headers'] is Map) {
      for (final entry in (json['headers'] as Map).entries) {
        headers['${entry.key}'] = '${entry.value}';
      }
    } else if (json['header'] is String &&
        (json['header'] as String).trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(json['header'] as String);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            headers['${entry.key}'] = '${entry.value}';
          }
        }
      } catch (_) {}
    }

    // Parse Legado compound URL: `https://example.com/tts,{"method":"POST","body":"..."}`
    final commaMatch = RegExp(r',\s*(\{[\s\S]*\})\s*$').firstMatch(rawUrl);
    if (commaMatch != null) {
      final optionStr = commaMatch.group(1)!;
      try {
        final opt = jsonDecode(optionStr);
        if (opt is Map) {
          rawUrl = rawUrl.substring(0, commaMatch.start).trim();
          if (opt['method'] is String) {
            method = (opt['method'] as String).toUpperCase();
          }
          if (opt['body'] != null) {
            bodyTemplate = '${opt['body']}';
          }
          if (opt['headers'] is Map) {
            for (final entry in (opt['headers'] as Map).entries) {
              headers['${entry.key}'] = '${entry.value}';
            }
          }
          if (opt['contentType'] is String) {
            contentType = opt['contentType'] as String;
          }
        }
      } catch (_) {}
    }

    return HttpTtsEngineConfig(
      id: rawId,
      name: (rawName == null || rawName.isEmpty) ? '自定义朗读引擎' : rawName,
      url: rawUrl,
      method: method == 'POST' ? 'POST' : 'GET',
      headers: Map.unmodifiable(headers),
      bodyTemplate: bodyTemplate,
      contentType: contentType,
    );
  }
}

class HttpTtsStore extends ChangeNotifier {
  HttpTtsStore._();
  static final HttpTtsStore shared = HttpTtsStore._();

  SharedPreferences? _prefs;
  List<HttpTtsEngineConfig> _engines = const [];
  bool _initialized = false;

  List<HttpTtsEngineConfig> get engines => _engines;

  List<SpeechVoice> get voices => List.unmodifiable([
    for (final engine in _engines) engine.toSpeechVoice(),
  ]);

  HttpTtsEngineConfig? engineById(String id) {
    for (final engine in _engines) {
      if (engine.id == id) return engine;
    }
    return null;
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs?.getString(_httpTtsStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _engines = List.unmodifiable([
            for (final item in decoded)
              if (item is Map<String, dynamic>)
                HttpTtsEngineConfig.fromJson(item)
              else if (item is Map)
                HttpTtsEngineConfig.fromJson(Map<String, dynamic>.from(item)),
          ]);
        }
      }
    } catch (_) {
      _engines = const [];
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    await ensureInitialized();
    await _prefs?.setString(
      _httpTtsStorageKey,
      jsonEncode([for (final e in _engines) e.toJson()]),
    );
  }

  Future<void> upsertEngine(HttpTtsEngineConfig config) async {
    await ensureInitialized();
    final next = [..._engines];
    final index = next.indexWhere((item) => item.id == config.id);
    if (index >= 0) {
      next[index] = config;
    } else {
      next.add(config);
    }
    _engines = List.unmodifiable(next);
    notifyListeners();
    await _persist();
  }

  Future<void> removeEngine(String id) async {
    await ensureInitialized();
    _engines = List.unmodifiable(
      _engines.where((item) => item.id != id).toList(growable: false),
    );
    notifyListeners();
    await _persist();
  }

  Future<int> importFromJsonText(String rawText) async {
    await ensureInitialized();
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return 0;
    final decoded = jsonDecode(trimmed);
    final items = switch (decoded) {
      List list => list,
      Map map => [map],
      _ => const <dynamic>[],
    };
    var count = 0;
    final next = [..._engines];
    for (final raw in items) {
      if (raw is! Map) continue;
      final parsed = HttpTtsEngineConfig.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (parsed.url.isEmpty) continue;
      final existingIdx = next.indexWhere((e) => e.id == parsed.id);
      if (existingIdx >= 0) {
        next[existingIdx] = parsed;
      } else {
        next.add(parsed);
      }
      count++;
    }
    if (count > 0) {
      _engines = List.unmodifiable(next);
      notifyListeners();
      await _persist();
    }
    return count;
  }

  String exportToJsonText() => const JsonEncoder.withIndent(
    '  ',
  ).convert([for (final e in _engines) e.toJson()]);

  static String substituteTemplate(
    String template, {
    required String text,
    required double speed,
    required bool urlEncodeText,
  }) {
    final encodedText = urlEncodeText
        ? Uri.encodeComponent(text)
        : jsonEncode(text).substring(1, jsonEncode(text).length - 1);
    final intSpeed = (speed * 10).round().clamp(5, 30).toString();
    final rateSpeed = speed.toStringAsFixed(2);
    return template
        .replaceAll('{{java.encodeURI(speakText)}}', Uri.encodeComponent(text))
        .replaceAll('{{speakText}}', encodedText)
        .replaceAll('{{speakSpeed}}', intSpeed)
        .replaceAll('{{speakSpeedRate}}', rateSpeed)
        .replaceAll(r'${speakText}', encodedText)
        .replaceAll(r'${speakSpeed}', intSpeed);
  }

  Future<Uint8List> synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation, {
    double speed = 1.0,
  }) async {
    await ensureInitialized();
    final config =
        engineById(voice.id) ?? (_engines.isNotEmpty ? _engines.first : null);
    if (config == null || config.url.trim().isEmpty) {
      throw const SpeechFailure('未找到对应的自定义 HTTP 朗读引擎，请重新配置');
    }

    final resolvedUrl = substituteTemplate(
      config.url.trim(),
      text: text,
      speed: speed,
      urlEncodeText: true,
    );
    final uri = Uri.tryParse(resolvedUrl);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw const SpeechFailure('自定义 HTTP 朗读引擎 URL 格式无效');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final detach = cancellation.onCancel(() => client.close(force: true));
    try {
      cancellation.check();
      final request = await client
          .openUrl(config.method, uri)
          .timeout(const Duration(seconds: 15));
      for (final entry in config.headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      if (config.method == 'POST' && config.bodyTemplate.trim().isNotEmpty) {
        request.headers.set(HttpHeaders.contentTypeHeader, config.contentType);
        final bodyStr = substituteTemplate(
          config.bodyTemplate,
          text: text,
          speed: speed,
          urlEncodeText: config.contentType.contains('urlencoded'),
        );
        final bodyBytes = utf8.encode(bodyStr);
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw SpeechFailure('自定义 HTTP 语音返回错误（HTTP ${response.statusCode}）');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        cancellation.check();
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.length <= 100) {
        throw const SpeechFailure(
          '自定义 HTTP 引擎未返回有效音频流',
          kind: SpeechFailureKind.content,
        );
      }
      return bytes;
    } on SpeechCancelled {
      rethrow;
    } on SpeechFailure {
      rethrow;
    } on TimeoutException {
      throw const SpeechFailure(
        '自定义 HTTP 语音请求超时',
        kind: SpeechFailureKind.timeout,
      );
    } catch (_) {
      cancellation.check();
      throw const SpeechFailure('自定义 HTTP 语音请求失败，请检查接口配置');
    } finally {
      detach();
      client.close(force: true);
    }
  }
}

Future<void> showHttpTtsConfigSheet({
  required BuildContext context,
  required bool reduceMotion,
  required ValueChanged<SpeechVoice>? onSelectVoice,
}) async {
  await HttpTtsStore.shared.ensureInitialized();
  if (!context.mounted) return;
  await showJellySheet<void>(
    context: context,
    reduceMotion: reduceMotion,
    builder: (sheetContext) =>
        _HttpTtsConfigSheet(onSelectVoice: onSelectVoice),
  );
}

class _HttpTtsConfigSheet extends StatefulWidget {
  const _HttpTtsConfigSheet({required this.onSelectVoice});
  final ValueChanged<SpeechVoice>? onSelectVoice;

  @override
  State<_HttpTtsConfigSheet> createState() => _HttpTtsConfigSheetState();
}

class _HttpTtsConfigSheetState extends State<_HttpTtsConfigSheet> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _bodyController = TextEditingController();
  String _method = 'GET';
  bool _adding = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _saveNew() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      showNovelFeedback(context, '请填写 HTTP TTS 接口 URL');
      return;
    }
    final config = HttpTtsEngineConfig(
      id: 'http_tts_${DateTime.now().millisecondsSinceEpoch}',
      name: name.isEmpty ? '自定义 HTTP 语音' : name,
      url: url,
      method: _method,
      bodyTemplate: _bodyController.text.trim(),
    );
    await HttpTtsStore.shared.upsertEngine(config);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _nameController.clear();
      _urlController.clear();
      _bodyController.clear();
    });
    showNovelFeedback(context, '已保存自定义 HTTP 朗读引擎');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: HttpTtsStore.shared,
      builder: (context, _) {
        final engines = HttpTtsStore.shared.engines;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '自定义 HTTP 朗读引擎',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GlassTextButton(
                      key: const ValueKey('http-tts-toggle-add'),
                      onPressed: () => setState(() => _adding = !_adding),
                      child: Text(_adding ? '收起新建' : '新建引擎'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '支持占位符 {{speakText}}（朗读文本）、{{speakSpeed}}（语速），并直接兼容「阅读 Legado」httpTTS JSON 规则导入。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    GlassTextButton(
                      key: const ValueKey('http-tts-import-clipboard'),
                      onPressed: () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        final text = data?.text?.trim() ?? '';
                        if (text.isEmpty) {
                          if (context.mounted) {
                            showNovelFeedback(context, '剪贴板为空');
                          }
                          return;
                        }
                        try {
                          final count = await HttpTtsStore.shared
                              .importFromJsonText(text);
                          if (context.mounted) {
                            showNovelFeedback(
                              context,
                              count > 0
                                  ? '已导入 $count 个 HTTP 朗读引擎'
                                  : '未识别到有效的 httpTTS 规则',
                            );
                          }
                        } catch (_) {
                          if (context.mounted) {
                            showNovelFeedback(context, 'JSON 格式解析失败');
                          }
                        }
                      },
                      child: const Text('从剪贴板导入 httpTTS'),
                    ),
                    if (engines.isNotEmpty)
                      GlassTextButton(
                        key: const ValueKey('http-tts-export-clipboard'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text: HttpTtsStore.shared.exportToJsonText(),
                            ),
                          );
                          if (context.mounted) {
                            showNovelFeedback(context, '已复制全部 HTTP 朗读规则到剪贴板');
                          }
                        },
                        child: const Text('导出规则到剪贴板'),
                      ),
                  ],
                ),
                if (_adding) ...[
                  const Divider(height: 22),
                  TextField(
                    key: const ValueKey('http-tts-name-input'),
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '引擎名称',
                      hintText: '例如：Azure 晓晓 / 本地 GPT-SoVITS',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('http-tts-url-input'),
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: '接口 URL（含 {{speakText}}）',
                      hintText:
                          'https://example.com/tts?text={{speakText}}&speed={{speakSpeed}}',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('请求方式：', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      CupertinoSlidingSegmentedControl<String>(
                        groupValue: _method,
                        children: const {
                          'GET': Text('GET'),
                          'POST': Text('POST'),
                        },
                        onValueChanged: (value) {
                          if (value != null) setState(() => _method = value);
                        },
                      ),
                    ],
                  ),
                  if (_method == 'POST') ...[
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('http-tts-body-input'),
                      controller: _bodyController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'POST 请求体模板（JSON 或表单）',
                        hintText:
                            '{"text":"{{speakText}}","speed":{{speakSpeed}}}',
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  GlassTextButton(
                    key: const ValueKey('http-tts-save-btn'),
                    onPressed: _saveNew,
                    child: const Text('保存引擎'),
                  ),
                ],
                const Divider(height: 22),
                if (engines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '暂未添加自定义 HTTP 朗读引擎。你可以点击右上角「新建引擎」，或复制阅读 Legado 的 httpTTS JSON 后点击「从剪贴板导入」。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (final engine in engines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: GlassTextButton(
                              key: ValueKey('http-tts-select-${engine.id}'),
                              onPressed: () {
                                final voice = engine.toSpeechVoice();
                                Navigator.pop(context);
                                widget.onSelectVoice?.call(voice);
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    engine.name,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '${engine.method} · ${engine.url}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          GlassIconButton(
                            icon: CupertinoIcons.trash,
                            label: '删除 ${engine.name}',
                            onPressed: () =>
                                HttpTtsStore.shared.removeEngine(engine.id),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}
