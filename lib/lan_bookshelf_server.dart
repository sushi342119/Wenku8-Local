import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'reader_chrome.dart';

class LanBookshelfServer extends ChangeNotifier {
  LanBookshelfServer({
    required this.local,
    required this.state,
  });

  final LocalLibraryStore local;
  final LibraryState state;

  HttpServer? _server;
  String _hostIp = '127.0.0.1';
  int _port = 0;
  int _uploadedCount = 0;
  String? _lastError;
  final List<String> _recentUploads = <String>[];

  bool get isRunning => _server != null;
  String get url => isRunning ? 'http://$_hostIp:$_port' : '';
  int get port => _port;
  int get uploadedCount => _uploadedCount;
  String? get lastError => _lastError;
  List<String> get recentUploads => List.unmodifiable(_recentUploads);

  static Future<String> resolveLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
      for (final iface in interfaces) {
        if (iface.addresses.isNotEmpty) {
          return iface.addresses.first.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> start({int preferredPort = 8899}) async {
    if (_server != null) return;
    _lastError = null;
    try {
      _hostIp = await resolveLanIp();
      HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
      } catch (_) {
        server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      _server = server;
      _port = server.port;
      server.listen(
        _handleRequest,
        onError: (Object error) {
          _lastError = error.toString();
          notifyListeners();
        },
      );
      notifyListeners();
    } catch (error) {
      _lastError = '启动局域网服务失败：$error';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, OPTIONS',
    );
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, X-File-Name',
    );

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    final path = request.uri.path;
    try {
      if (request.method == 'GET' && (path == '/' || path == '/index.html')) {
        response.headers.contentType = ContentType.html;
        response.write(_webAppHtml);
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/books') {
        final list = [
          for (final book in local.books)
            {
              'id': book.id,
              'title': book.displayTitle,
              'author': book.displayAuthor,
              'fileName': book.fileName,
              'kind': book.kind.name,
              'chapterCount': book.chapters.length,
              'wordCount': book.wordCount ?? 0,
            },
        ];
        _writeJson(response, {'ok': true, 'books': list});
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/book') {
        final id = int.tryParse(request.uri.queryParameters['id'] ?? '') ?? 0;
        final chapterIdx =
            int.tryParse(request.uri.queryParameters['chapter'] ?? '0') ?? 0;
        final book = local.bookFor(id);
        if (book == null) {
          _writeJson(
            response,
            {'ok': false, 'error': '未找到该书籍'},
            status: HttpStatus.notFound,
          );
          await response.close();
          return;
        }
        final novel = local.toNovel(book);
        final safeIdx = novel.chapters.isEmpty
            ? 0
            : chapterIdx.clamp(0, novel.chapters.length - 1);
        var content = '';
        var chapterTitle = '';
        if (novel.chapters.isNotEmpty && book.kind == LocalBookKind.txt) {
          chapterTitle = novel.chapters[safeIdx].title;
          content = await local.chapterContent(
            novel.id,
            novel.chapters[safeIdx],
          );
        } else if (book.kind == LocalBookKind.epub) {
          chapterTitle = novel.chapters.isNotEmpty
              ? novel.chapters[safeIdx].title
              : book.displayTitle;
          final epubData = await local.epubChapter(book.id, safeIdx);
          content = epubData.blocks
              .map((b) => b.text ?? '')
              .where((s) => s.trim().isNotEmpty)
              .join('\n\n');
        }
        _writeJson(response, {
          'ok': true,
          'id': book.id,
          'title': book.displayTitle,
          'author': book.displayAuthor,
          'chapter': safeIdx,
          'chapterTitle': chapterTitle,
          'totalChapters': novel.chapters.length,
          'content': content,
          'chapters': [
            for (var i = 0; i < novel.chapters.length; i++)
              {'index': i, 'title': novel.chapters[i].title},
          ],
        });
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/upload') {
        final rawName =
            request.uri.queryParameters['name'] ??
            request.headers.value('x-file-name') ??
            'uploaded_book.txt';
        final fileName = Uri.decodeComponent(rawName).trim();
        final builder = BytesBuilder(copy: false);
        await for (final chunk in request) {
          builder.add(chunk);
          if (builder.length > localTextMaxSourceBytes) {
            throw const FormatException('上传文件超过 256 MiB 限制');
          }
        }
        final bytes = builder.takeBytes();
        if (bytes.isEmpty) {
          _writeJson(
            response,
            {'ok': false, 'error': '上传文件内容为空'},
            status: HttpStatus.badRequest,
          );
          await response.close();
          return;
        }
        final tempDir = await Directory.systemTemp.createTemp('shuyu_wifi_');
        try {
          final safeName = fileName.replaceAll(
            RegExp(r'[\\/:*?"<>|\x00-\x1f]'),
            '_',
          );
          final tempFile = File('${tempDir.path}/$safeName');
          await tempFile.writeAsBytes(bytes, flush: true);
          if (safeName.toLowerCase().endsWith('.zip')) {
            final res = await local.importCloudBatch(safeName, tempFile.path);
            await state.addShelfBooks([
              for (final b in local.books)
                if (!state.contains(b.id)) local.toNovel(b),
            ]);
            _uploadedCount += res.imported;
            _recentUploads.insert(0, '$safeName (${res.imported} 本)');
          } else {
            final novel = await local.importCloudFile(safeName, tempFile.path);
            await state.addShelfBooks([novel]);
            _uploadedCount++;
            _recentUploads.insert(0, novel.title);
          }
          if (_recentUploads.length > 10) {
            _recentUploads.removeRange(10, _recentUploads.length);
          }
          notifyListeners();
          _writeJson(response, {'ok': true, 'name': safeName});
        } finally {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
        await response.close();
        return;
      }

      _writeJson(
        response,
        {'ok': false, 'error': '未知接口'},
        status: HttpStatus.notFound,
      );
      await response.close();
    } catch (error) {
      _writeJson(
        response,
        {'ok': false, 'error': error.toString()},
        status: HttpStatus.internalServerError,
      );
      await response.close();
    }
  }

  void _writeJson(
    HttpResponse response,
    Map<String, Object?> data, {
    int status = HttpStatus.ok,
  }) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

Future<void> showLanBookshelfSheet({
  required BuildContext context,
  required LocalLibraryStore local,
  required LibraryState state,
  bool reduceMotion = false,
}) async {
  final server = LanBookshelfServer(local: local, state: state);
  await server.start();
  if (!context.mounted) {
    await server.stop();
    server.dispose();
    return;
  }
  try {
    await showJellySheet<void>(
      context: context,
      reduceMotion: reduceMotion,
      builder: (ctx) => _LanBookshelfSheet(server: server),
    );
  } finally {
    await server.stop();
    server.dispose();
  }
}

class _LanBookshelfSheet extends StatelessWidget {
  const _LanBookshelfSheet({required this.server});
  final LanBookshelfServer server;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final running = server.isRunning;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    CupertinoIcons.wifi,
                    color: running ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Wi-Fi 传书与网页书架',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    key: const ValueKey('lan-server-toggle'),
                    value: running,
                    onChanged: (v) {
                      if (v) {
                        server.start();
                      } else {
                        server.stop();
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '确保电脑或另一台设备与本机连接同一 Wi-Fi，在浏览器打开下方地址即可拖拽上传 TXT / EPUB / MOBI / AZW3 书籍或在线阅读：',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(
                    ArchiveDesign.panelRadius,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        running ? server.url : '服务已暂停',
                        key: const ValueKey('lan-server-url'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: running
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (running)
                      GlassTextButton(
                        key: const ValueKey('lan-server-copy-url'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: server.url),
                          );
                          if (context.mounted) {
                            showNovelFeedback(context, '已复制局域网地址');
                          }
                        },
                        child: const Text('复制地址'),
                      ),
                  ],
                ),
              ),
              if (server.lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  server.lastError!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '本次已接收 ${server.uploadedCount} 本书籍 · 关闭此面板将自动停止局域网服务',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              if (server.recentUploads.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '最近接收：${server.recentUploads.join('、')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

const _webAppHtml = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>书屿 · Wi-Fi 传书与网页书架</title>
<style>
  :root {
    --bg: #F6F1E7;
    --card: #FCF9F2;
    --ink: #2C261F;
    --muted: #7A6F63;
    --accent: #8C6239;
    --border: #E5DCCB;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Noto Serif CJK SC", sans-serif;
    background: var(--bg);
    color: var(--ink);
    line-height: 1.6;
  }
  header {
    padding: 20px 24px;
    border-bottom: 1px solid var(--border);
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: var(--card);
  }
  header h1 { margin: 0; font-size: 20px; font-weight: 600; }
  main { max-width: 960px; margin: 24px auto; padding: 0 16px; }
  .dropzone {
    border: 2px dashed var(--accent);
    border-radius: 14px;
    background: var(--card);
    padding: 28px 20px;
    text-align: center;
    cursor: pointer;
    transition: background .2s;
  }
  .dropzone:hover { background: #F3ECE0; }
  .books {
    margin-top: 24px;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 14px;
  }
  .book-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 14px 16px;
    cursor: pointer;
  }
  .book-card h3 { margin: 0 0 4px 0; font-size: 16px; }
  .book-card p { margin: 0; font-size: 12px; color: var(--muted); }
  #reader {
    display: none;
    margin-top: 24px;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 24px;
  }
  #reader-content {
    white-space: pre-wrap;
    font-size: 18px;
    line-height: 1.85;
    margin-top: 16px;
  }
  button {
    background: var(--accent);
    color: #fff;
    border: none;
    border-radius: 8px;
    padding: 8px 14px;
    cursor: pointer;
    font-size: 13px;
  }
</style>
</head>
<body>
<header>
  <h1>书屿 · Wi-Fi 传书与网页书架</h1>
  <span id="status" style="font-size:13px;color:var(--muted)">已连接</span>
</header>
<main>
  <div class="dropzone" onclick="document.getElementById('fileInput').click()"
       ondragover="event.preventDefault()"
       ondrop="handleDrop(event)">
    <div style="font-size:16px;font-weight:600">点击选择或拖拽小说文件到此处上传</div>
    <div style="font-size:13px;color:var(--muted);margin-top:4px">
      支持 .txt / .epub / .mobi / .azw3 / .zip 批量导入，自动加入书屿书架
    </div>
    <input id="fileInput" type="file" multiple accept=".txt,.epub,.mobi,.azw3,.azw,.prc,.zip,.fb2,.docx" style="display:none" onchange="uploadFiles(this.files)">
  </div>
  <div id="reader">
    <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap">
      <strong id="reader-title"></strong>
      <div>
        <button onclick="stepChapter(-1)">上一章</button>
        <button onclick="stepChapter(1)">下一章</button>
        <button onclick="document.getElementById('reader').style.display='none'" style="background:#7A6F63">关闭阅读</button>
      </div>
    </div>
    <div id="reader-content"></div>
  </div>
  <h2 style="font-size:16px;margin-top:28px">本机书库</h2>
  <div id="books" class="books"></div>
</main>
<script>
let currentBookId = 0, currentChapter = 0, totalChapters = 0;
async function loadBooks() {
  const res = await fetch('/api/books');
  const data = await res.json();
  const container = document.getElementById('books');
  container.innerHTML = '';
  for (const b of (data.books || [])) {
    const div = document.createElement('div');
    div.className = 'book-card';
    div.onclick = () => openBook(b.id, 0);
    div.innerHTML = '<h3>' + escapeHtml(b.title) + '</h3><p>' +
      escapeHtml(b.author || '佚名') + ' · ' + b.chapterCount + ' 章</p>';
    container.appendChild(div);
  }
}
async function openBook(id, ch) {
  const res = await fetch('/api/book?id=' + id + '&chapter=' + ch);
  const data = await res.json();
  if (!data.ok) return alert(data.error || '加载失败');
  currentBookId = data.id;
  currentChapter = data.chapter;
  totalChapters = data.totalChapters;
  document.getElementById('reader').style.display = 'block';
  document.getElementById('reader-title').textContent =
    data.title + ' · ' + (data.chapterTitle || ('第 ' + (ch + 1) + ' 章'));
  document.getElementById('reader-content').textContent = data.content || '（本章暂无正文）';
}
function stepChapter(delta) {
  const next = currentChapter + delta;
  if (next >= 0 && next < totalChapters) openBook(currentBookId, next);
}
async function uploadFiles(files) {
  const status = document.getElementById('status');
  for (const file of files) {
    status.textContent = '正在上传 ' + file.name + '…';
    const res = await fetch('/api/upload?name=' + encodeURIComponent(file.name), {
      method: 'POST',
      body: file
    });
    const data = await res.json();
    if (!data.ok) alert(file.name + ' 上传失败：' + data.error);
  }
  status.textContent = '上传完成';
  loadBooks();
}
function handleDrop(e) {
  e.preventDefault();
  if (e.dataTransfer && e.dataTransfer.files) uploadFiles(e.dataTransfer.files);
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
}
loadBooks();
</script>
</body>
</html>
''';
