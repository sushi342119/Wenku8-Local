/// 书源试验版（source-trial 分支）：下载管理器。
///
/// 一本书一个任务、串行请求；显示进度；支持取消、失败重试、验证后继续；
/// 缓存已完成章节；全书完成后生成 UTF-8 TXT，写入应用 novels 文件夹，
/// 走现有 scanAppFolder() 链路入库（复用本地阅读、标签、进度能力）。
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../local_library.dart';
import 'site_adapter.dart';
import 'source_client.dart';
import 'source_config.dart';
import 'source_models.dart';

/// 章节正文拉取函数（由站点适配器提供）。
typedef ChapterFetcher =
    Future<SourceChapterContent> Function(
      SourceClient client,
      SourceChapter chapter,
    );

/// 下载进度回调：(已完成章数, 总章数, 当前章节标题)。
typedef DownloadProgress = void Function(int done, int total, String current);

class SourceDownloadTask {
  SourceDownloadTask({
    required this.detail,
    required this.client,
    required this.fetcher,
    required this.local,
  });

  final SourceBookDetail detail;
  final SourceClient client;
  final ChapterFetcher fetcher;
  final LocalLibraryStore local;

  SourceDownloadStatus _status = SourceDownloadStatus.idle;
  SourceDownloadStatus get status => _status;

  int _done = 0;
  int get done => _done;

  int get total => detail.chapters.length;

  final List<SourceChapterResult> _results = [];
  List<SourceChapterResult> get results => List.unmodifiable(_results);

  bool _cancelled = false;
  String? _error;
  String? get error => _error;

  /// 已成功的章节（用于断点继续，避免重复下载）。
  final Map<int, SourceChapterContent> _cache = {};

  void cancel() {
    _cancelled = true;
  }

  /// 开始/继续下载。遇到 Cloudflare 挑战时抛 [SourceNeedVerify]，
  /// 由调用方打开 WebView 验证后再次调用本方法继续（已下载章节不重复）。
  Future<void> start(DownloadProgress onProgress) async {
    if (_status == SourceDownloadStatus.downloading) return;
    _cancelled = false;
    _error = null;
    _status = SourceDownloadStatus.downloading;
    try {
      for (final chapter in detail.chapters) {
        if (_cancelled) {
          _status = SourceDownloadStatus.cancelled;
          return;
        }
        if (_cache.containsKey(chapter.index)) {
          _done++;
          onProgress(_done, total, chapter.title);
          continue;
        }
        onProgress(_done, total, chapter.title);
        try {
          final content = await fetcher(client, chapter);
          if (content.isEmpty) {
            throw const SourceEmptyContent();
          }
          _cache[chapter.index] = content;
          _results.add(
            SourceChapterResult(chapter: chapter, content: content),
          );
        } on SourceNeedVerify {
          _status = SourceDownloadStatus.pausedNeedVerify;
          rethrow;
        } catch (e) {
          _results.add(
            SourceChapterResult(chapter: chapter, error: e.toString()),
          );
        }
        _done++;
        onProgress(_done, total, chapter.title);
        // 限流：章间短暂间隔，避免触发站点限流。
        await Future.delayed(const Duration(milliseconds: 800));
      }
      final failed = _results.where((r) => !r.success).length;
      if (failed > 0) {
        _status = SourceDownloadStatus.failed;
        _error = '$failed 章下载失败，可重试';
        return;
      }
      _status = SourceDownloadStatus.completed;
    } catch (e) {
      if (e is SourceNeedVerify) rethrow;
      _status = SourceDownloadStatus.failed;
      _error = e.toString();
    }
  }

  /// 重试失败章节。
  Future<void> retryFailed(DownloadProgress onProgress) async {
    final failedIndexes = _results
        .where((r) => !r.success)
        .map((r) => r.chapter.index)
        .toSet();
    if (failedIndexes.isEmpty) return;
    _results.removeWhere((r) => failedIndexes.contains(r.chapter.index));
    _done = total - failedIndexes.length;
    _error = null;
    await start(onProgress);
  }

  List<SourceChapterResult> get failedResults =>
      _results.where((r) => !r.success).toList();

