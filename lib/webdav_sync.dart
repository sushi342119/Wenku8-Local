import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_interactions.dart';
import 'app_ui.dart';

const String _webDavConfigStorageKey = 'webdav.backup.config.v1';

@immutable
class WebDavBackupConfig {
  const WebDavBackupConfig({
    this.serverUrl = 'https://dav.jianguoyun.com/dav/',
    this.username = '',
    this.password = '',
    this.remoteFolder = 'shuyu_backup',
    this.autoBackup = false,
  });

  final String serverUrl;
  final String username;
  final String password;
  final String remoteFolder;
  final bool autoBackup;

  bool get isConfigured =>
      serverUrl.trim().isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  Uri? folderUri() {
    final raw = serverUrl.trim();
    if (raw.isEmpty) return null;
    final normalizedBase = raw.endsWith('/') ? raw : '$raw/';
    final base = Uri.tryParse(normalizedBase);
    if (base == null || (!base.isScheme('http') && !base.isScheme('https'))) {
      return null;
    }
    final cleanFolder = remoteFolder
        .trim()
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleanFolder.isEmpty) return base;
    return base.resolve('$cleanFolder/');
  }

  Uri? fileUri(String fileName) {
    final folder = folderUri();
    if (folder == null) return null;
    final cleanName = fileName.replaceAll(RegExp(r'^/+'), '');
    return folder.resolve(cleanName);
  }

  WebDavBackupConfig copyWith({
    String? serverUrl,
    String? username,
    String? password,
    String? remoteFolder,
    bool? autoBackup,
  }) => WebDavBackupConfig(
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    remoteFolder: remoteFolder ?? this.remoteFolder,
    autoBackup: autoBackup ?? this.autoBackup,
  );

  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'username': username,
    'password': password,
    'remoteFolder': remoteFolder,
    'autoBackup': autoBackup,
  };

  factory WebDavBackupConfig.fromJson(Map<String, dynamic> json) =>
      WebDavBackupConfig(
        serverUrl: (json['serverUrl'] as String?) ??
            'https://dav.jianguoyun.com/dav/',
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
        remoteFolder: (json['remoteFolder'] as String?) ?? 'shuyu_backup',
        autoBackup: (json['autoBackup'] as bool?) ?? false,
      );

  static WebDavBackupConfig load(SharedPreferences? prefs) {
    final raw = prefs?.getString(_webDavConfigStorageKey);
    if (raw == null || raw.isEmpty) return const WebDavBackupConfig();
    try {
      return WebDavBackupConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const WebDavBackupConfig();
    }
  }

  Future<void> save(SharedPreferences? prefs) async {
    await prefs?.setString(_webDavConfigStorageKey, jsonEncode(toJson()));
  }
}

class WebDavBackupClient {
  const WebDavBackupClient(this.config);

  final WebDavBackupConfig config;

