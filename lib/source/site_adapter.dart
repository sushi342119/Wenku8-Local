/// 书源试验版（source-trial 分支）：站点适配器接口。
///
/// 首版只实现 123小说网（[Site123XiaoShuo]）。接口与具体站点解耦，
///
/// 新增站点时只需实现本接口，无需改动下载、入库链路。
library;

import 'source_client.dart';
import 'source_models.dart';

/// 站点适配器：把站点 HTML 解析为统一模型。
abstract interface class SiteAdapter {
  /// 站点显示名（如"123小说网"）。
  String get siteName;

  /// 搜索。返回业务页面被 Cloudflare 拦截时抛 [SiteNeedVerify]。
  Future<List<SourceBook>> search(SourceClient client, String keyword);

  /// 书籍详情（含目录）。
  Future<SourceBookDetail> detail(SourceClient client, SourceBook book);

  /// 单章正文。
  Future<SourceChapterContent> content(
    SourceClient client,
    SourceChapter chapter,
  );
}

/// 需要用户完成网站验证（client 侧检测到挑战页时抛给上层）。
class SiteNeedVerify implements Exception {
  const SiteNeedVerify([this.message = '需要完成网站验证']);
  final String message;
  @override
  String toString() => message;
}
