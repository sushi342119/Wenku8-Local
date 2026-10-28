import 'dart:math' as math;

import 'package:flutter/material.dart';

enum _PickPhase { idle, spinning, result }

/// 按权重和上的均匀随机落点抽样；无有效权重时退回均匀抽样。
@visibleForTesting
int sampleArchiveRandomPickIndex(List<double> weights, math.Random random) {
  if (weights.isEmpty) {
    throw ArgumentError.value(weights, 'weights', '候选不能为空');
  }
  final validWeights = [
    for (final weight in weights)
      weight.isFinite && weight > 0 ? weight : 0.0,
  ];
  final largest = validWeights.reduce(math.max);
  if (largest == 0) return random.nextInt(weights.length);

  // 同比例缩放，避免权重和溢出或极小权重乘随机落点时损失精度。
  for (var i = 0; i < validWeights.length; i++) {
    validWeights[i] /= largest;
  }
  final total = validWeights.fold(0.0, (sum, weight) => sum + weight);

  var point = random.nextDouble() * total;
  var lastPositive = 0;
  for (var i = 0; i < validWeights.length; i++) {
    final weight = validWeights[i];
    if (weight == 0) continue;
    lastPositive = i;
    if (point < weight) return i;
    point -= weight;
  }
  // 浮点舍入到总和边界时，仍只能落在正权重候选上。
  return lastPositive;
}

class ArchiveRandomPickCard<T extends Object> extends StatefulWidget {
  const ArchiveRandomPickCard({
    super.key,
    required this.books,
    required this.titleOf,
    required this.authorOf,
    required this.onOpenDetail,
    this.identityOf,
    this.weightOf,
    this.onPicked,
    this.filterHeader,
    this.emptyState,
  });

  final List<T> books;
  final String Function(T book) titleOf;
  final String Function(T book) authorOf;
  final ValueChanged<T> onOpenDetail;

  /// 有稳定的书籍 ID 时建议传入；未传入时按对象的 == 比较。
  final Object Function(T book)? identityOf;

  /// 默认均匀抽样；0、负数和非有限值不参与，全部无效时退回均匀抽样。
  final double Function(T book)? weightOf;

  /// 每次主动抽取确定结果时调用一次；单本候选的自动展示不计为抽取。
  final ValueChanged<T>? onPicked;

  final Widget? filterHeader;
  final Widget? emptyState;

  @override
  State<ArchiveRandomPickCard<T>> createState() =>
      _ArchiveRandomPickCardState<T>();
}

