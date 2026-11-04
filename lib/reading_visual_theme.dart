import 'dart:ui';

/// Stable, shared identities for reports, excerpts, moments and home widgets.
/// Each surface composes live information around the shared original artwork.
enum ReadingVisualTheme {
  archive(
    '阅读档案',
    '档案索引 · 阅读分析',
    0xfff7f8f6,
    0xff18232c,
    0xff66727b,
    0xff2e769e,
    0xffc8d9e0,
  ),
  shelf(
    '书架索引',
    '书架陈列 · 藏书目录',
    0xffeef4f0,
    0xff183a30,
    0xff5c6c63,
    0xff3e7361,
    0xffbed3c7,
  ),
  editorial(
    '阅读年表',
    '纵向年表 · 阅读轨迹',
    0xfffaf6e9,
    0xff353126,
    0xff6f6854,
    0xff9b8141,
    0xffdad0ad,
  ),
  constellation(
    '星港夜航',
    '月下星港 · 阅读航迹',
    0xff101629,
    0xffe9edf7,
    0xffa5b0cd,
    0xffb4a3f5,
    0xff334267,
  ),
  signal(
    '行动档案',
    '战术归档 · 阅读行动',
    0xfff0f1e8,
    0xff1c292a,
    0xff5f6f69,
    0xff4f7e6c,
    0xffc8d098,
  ),
  score(
    '青春频率',
    '耳机电波 · 阅读节律',
    0xfffff4f3,
    0xff352f44,
    0xff786275,
    0xffc84d76,
    0xfff0bacd,
  ),
  ink(
    '云间书信',
    '玉色长风 · 纸上云信',
    0xfff6f4e9,
    0xff233e3b,
    0xff607167,
    0xffa4473a,
    0xffb8d1c7,
  ),
  festival(
    '晴空来信',
    '晴空列车 · 旅途书简',
    0xfff2f8fb,
    0xff1b3d54,
    0xff566f7d,
    0xffe47843,
    0xffaecedf,
  );

  const ReadingVisualTheme(
    this.label,
    this.description,
    this.backgroundValue,
    this.inkValue,
    this.mutedValue,
    this.accentValue,
    this.secondaryValue,
  );

  final String label, description;
  final int backgroundValue, inkValue, mutedValue, accentValue, secondaryValue;
  String get id => name;

  /// UI-only thumbnail. Native widgets retain their full approved artwork;
  /// reports and keepsakes use the separate export-asset registry.
  String get artAsset => 'assets/reading_previews/$name-117.webp';
  Color get background => Color(backgroundValue);
  Color get foreground => Color(inkValue);
  Color get muted => Color(mutedValue);
  Color get accent => Color(accentValue);
  Color get secondary => Color(secondaryValue);
  bool get isDark => this == constellation;
  bool get isAcg => index >= constellation.index;
  bool get prefersSerif => this == editorial || this == ink;

  static ReadingVisualTheme fromId(String? id) => switch (id) {
    'paper' || 'cream' => editorial,
    'night' => constellation,
    _ => values.where((theme) => theme.id == id).firstOrNull ?? archive,
  };
}
