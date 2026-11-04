/// Independent home-screen compositions. Existing installations retain classic.
enum ReadingWidgetDesign {
  classic('随尺寸', '保留原有桌面主题'),
  focus('今日阅读', '一段阅读，留一点空白'),
  week('本周热力', '让一周的阅读有迹可循'),
  calendar('阅读日历', '把日子连成一片风景'),
  memory('阅读纪念', '为读过的故事留一席位置'),
  quote('摘录卡', '把喜欢的句子留在身边');

  const ReadingWidgetDesign(this.label, this.description);
  final String label, description;
  static ReadingWidgetDesign fromId(String? value) =>
      values.where((design) => design.name == value).firstOrNull ?? classic;
}
