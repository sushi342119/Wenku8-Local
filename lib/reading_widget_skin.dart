enum ReadingWidgetSkin {
  original('经典留白', '极简字卡与热力'),
  seasons('四季流转', '随节气更替的插画底色'),
  archive('书屿档案', '纸张肌理与档案排版'),
  editorial('画报刊头', '报刊折页与大字标题'),
  ink('水墨长卷', '东方宣纸与朱砂印记'),
  constellation('星轨观测', '深空夜读与星图刻度');

  const ReadingWidgetSkin(this.label, this.description);
  final String label;
  final String description;

  static ReadingWidgetSkin fromId(String? value) =>
      values.where((skin) => skin.name == value).firstOrNull ?? original;
}

int readingDailyGoal(int? value) => (value ?? 0).clamp(0, 1440);

String readingGoalCaption(int goalMinutes, int? todaySeconds) {
  final goal = readingDailyGoal(goalMinutes);
  if (goal <= 0) return '按自己的节奏阅读';
  final minutes = (todaySeconds ?? 0) ~/ 60;
  if (minutes >= goal) return '今日已达成 $goal 分钟目标（已读 $minutes 分钟）';
  return '每日目标 $goal 分钟 · 今日已读 $minutes 分钟';
}