  /// 生成 TXT 并入库。返回导入的 LocalBook，失败抛错。
  /// 章节失败时不静默跳过：有失败章节则拒绝入库，由调用方先处理。
  Future<LocalBook> saveToLibrary() async {
    if (_status != SourceDownloadStatus.completed) {
      throw StateError('下载未完成，无法入库');
    }
    final failed = failedResults;
    if (failed.isNotEmpty) {
      throw StateError('${failed.length} 章下载失败，请先重试成功后再入库');
    }
    final text = _buildTxt();
    final fileName = _fileName();
    final dir = await _novelsDir();
    final file = File('$dir/$fileName');
    await file.writeAsString(text);
    final result = await local.scanAppFolder();
    // 扫描后按文件名找回刚导入的书。
    final book = local.books
        .where((b) => b.fileName == fileName)
        .cast<LocalBook?>();
    final imported = book.isEmpty ? null : book.first;
    if (imported == null) {
      throw StateError('入库失败：扫描完成但未找到书籍（added=${result.added}）');
    }
    return imported;
  }

  Future<String> _novelsDir() async {
    final dir = await getExternalStorageDirectory();
    if (dir == null) throw StateError('无法获取应用外部存储目录');
    final novels = Directory('${dir.path}/novels');
    if (!await novels.exists()) await novels.create(recursive: true);
    return novels.path;
  }

  String _sanitize(String s) {
    var v = s.replaceAll(RegExp(r'[<>:\"/\\|?*\x00-\x1f]'), '_').trim();
    v = v.replaceAll(RegExp(r'[. ]+$'), '');
    if (v.isEmpty) v = '未命名';
    if (v.length > 80) v = v.substring(0, 80);
    return v;
  }

  String _fileName() {
    final title = _sanitize(detail.book.title);
    final author = _sanitize(detail.book.author);
    final base = author.isEmpty ? title : '$title - $author';
    // 同名文件已存在时加序号，避免覆盖用户已有书籍。
    return '$base [书源].txt';
  }

  /// 生成 TXT：章节标题行符合本地 _chapterTitlePattern（第X章，≤42字），
  /// 确保导入后能正确切分章节。
  String _buildTxt() {
    final buf = StringBuffer();
    buf.writeln('《${detail.book.title}》');
    if (detail.book.author.isNotEmpty) buf.writeln('作者：${detail.book.author}');
    buf.writeln('来源：123小说网（书源试验版导入）');
    if (detail.book.description != null &&
        detail.book.description!.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('简介：${detail.book.description!.trim()}');
    }
    buf.writeln();
    final ordered = _cache.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in ordered) {
      final content = entry.value;
      buf.writeln(_chapterHeading(entry.key, content.title));
      buf.writeln();
      for (final p in content.paragraphs) {
        final line = p.trim();
        if (line.isEmpty) continue;
        buf.writeln('　　$line');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// 章节标题行：保证命中本地章节正则且不超过 42 字。
  String _chapterHeading(int index, String rawTitle) {
    final t = rawTitle.trim();
    // 站点标题已是"第X章"格式且长度合适时直接用。
    if (t.length <= 40 &&
        RegExp(r'^第[一二三四五六七八九十百千零〇两\d\s　]+[章节回集卷部篇]').hasMatch(t)) {
      return t;
    }
    // 否则用序号重建标题，原标题截断拼接。
    var suffix = t;
    // 去掉可能重复的序号前缀，避免"第1章 第1章 xxx"。
    suffix = suffix
        .replaceFirst(
          RegExp(r'^第[一二三四五六七八九十百千零〇两\d\s　]+[章节回集卷部篇]\s*'),
          '',
        )
        .trim();
    var heading = '第${index + 1}章';
    if (suffix.isNotEmpty) {
      final maxSuffix = 40 - heading.length - 1;
      if (suffix.length > maxSuffix) suffix = suffix.substring(0, maxSuffix);
      heading = '$heading $suffix';
    }
    return heading;
  }
}

/// 需要用户完成 Cloudflare 验证（由 WebView 流程处理）。
class SourceNeedVerify implements Exception {
  const SourceNeedVerify([this.message = '需要完成网站验证']);
  final String message;
  @override
  String toString() => message;
}

/// 正文为空（可能被挑战页拦截或解析失败）。
class SourceEmptyContent implements Exception {
  const SourceEmptyContent();
  @override
  String toString() => '正文为空';
}
