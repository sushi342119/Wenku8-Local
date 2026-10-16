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
