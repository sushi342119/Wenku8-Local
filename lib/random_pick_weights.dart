import 'dart:math' as math;

/// 本轮有效权重：多本候选避开上一本，并奖励从未抽中过的书籍。
/// 先减去可参与候选的最小次数，避免大次数使所有权重一起下溢。
Map<int, double> buildRandomPickWeights(
  List<int> candidateIds,
  Map<int, int> drawCounts, {
  int? lastPickedId,
}) {
  final ids = candidateIds.toSet();
  final eligible = ids.where((id) => ids.length == 1 || id != lastPickedId);
  if (ids.isEmpty) return {};
  final minimum = eligible.map((id) => drawCounts[id] ?? 0).reduce(math.min);
  return {
    for (final id in ids)
      id: ids.length > 1 && id == lastPickedId
          ? 0.0
          : math.max(
              // 等价于给首次抽取 2 倍奖励；最大权重不超过 1。
              ((drawCounts[id] ?? 0) == 0 ? 1.0 : 0.5) *
                  math.pow(0.25, (drawCounts[id] ?? 0) - minimum).toDouble(),
              double.minPositive,
            ),
  };
}
