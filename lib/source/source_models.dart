/// 书源试验版（source-trial 分支）：数据模型。
///
/// 首版只做单站点（123小说网）接入：搜索 → 详情 → 目录 → 正文 → 转本地 TXT。
library;

/// 书源搜索结果中的一本书。
class SourceBook {
  const SourceBook({
    required this.title,
    required this.author,
    required this.detailUrl,
    this.coverUrl,
    this.description,
    this.status,
  });

  final String title;
  final String author;

  /// 书籍详情页 URL（可能是相对路径，由调用方按基址解析）。
  final String detailUrl;
  final String? coverUrl;
  final String? description;

  /// 连载状态（如"连载中"/"已完结"），站点未提供时为 null。
  final String? status;
}

/// 书籍详情：基本信息 + 章节目录。
class SourceBookDetail {
  const SourceBookDetail({
    required this.book,
    required this.chapters,
  });

  final SourceBook book;

  /// 有序章节列表（阅读顺序）。
  final List<SourceChapter> chapters;
}

/// 单个章节。
class SourceChapter {
  const SourceChapter({
    required this.title,
    required this.url,
    required this.index,
  });

  final String title;

  /// 章节正文页 URL（可能是相对路径）。
  final String url;

  /// 在目录中的序号（0-based）。
  final int index;
}

/// 一章的正文。
class SourceChapterContent {
  const SourceChapterContent({
    required this.chapter,
    required this.title,
    required this.paragraphs,
  });

  final SourceChapter chapter;

  /// 正文页实际标题（可能与目录标题略有差异）。
  final String title;

  /// 正文段落（已清理广告/导航节点，保留段落顺序）。
  final List<String> paragraphs;

  bool get isEmpty => paragraphs.every((p) => p.trim().isEmpty);
}

/// 下载任务状态。
enum SourceDownloadStatus {
  idle,
  downloading,
  pausedNeedVerify,
  cancelled,
  failed,
  completed,
}

/// 单章下载结果。
class SourceChapterResult {
  const SourceChapterResult({
    required this.chapter,
    this.content,
    this.error,
  });

  final SourceChapter chapter;
  final SourceChapterContent? content;
  final String? error;

  bool get success => content != null && !content!.isEmpty;
}
