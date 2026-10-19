/// 书源试验版（source-trial 分支）：123小说网 站点适配器。
///
/// 解析规则待网站结构探查完成后填写。
library;

import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'site_adapter.dart';
import 'source_client.dart';
import 'source_config.dart';
import 'source_download.dart';
import 'source_models.dart';

class Site123Adapter implements SiteAdapter {
  @override
  String get siteName => '123小说网';

  String _base() => SourceConfig.instance.baseUrl;

  String _resolve(String url) => SourceConfig.instance.resolve(url);

  /// 拉取页面；命中挑战时抛 [SiteNeedVerify]（由上层打开 WebView）。
  Future<Document> _fetchDocument(SourceClient client, Uri uri) async {
    final page = await client.get(uri);
    if (page.challenged) throw const SiteNeedVerify();
    if (page.statusCode != 200) {
      throw HttpException('请求失败（${page.statusCode}）');
    }
    final doc = html_parser.parse(page.html);
    // 二次确认：解析出的不是挑战页。
    final title = doc.querySelector('title')?.text ?? '';
    if (title.toLowerCase().contains('just a moment')) {
      throw const SiteNeedVerify();
    }
    return doc;
  }

  @override
  Future<List<SourceBook>> search(SourceClient client, String keyword) async {
    // TODO: 探查确认搜索 URL 与结果选择器后实现。
    throw UnimplementedError('search 待实现');
  }

  @override
  Future<SourceBookDetail> detail(SourceClient client, SourceBook book) async {
    // TODO: 探查确认详情页结构后实现。
    throw UnimplementedError('detail 待实现');
  }

  @override
  Future<SourceChapterContent> content(
    SourceClient client,
    SourceChapter chapter,
  ) async {
    // TODO: 探查确认正文页结构后实现。
    throw UnimplementedError('content 待实现');
  }
}
