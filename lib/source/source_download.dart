/// 书源试验版（source-trial 分支）：下载管理器。
///
/// 一本书一个任务、串行请求；显示进度；支持取消、失败重试、验证后继续；
/// 缓存已完成章节；全书完成后生成 UTF-8 TXT，写入应用 novels 文件夹，
/// 走现有 scanAppFolder() 链路入库（复用本地阅读、标签、进度能力）。
///
/// 状态设计：
/// - 每章只有一个"当前结果"（Map<index, result>），重试成功替换旧失败，
///   不会出现"后来成功了但旧失败还在"的幽灵失败。
/// - 进度 _done 恒等于成功缓存章数（派生值，不累计），不会超总数。
/// - 完成判定：目录非空 且 每一章都有有效缓存（不只看"无失败记录"）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../local_library.dart';
import '../local_platform.dart';
import 'source_client.dart';
import 'source_models.dart';

/// 章节正文拉取函数（由站点适配器提供）。
typedef ChapterFetcher =
    Future<SourceChapterContent> Function(
      SourceClient client,
      SourceChapter chapter,
    );

/// 下载进度回调：(成功章数, 总章数, 当前章节标题)。
typedef DownloadProgress = void Function(int done, int total, String current);

class SourceDownloadTask extends ChangeNotifier {
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

  /// 成功缓存的章节：index -> 正文。
  final Map<int, SourceChapterContent> _cache = {};

  /// 每章当前结果：index -> result（重试成功会替换旧失败）。
  final Map<int, SourceChapterResult> _results = {};

  List<SourceChapterResult> get results => List.unmodifiable(
    _results.values.toList()..sort((a, b) => a.chapter.index.compareTo(b.chapter.index)),
  );

  List<SourceChapterResult> get failedResults =>
      results.where((r) => !r.success).toList();

  /// 进度 = 成功缓存章数（派生，不累计）。
  int get done => _cache.length;
  int get total => detail.chapters.length;

  bool _cancelled = false;
  String? _error;
  String? get error => _error;

  void cancel() {
    _cancelled = true;
    notifyListeners();
  }