class _ArchiveRandomPickCardState<T extends Object>
    extends State<ArchiveRandomPickCard<T>>
    with SingleTickerProviderStateMixin {
  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _paper =>
      _dark ? const Color(0xFF1E211F) : const Color(0xFFFAF7F0);
  Color get _ink => _dark ? const Color(0xFFE8E2D6) : const Color(0xFF39352F);
  Color get _muted =>
      _dark ? const Color(0xFF9A917F) : const Color(0xFF6E665A);
  Color get _border =>
      _dark ? const Color(0xFF3A352C) : const Color(0xFFDCD4C6);
  Color get _accent =>
      _dark ? const Color(0xFFB89B6E) : const Color(0xFF715B42);
  Color get _shadow =>
      _dark ? const Color(0x40000000) : const Color(0x1439352F);

  static const _durationMs = 2400;

  // 时间轴：
  //    0–280ms  第一次洗牌
  //  280–620ms  第二次洗牌
  // 620–1020ms  第三次洗牌
  // 1020–1380ms 顶卡向上抽出 12px
  // 1380–1530ms 停顿 150ms
  // 1530–2180ms 翻面
  // 2180–2400ms 后卡淡出，结果卡归位
  static const _shuffleIntervals = <Interval>[
    Interval(0, 280 / _durationMs),
    Interval(280 / _durationMs, 620 / _durationMs),
    Interval(620 / _durationMs, 1020 / _durationMs),
  ];

  static const _liftInterval = Interval(
    1020 / _durationMs,
    1380 / _durationMs,
    curve: Curves.easeInOutCubic,
  );

  static const _flipInterval = Interval(
    1530 / _durationMs,
    2180 / _durationMs,
    curve: Curves.easeInOutCubic,
  );

  static const _finishInterval = Interval(
    2180 / _durationMs,
    1,
    curve: Curves.easeInOutCubic,
  );

  final math.Random _random = math.Random();

  late final AnimationController _controller;

  _PickPhase _phase = _PickPhase.idle;
  T? _displayedBook;
  int? _displayedIndex;

  // 使用独立快照，支持父组件原地修改同一个 List 后触发重建。
  List<Object> _identities = <Object>[];
  List<String> _titles = <String>[];
  List<String> _authors = <String>[];

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _durationMs),
    )..addStatusListener(_handleAnimationStatus);

    _captureSnapshot();
    _reset();
  }

  @override
  void didUpdateWidget(covariant ArchiveRandomPickCard<T> oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_booksChanged()) {
      _captureSnapshot();

      // didUpdateWidget 后框架会调用 build，无需 setState。
      _reset();
    } else {
      // 相同 ID、相同展示内容，但模型实例更新时使用最新实例。
      final index = _displayedIndex;
      if (index != null && index < widget.books.length) {
        _displayedBook = widget.books[index];
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // 动画途中开启“减少动态效果”，保留本轮结果并立即展示。
    if (_phase == _PickPhase.spinning && _reduceMotion) {
      _controller.stop();
      _phase = _PickPhase.result;
    }
  }

  Object _identity(T book) => widget.identityOf?.call(book) ?? book;

  void _captureSnapshot() {
    _identities = widget.books.map(_identity).toList(growable: false);
    _titles = widget.books.map(widget.titleOf).toList(growable: false);
    _authors = widget.books.map(widget.authorOf).toList(growable: false);
  }

  bool _booksChanged() {
    if (widget.books.length != _identities.length) {
      return true;
    }

    for (var i = 0; i < widget.books.length; i++) {
      final book = widget.books[i];

      if (_identity(book) != _identities[i] ||
          widget.titleOf(book) != _titles[i] ||
          widget.authorOf(book) != _authors[i]) {
        return true;
      }
    }

    return false;
  }

  void _reset() {
    _controller.stop();
    _controller.reset();

    if (widget.books.length == 1) {
      _displayedIndex = 0;
      _displayedBook = widget.books.first;
      _phase = _PickPhase.result;
    } else {
      _displayedIndex = null;
      _displayedBook = null;
      _phase = _PickPhase.idle;
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (!mounted ||
        status != AnimationStatus.completed ||
        _phase != _PickPhase.spinning) {
      return;
    }

    setState(() {
      _phase = _PickPhase.result;
    });
  }

  void _pick() {
    if (_phase == _PickPhase.spinning || widget.books.isEmpty) {
      return;
    }

    _controller.stop();
    _controller.reset();

    // 每轮只抽样一次，允许再次抽中上一本。
    // 洗牌阶段只显示卡背，不提前泄露书名和作者。
    final weightOf = widget.weightOf;
    final index = weightOf == null
        ? _random.nextInt(widget.books.length)
        : sampleArchiveRandomPickIndex(
            widget.books.map(weightOf).toList(growable: false),
            _random,
          );
    final skipAnimation = _reduceMotion || widget.books.length == 1;

    setState(() {
      _displayedIndex = index;
      _displayedBook = widget.books[index];
      _phase = skipAnimation ? _PickPhase.result : _PickPhase.spinning;
    });

    if (!skipAnimation) {
      _controller.forward();
    }
    widget.onPicked?.call(widget.books[index]);
  }

  void _openDetail() {
    final book = _displayedBook;

    if (_phase == _PickPhase.result && book != null) {
      widget.onOpenDetail(book);
    }
  }

  String _title(T book) {
    final title = widget.titleOf(book).trim();
    return title.isEmpty ? '未命名书籍' : title;
  }

  String _author(T book) {
    final author = widget.authorOf(book).trim();
    return author.isEmpty ? '佚名' : author;
  }

  String _archiveNumber(int index) {
    return 'ARC-${(index + 1).toString().padLeft(4, '0')}';
  }

  double _lerp(double start, double end, double t) {
    return start + (end - start) * t;
  }

  Offset _slotOffset(int rank) {
    // rank 0 为顶卡；后两张每层错开 5px。
    return Offset(rank * 5.0, rank * 5.0);
  }

  double _slotAngle(int rank) {
    return switch (rank) {
      0 => 0.0,
      1 => -0.018,
      _ => 0.025,
    };
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleAnimationStatus);
    _controller.dispose();
    super.dispose();
  }

  Widget _buildCardSurface({
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _paper,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: _shadow,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildCardBack(int cardId) {
    // 此处是索引卡编号，与随机结果无关。
    // 三张卡为洗牌道具，即使只有两本书也保持三张卡的视觉效果。
    return _buildCardSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '馆藏编号  ${_archiveNumber(cardId)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted,
              fontSize: 11,
              height: 1.4,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: _border),
          Expanded(
            child: Center(
              child: Text(
                '待抽阅',
                style: TextStyle(
                  fontFamily: 'serif',
                  color: _accent,
                  fontSize: 24,
                  height: 1.4,
                  letterSpacing: 5,
                ),
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: _border),
          const SizedBox(height: 12),
          Text(
            '馆藏索引 · 随机抽阅',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted,
              fontSize: 11,
              height: 1.4,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardFront(T book) {
    final index = _displayedIndex ?? 0;

    return _buildCardSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '馆藏编号  ${_archiveNumber(index)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted,
              fontSize: 11,
              height: 1.4,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: _border),
          const SizedBox(height: 16),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _title(book),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'serif',
                  color: _ink,
                  fontSize: 23,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _author(book),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: _border),
        ],
      ),
    );
  }

  Widget _buildFlipCard({
    required double progress,
    required T book,
    required int cardId,
  }) {
    // progress == 0.5 时恰好旋转 90°，在此切换卡背与正面。
    final showFront = progress >= 0.5;
    final angle = math.pi * progress;

    // 正面预先反转 π，避免外层翻转后文字呈镜像。
    final face = showFront
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.rotationY(math.pi),
            child: _buildCardFront(book),
          )
        : _buildCardBack(cardId);

    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.001);
    transform.multiply(Matrix4.rotationY(angle));

    return Transform(
      alignment: Alignment.center,
      transform: transform,
      child: face,
    );
  }

  Widget _buildDeck({
    required double cardWidth,
    required double cardHeight,
    required double stageWidth,
    required double stageHeight,
  }) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final isResult = _phase == _PickPhase.result;
        final isSpinning = _phase == _PickPhase.spinning;
        final time = isSpinning ? _controller.value : 0.0;
        final book = _displayedBook;

        final left = (stageWidth - cardWidth) / 2;
        final top = (stageHeight - cardHeight) / 2;

        if (isResult && book != null) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: left,
                top: top,
                width: cardWidth,
                height: cardHeight,
                child: _buildCardFront(book),
              ),
            ],
          );
        }

        // 从前到后的物理卡片顺序。完成一次洗牌后，把顶卡移到底部。
        final order = <int>[0, 1, 2];
        int? activeStep;

        for (var step = 0; step < _shuffleIntervals.length; step++) {
          final interval = _shuffleIntervals[step];

          if (time >= interval.end) {
            order.add(order.removeAt(0));
          } else {
            if (isSpinning && time >= interval.begin) {
              activeStep = step;
            }
            break;
          }
        }

        final offsets = <int, Offset>{};
        final angles = <int, double>{};

        for (var rank = 0; rank < order.length; rank++) {
          offsets[order[rank]] = _slotOffset(rank);
          angles[order[rank]] = _slotAngle(rank);
        }

        // Stack 按从后到前的顺序绘制。
        var paintOrder = order.reversed.toList(growable: false);

        if (activeStep != null) {
          final progress = _shuffleIntervals[activeStep].transform(time);
          final outgoing = order.first;

          // 前半程向侧面滑出，后半程收回到卡堆底部。
          final outgoingHalf = progress < 0.5;
          final halfProgress = outgoingHalf
              ? progress * 2
              : (progress - 0.5) * 2;
          final eased = Curves.easeInOutCubic.transform(halfProgress);

          final sideDistance = math.min(56.0, cardWidth * 0.22);
          final sideOffset = Offset(sideDistance, -3);

          offsets[outgoing] = outgoingHalf
              ? Offset.lerp(_slotOffset(0), sideOffset, eased)!
              : Offset.lerp(sideOffset, _slotOffset(2), eased)!;

          angles[outgoing] = outgoingHalf
              ? _lerp(_slotAngle(0), 0.065, eased)
              : _lerp(0.065, _slotAngle(2), eased);

          // 另外两张卡依次向前补位。
          final advance = Curves.easeInOutCubic.transform(progress);
          for (var rank = 1; rank < order.length; rank++) {
            final id = order[rank];
            offsets[id] = Offset.lerp(
              _slotOffset(rank),
              _slotOffset(rank - 1),
              advance,
            )!;
            angles[id] = _lerp(
              _slotAngle(rank),
              _slotAngle(rank - 1),
              advance,
            );
          }

          // 最侧方时切换遮挡关系，使顶卡回到卡堆底部。
          if (!outgoingHalf) {
            paintOrder = <int>[
              outgoing,
              ...order.skip(1).toList().reversed,
            ];
          }
        }

        final shuffleFinished = time >= 1020 / _durationMs;
        final lift = _liftInterval.transform(time);
        final flip = _flipInterval.transform(time);
        final finish = _finishInterval.transform(time);
        final topCardId = order.first;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final id in paintOrder)
              Positioned(
                key: ValueKey<int>(id),
                left: left,
                top: top,
                width: cardWidth,
                height: cardHeight,
                child: Opacity(
                  opacity: shuffleFinished && id != topCardId
                      ? 1 - finish
                      : 1,
                  child: Transform.translate(
                    offset: offsets[id]! +
                        Offset(
                          0,
                          shuffleFinished && id == topCardId
                              ? -12 * lift * (1 - finish)
                              : 0,
                        ),
                    child: Transform.rotate(
                      angle: angles[id]!,
                      child: shuffleFinished &&
                              id == topCardId &&
                              book != null
                          ? _buildFlipCard(
                              progress: flip,
                              book: book,
                              cardId: id,
                            )
                          : _buildCardBack(id),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildStage() {
    final book = _displayedBook;

    // 放大字体时增加卡片高度，避免固定高度压缩正文。
    final scaledTitleSize = MediaQuery.textScalerOf(context).scale(23);
    final extraHeight = math.max(0.0, scaledTitleSize - 23) * 7;
    final cardHeight = 248.0 + extraHeight;
    final stageHeight = cardHeight + 60;

    final semanticsLabel = switch (_phase) {
      _PickPhase.idle => '三张馆藏索引卡，待抽阅',
      _PickPhase.spinning => '正在洗牌抽阅',
      _PickPhase.result =>
        book == null ? '已选中' : '已选中：${_title(book)}，${_author(book)}',
    };

    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stageWidth = constraints.maxWidth;

            // 两侧预留滑出和阴影空间；宽屏时保持索引卡比例。
            final cardWidth = math.min(
              420.0,
              math.max(1.0, stageWidth - 64),
            );

            return SizedBox(
              height: stageHeight,
              width: double.infinity,
              child: RepaintBoundary(
                child: _buildDeck(
                  cardWidth: cardWidth,
                  cardHeight: cardHeight,
                  stageWidth: stageWidth,
                  stageHeight: stageHeight,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.filterHeader;

    if (widget.books.isEmpty) {
      final empty = widget.emptyState ?? const SizedBox.shrink();

      if (header == null) {
        return empty;
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 12),
          empty,
        ],
      );
    }

    final spinning = _phase == _PickPhase.spinning;
    final result = _phase == _PickPhase.result;

    final status = switch (_phase) {
      _PickPhase.idle => '待抽取',
      _PickPhase.spinning => '抽取中',
      _PickPhase.result => '已选中',
    };

    final buttonStyle = ElevatedButton.styleFrom(
      backgroundColor: _accent,
      foregroundColor: _dark ? const Color(0xFF1E211F) : Colors.white,
      disabledBackgroundColor: _border,
      disabledForegroundColor: _muted,
      elevation: 0,
      minimumSize: const Size(120, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null) ...[
          header,
          const SizedBox(height: 12),
        ],
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _paper,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '随机抽阅',
                        style: TextStyle(
                          fontFamily: 'serif',
                          fontSize: 21,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: _ink,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: _border),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        status,
                        style: TextStyle(
                          color: _muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '从当前展出的 ${widget.books.length} 本馆藏中，抽阅一本。',
                  style: TextStyle(
                    color: _muted,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 8),
                _buildStage(),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: spinning ? null : _pick,
                      style: buttonStyle,
                      child: Text(
                        spinning
                            ? '抽阅中…'
                            : result
                                ? '再抽一本'
                                : '抽阅一本',
                      ),
                    ),
                    if (result && _displayedBook != null)
                      TextButton(
                        onPressed: _openDetail,
                        style: TextButton.styleFrom(
                          foregroundColor: _accent,
                          minimumSize: const Size(96, 44),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                        child: const Text('查看详情'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