  String get _basicAuthHeader {
    final token = base64Encode(
      utf8.encode('${config.username.trim()}:${config.password}'),
    );
    return 'Basic $token';
  }

  Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    request.headers.set(HttpHeaders.userAgentHeader, 'Shuyu-WebDAV/1.0');
    headers?.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    return request.close().timeout(const Duration(seconds: 25));
  }

  Future<void> ensureFolder(HttpClient client) async {
    final uri = config.folderUri();
    if (uri == null) throw const FormatException('WebDAV 服务器地址格式无效');
    final response = await _send(client, 'MKCOL', uri);
    await response.drain<void>();
    // 201 Created, 405 Method Not Allowed (already exists), 301/200 OK
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException('WebDAV 账号或应用密码认证失败（401/403）');
    }
  }

  Future<String> uploadBackup(String jsonText) async {
    if (!config.isConfigured) {
      throw const FormatException('请先填写完整的 WebDAV 地址、账号与密码');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      await ensureFolder(client);
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final datedFile = 'shuyu-backup-$date.json';
      final bytes = utf8.encode(jsonText);

      for (final name in [datedFile, 'shuyu-backup-latest.json']) {
        final uri = config.fileUri(name);
        if (uri == null) throw const FormatException('WebDAV 目标路径无效');
        final response = await _send(
          client,
          'PUT',
          uri,
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: bytes,
        );
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw FormatException('WebDAV 上传失败（HTTP ${response.statusCode}）');
        }
      }
      return datedFile;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> listBackups() async {
    if (!config.isConfigured) {
      throw const FormatException('请先填写完整的 WebDAV 地址、账号与密码');
    }
    final uri = config.folderUri();
    if (uri == null) throw const FormatException('WebDAV 服务器地址格式无效');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      await ensureFolder(client);
      final response = await _send(
        client,
        'PROPFIND',
        uri,
        headers: {
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        await response.drain<void>();
        throw const FormatException('WebDAV 账号或密码认证失败（401/403）');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw FormatException('WebDAV 目录读取失败（HTTP ${response.statusCode}）');
      }
      final xml = await utf8.decoder.bind(response).join();
      final matches = RegExp(
        r'<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>',
        caseSensitive: false,
      ).allMatches(xml);
      final files = <String>{};
      for (final match in matches) {
        final rawHref = Uri.decodeFull((match.group(1) ?? '').trim());
        final segments = rawHref
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .toList(growable: false);
        if (segments.isEmpty) continue;
        final last = segments.last;
        if (last.toLowerCase().endsWith('.json')) {
          files.add(last);
        }
      }
      final sorted = files.toList()..sort((a, b) => b.compareTo(a));
      return sorted;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> downloadBackup([
    String fileName = 'shuyu-backup-latest.json',
  ]) async {
    if (!config.isConfigured) {
      throw const FormatException('请先填写完整的 WebDAV 地址、账号与密码');
    }
    final uri = config.fileUri(fileName);
    if (uri == null) throw const FormatException('WebDAV 目标路径无效');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final response = await _send(client, 'GET', uri);
      if (response.statusCode == 404) {
        await response.drain<void>();
        throw FormatException('云端未找到备份文件 $fileName');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw FormatException('WebDAV 下载失败（HTTP ${response.statusCode}）');
      }
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }
}

Future<void> showWebDavBackupSheet({
  required BuildContext context,
  required bool reduceMotion,
  required SharedPreferences? preferences,
  required Future<String> Function() createBackupJson,
  required Future<void> Function(String jsonText) onRestoreBackupJson,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: reduceMotion,
  builder: (sheetContext) => _WebDavBackupSheet(
    preferences: preferences,
    createBackupJson: createBackupJson,
    onRestoreBackupJson: onRestoreBackupJson,
  ),
);

class _WebDavBackupSheet extends StatefulWidget {
  const _WebDavBackupSheet({
    required this.preferences,
    required this.createBackupJson,
    required this.onRestoreBackupJson,
  });

  final SharedPreferences? preferences;
  final Future<String> Function() createBackupJson;
  final Future<void> Function(String jsonText) onRestoreBackupJson;

  @override
  State<_WebDavBackupSheet> createState() => _WebDavBackupSheetState();
}

class _WebDavBackupSheetState extends State<_WebDavBackupSheet> {
  late WebDavBackupConfig _config;
  late final TextEditingController _urlController;
  late final TextEditingController _userController;
  late final TextEditingController _passController;
  late final TextEditingController _folderController;
  String? _busy;
  String? _status;
  bool _isError = false;
  List<String> _remoteFiles = const [];

  @override
  void initState() {
    super.initState();
    _config = WebDavBackupConfig.load(widget.preferences);
    _urlController = TextEditingController(text: _config.serverUrl);
    _userController = TextEditingController(text: _config.username);
    _passController = TextEditingController(text: _config.password);
    _folderController = TextEditingController(text: _config.remoteFolder);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _folderController.dispose();
    super.dispose();
  }

  Future<WebDavBackupConfig> _saveCurrentConfig() async {
    final next = _config.copyWith(
      serverUrl: _urlController.text.trim(),
      username: _userController.text.trim(),
      password: _passController.text,
      remoteFolder: _folderController.text.trim().isEmpty
          ? 'shuyu_backup'
          : _folderController.text.trim(),
    );
    _config = next;
    await next.save(widget.preferences);
    return next;
  }

  Future<void> _runTask(String label, Future<void> Function() task) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _status = null;
      _isError = false;
    });
    try {
      await task();
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _status = e.message;
          _isError = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '连接 WebDAV 失败，请检查网络、服务器地址或应用密码';
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSheet(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'WebDAV 云端备份与同步',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                GlassTextButton(
                  onPressed: () {
                    _urlController.text = 'https://dav.jianguoyun.com/dav/';
                  },
                  child: const Text('填入坚果云地址', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '支持坚果云、Nextcloud、Alist / OpenList 等标准 WebDAV 网盘，将书架、阅读进度、书签与净化规则一键备份到云端。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('webdav-url-input'),
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: '服务器地址 (Server URL)',
                hintText: 'https://dav.jianguoyun.com/dav/',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('webdav-user-input'),
                    controller: _userController,
                    decoration: const InputDecoration(
                      labelText: '账号 (Username)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const ValueKey('webdav-pass-input'),
                    controller: _passController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '应用密码 (Password)',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('webdav-folder-input'),
              controller: _folderController,
              decoration: const InputDecoration(
                labelText: '远程备份目录',
                hintText: 'shuyu_backup',
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                GlassTextButton(
                  key: const ValueKey('webdav-backup-upload'),
                  onPressed: _busy == null
                      ? () => _runTask('正在上传备份到 WebDAV…', () async {
                          final cfg = await _saveCurrentConfig();
                          final jsonText = await widget.createBackupJson();
                          final fileName =
                              await WebDavBackupClient(cfg).uploadBackup(
                                jsonText,
                              );
                          final files =
                              await WebDavBackupClient(cfg).listBackups();
                          if (mounted) {
                            setState(() {
                              _remoteFiles = files;
                              _status = '已成功备份至云端：$fileName';
                            });
                          }
                        })
                      : null,
                  child: const Text('立即备份到 WebDAV'),
                ),
                GlassTextButton(
                  key: const ValueKey('webdav-backup-restore'),
                  onPressed: _busy == null
                      ? () => _runTask('正在从 WebDAV 读取最新备份…', () async {
                          final cfg = await _saveCurrentConfig();
                          final client = WebDavBackupClient(cfg);
                          final files = await client.listBackups();
                          if (files.isEmpty) {
                            throw const FormatException('云端目录中暂无备份文件');
                          }
                          final target = files.contains(
                            'shuyu-backup-latest.json',
                          )
                              ? 'shuyu-backup-latest.json'
                              : files.first;
                          final jsonText = await client.downloadBackup(target);
                          if (!mounted) return;
                          Navigator.pop(context);
                          await widget.onRestoreBackupJson(jsonText);
                        })
                      : null,
                  child: const Text('从 WebDAV 恢复最新备份'),
                ),
                GlassTextButton(
                  key: const ValueKey('webdav-list-files'),
                  onPressed: _busy == null
                      ? () => _runTask('正在获取云端备份列表…', () async {
                          final cfg = await _saveCurrentConfig();
                          final files =
                              await WebDavBackupClient(cfg).listBackups();
                          if (mounted) {
                            setState(() {
                              _remoteFiles = files;
                              _status = files.isEmpty
                                  ? '连接成功，云端目录暂无历史备份'
                                  : '已获取 ${files.length} 个云端备份文件';
                            });
                          }
                        })
                      : null,
                  child: const Text('刷新云端列表'),
                ),
              ],
            ),
            if (_busy != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _busy!,
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                ),
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _status!,
                  key: const ValueKey('webdav-status-text'),
                  style: TextStyle(
                    fontSize: 12,
                    color: _isError ? scheme.error : scheme.primary,
                  ),
                ),
              ),
            if (_remoteFiles.isNotEmpty) ...[
              const Divider(height: 22),
              Text(
                '云端备份文件（点击可读取并预览恢复）',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (final file in _remoteFiles.take(8))
                GlassTextButton(
                  onPressed: _busy == null
                      ? () => _runTask('正在下载 $file…', () async {
                          final cfg = await _saveCurrentConfig();
                          final jsonText =
                              await WebDavBackupClient(cfg).downloadBackup(
                                file,
                              );
                          if (!mounted) return;
                          Navigator.pop(context);
                          await widget.onRestoreBackupJson(jsonText);
                        })
                      : null,
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.cloud_download, size: 15),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(file, style: const TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
