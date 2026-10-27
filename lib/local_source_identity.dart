import 'dart:convert';

/// 本地书籍的来源身份：同一来源只生成一种忽略键。
///
/// appFolder 与 SAF 的来源字段不能互相覆盖：旧 appFolder 记录即使当前
/// 选中了 SAF 文件夹，仍属于 appFolder:novels；旧 SAF 记录则属于
/// 当初授权的 SAF 树。忽略键格式为 jsonEncode([sourceId, sourceKey])，
/// 与旧名单条目格式一致。
class LocalSourceIdentity {
  const LocalSourceIdentity._(this.sourceId, this.sourceKey);

  final String sourceId;
  final String sourceKey;

  String get ignoredKey => jsonEncode([sourceId, sourceKey]);

  factory LocalSourceIdentity.appFolder(String path) {
    return LocalSourceIdentity._(
      'appFolder:novels',
      _filePath(path),
    );
  }

  factory LocalSourceIdentity.saf(String treeUri, String sourceKey) {
    if (treeUri.isEmpty || sourceKey.isEmpty) {
      throw StateError('SAF 来源信息不完整');
    }
    return LocalSourceIdentity._('saf:$treeUri', sourceKey);
  }

  factory LocalSourceIdentity.forBook({
    required String sourceId,
    required String sourceKey,
    required String fileUri,
    required String? folderUri,
  }) {
    final storedKey = sourceKey.isNotEmpty ? sourceKey : fileUri;
    if (storedKey.isEmpty) {
      throw StateError('书籍没有可识别的源定位符');
    }
    // 已回填的记录保留自己的来源，不能被当前所选目录覆盖。
    if (sourceId == 'appFolder:novels') {
      return LocalSourceIdentity.appFolder(storedKey);
    }
    if (sourceId.isNotEmpty) {
      return LocalSourceIdentity._(sourceId, storedKey);
    }
    // 旧记录优先根据源 fileUri 判断所属来源。
    final locator = fileUri.isNotEmpty ? fileUri : storedKey;
    final uri = Uri.tryParse(locator);
    if (uri?.scheme == 'content') {
      // 旧 SAF 记录的树必须从它自身的 URI 里取，不能借用当前目录：
      // 当前目录已换成 B 时，借用 folderUri 会写出 B 的忽略键，
      // 以后扫描 A 时仍会重新导入。
      final parts = uri!.pathSegments;
      final documentAt = locator.indexOf('/document/');
      if (parts.length < 4 ||
          parts[0] != 'tree' ||
          parts[2] != 'document' ||
          documentAt < 0) {
        throw StateError('旧 SAF 记录缺少原目录身份，请先扫描原目录');
      }
      // 保留源 URI 中树前缀的原始编码，不借用当前 folderUri。
      return LocalSourceIdentity.saf(
        locator.substring(0, documentAt),
        storedKey,
      );
    }
    if (uri == null || !uri.hasScheme || uri.scheme == 'file') {
      // 旧 appFolder 记录即使当前选中了 SAF 文件夹，
      // 仍然使用 appFolder:novels + 源文件路径。
      return LocalSourceIdentity.appFolder(locator);
    }
    throw StateError('无法识别旧书籍的来源：${uri.scheme}');
  }

  static String _filePath(String value) {
    if (value.isEmpty) throw StateError('源文件路径不能为空');
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'file') {
      return uri!.toFilePath();
    }
    if (uri != null && uri.hasScheme) {
      throw StateError('appFolder 来源不是文件路径');
    }
    return value;
  }
}
