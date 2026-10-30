/// 应用字体条目：内置字体为固定条目，导入字体为动态条目。
/// [id] 为稳定 ID，用于持久化保存用户选择；[family] 为 Flutter fontFamily，
/// 系统字体为 null（使用平台默认）。
class AppFontEntry {
  const AppFontEntry({
    required this.id,
    required this.displayName,
    this.family,
    required this.source,
    this.filePath,
  });

  final String id;
  final String displayName;
  final String? family;
  final AppFontSource source;

  /// 导入字体在应用私有目录中的绝对路径；内置/系统字体为 null。
  final String? filePath;

  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        if (family != null) 'family': family,
        'source': source.name,
        if (filePath != null) 'filePath': filePath,
      };

  factory AppFontEntry.fromJson(Map<String, Object?> json) {
    for (final key in ['id', 'displayName', 'family', 'source', 'filePath']) {
      if (json[key] != null && json[key] is! String) {
        throw const FormatException('字体记录字段类型错误');
      }
    }
    final source = switch (json['source']) {
      'imported' => AppFontSource.imported,
      'bundled' => AppFontSource.bundled,
      _ => AppFontSource.system,
    };
    return AppFontEntry(
      id: json['id'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '未知字体',
      family: json['family'] as String?,
      source: source,
      filePath: json['filePath'] as String?,
    );
  }
}

enum AppFontSource { system, bundled, imported }

/// 内置：系统字体。
const appFontSystem = AppFontEntry(
  id: 'system',
  displayName: '系统字体',
  family: null,
  source: AppFontSource.system,
);

/// 内置：思源宋体（随包发布）。
const appFontSourceHanSerif = AppFontEntry(
  id: 'sourceHanSerif',
  displayName: '内置思源宋体',
  family: 'SourceHanSerifCN',
  source: AppFontSource.bundled,
);

/// 兼容旧版：AppTypeface 枚举保留，状态层改用字体 ID。
enum AppTypeface {
  system('系统字体', null),
  sourceHanSerif('内置思源宋体', 'SourceHanSerifCN');

  const AppTypeface(this.label, this.family);
  final String label;
  final String? family;
  static AppTypeface fromRecord(Object? value) => value == 'sourceHanSerif'
      ? AppTypeface.sourceHanSerif
      : AppTypeface.system;
}