  /// 开始/继续下载。遇到 Cloudflare 挑战时抛 [SourceNeedVerify]，
  /// 由调用方打开 WebView 验证后再次调用本方法继续（已下载章节不重复）。
  ///
  /// 重复调用安全：已缓存章节直接跳过；失败章节会被重新尝试并替换旧结果。
  Future<void> start(DownloadProgress onProgress) async {
    if (_status == SourceDownloadStatus.downloading) return;
    if (detail.chapters.isEmpty) {
      _status = SourceDownloadStatus.failed;
      _error = '目录为空，无法下载';
      return;
    }
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
          onProgress(done, total, chapter.title);
          continue;
        }
        onProgress(done, total, chapter.title);
        SourceChapterContent? content;
        String? error;
        try {
          content = await fetcher(client, chapter);
          if (content.isEmpty) throw const SourceEmptyContent();
        } on SourceNeedVerify {
          // 取消优先：用户已取消则不再引导验证。
          if (_cancelled) {
            _status = SourceDownloadStatus.cancelled;
            return;
          }
          _status = SourceDownloadStatus.pausedNeedVerify;
          notifyListeners();
          rethrow;
        } catch (e) {
          error = e.toString();
        }
        // 请求返回后再次检查取消（最后一章取消也能生效）。
        if (_cancelled) {
          // 保留刚取得的有效正文，但按取消结束。
          if (content != null) {
            _cache[chapter.index] = content;
            _results[chapter.index] = SourceChapterResult(
              chapter: chapter,
              content: content,
            );
          }
          _status = SourceDownloadStatus.cancelled;
          return;
        }
        if (content != null) {
          _cache[chapter.index] = content;
          _results[chapter.index] = SourceChapterResult(
            chapter: chapter,
            content: content,
          );
        } else {
          _results[chapter.index] = SourceChapterResult(
            chapter: chapter,
            error: error ?? '未知错误',
          );
        }
        onProgress(done, total, chapter.title);
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 400));
        if (_cancelled) {
          _status = SourceDownloadStatus.cancelled;
          return;
        }
      }
      _finish();
    } catch (e) {
      if (e is SourceNeedVerify) rethrow;
      _status = SourceDownloadStatus.failed;
      _error = e.toString();
    }
  }

  void _finish() {
    if (_cancelled) {
      _status = SourceDownloadStatus.cancelled;
      return;
    }
    // 完成判定：每一章都必须有有效缓存（不只看"无失败记录"）。
    final missing = detail.chapters
        .where((c) => !_cache.containsKey(c.index))
        .toList();
    if (missing.isEmpty) {
      _status = SourceDownloadStatus.completed;
    } else {
      _status = SourceDownloadStatus.failed;
      _error = '${missing.length} 章未下载成功，可重试';
    }
    notifyListeners();
  }

  /// 重试失败章节（= 继续下载未缓存章节）。运行中调用直接返回。
  Future<void> retryFailed(DownloadProgress onProgress) =>
      start(onProgress);

  /// 生成 TXT 并入库。返回导入的 LocalBook，失败抛错。
  /// 有缺失章节时拒绝入库（不静默跳过）。
  ///
  /// 保存位置：用户已选择小说文件夹（SAF）时写入该文件夹并触发 scan()；
  /// 未选择时写入 App 内置目录并触发 scanAppFolder()。
  /// SAF 写入失败时直接抛错，不静默回退（避免用户以为存了却找不到）。
  Future<LocalBook> saveToLibrary() async {
    if (_status != SourceDownloadStatus.completed) {
      throw StateError('下载未完成，无法入库');
    }
    // 第二道完整性保障：保存前再次验证每一章都有缓存。
    final missing = detail.chapters
        .where((c) => !_cache.containsKey(c.index))
        .toList();
    if (missing.isNotEmpty) {
      throw StateError('${missing.length} 章缺失，无法入库');
    }
    final text = _buildTxt();
    final fileName = _fileName();
    final safFolder = local.folderUri;
    String actualFileName = fileName;
    if (safFolder != null && safFolder.isNotEmpty) {
      // SAF 文件夹：经原生层创建文档（同名自动重命名）。
      final created = await LocalPlatform.createTextDocument(
        safFolder,
        fileName,
        text,
      );
      actualFileName = created.fileName;
      await local.scan();
    } else {
      // App 内置目录。
      final dir = await _novelsDir();
      final file = File('$dir/$fileName');
      await file.writeAsString(text);
      await local.scanAppFolder();
    }
    var imported = local.books
        .where((b) => b.fileName == actualFileName)
        .cast<LocalBook?>();
    if (imported.isEmpty && safFolder != null && safFolder.isNotEmpty) {
      // SAF provider 可能有短暂同步延迟：重试一次扫描。
      await Future.delayed(const Duration(milliseconds: 600));
      await local.scan();
      imported = local.books
          .where((b) => b.fileName == actualFileName)
          .cast<LocalBook?>();
    }
    if (imported.isEmpty) {
      throw StateError('文件已保存（$actualFileName），但扫描暂未识别，请在本地书库点扫描');
    }
    return imported.first!;
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
    // 标记来源；同名文件已存在时 scanAppFolder 会按修改时间刷新，
    // 为避免覆盖用户已有同名书籍，加序号。
    var name = '$base [书源].txt';
    return name;
  }

  /// 生成 TXT：严格按 detail.chapters 顺序（用 _cache 按 index 取），
  /// 章节标题行符合本地 _chapterTitlePattern（第X章，≤42字）。
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
    for (final chapter in detail.chapters) {
      final content = _cache[chapter.index]!;
      buf.writeln(_chapterHeading(chapter.index, content.title));
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
    if (t.length <= 40 &&
        RegExp(r'^第[一二三四五六七八九十百千零〇两\d\s　]+[章节回集卷部篇]').hasMatch(t)) {
      return t;
    }
    var suffix = t
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
