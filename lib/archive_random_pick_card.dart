import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum _PickPhase { idle, spinning, result }

class ArchiveRandomPickCard<T extends Object> extends StatefulWidget {
  const ArchiveRandomPickCard({
    super.key,
    required this.books,
    required this.titleOf,
    required this.authorOf,
    required this.onOpenDetail,
    this.identityOf,
  });

  final List<T> books;
  final String Function(T book) titleOf;
  final String Function(T book) authorOf;
  final ValueChanged<T> onOpenDetail;

  /// 有稳定的书籍 ID 时建议传入；未传入时按对象的 == 比较。
  final Object Function(T book)? identityOf;

  @override
  State<ArchiveRandomPickCard<T>> createState() =>
      _ArchiveRandomPickCardState<T>();
}

class _ArchiveRandomPickCardState<T extends Object>
    extends State<ArchiveRandomPickCard<T>> {
  static const _paper = Color(0xFFFAF7F0);
  static const _ink = Color(0xFF39352F);
  static const _muted = Color(0xFF81786B);
  static const _border = Color(0xFFDCD4C6);
  static const _accent = Color(0xFF715B42);

  // 10 次切换，共 1600ms，最后一次落定结果。
  static const _intervals = <int>[
    60,
    80,
    100,
    120,
    140,
    160,
    190,
    220,
    250,
    280,
  ];

  final math.Random _random = math.Random();

  Timer? _timer;
  _PickPhase _phase = _PickPhase.idle;
  T? _displayedBook;
  int? _displayedIndex;
  int _switchSerial = 0;
  int _runToken = 0;

  // 保存独立快照，支持父组件原地修改同一 List 后触发重建。
  List<Object> _identities = <Object>[];
  List<String> _titles = <String>[];
  List<String> _authors = <String>[];

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
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

    // 抽取过程中打开“减少动态效果”，立即结束动画。
    if (_phase == _PickPhase.spinning && _reduceMotion) {
      _cancelRun();
      _selectFinalBook();
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

  void _cancelRun() {
    _timer?.cancel();
    _timer = null;
    _runToken++;
  }

  void _reset() {
    _cancelRun();
    _switchSerial++;

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

  void _setDisplayedIndex(int index) {
    _displayedIndex = index;
    _displayedBook = widget.books[index];
    _switchSerial++;
  }

  // 动画展示时避免连续出现同一本。
  int _nextPreviewIndex() {
    final length = widget.books.length;
    final previous = _displayedIndex;

    if (length <= 1) return 0;
    if (previous == null || previous >= length) {
      return _random.nextInt(length);
    }

    final candidate = _random.nextInt(length - 1);
    return candidate >= previous ? candidate + 1 : candidate;
  }

  // 最终结果独立均匀抽样，允许再次抽中上一本。
  void _selectFinalBook() {
    if (widget.books.isEmpty) {
      _phase = _PickPhase.idle;
      _displayedBook = null;
      _displayedIndex = null;
      return;
    }

    _setDisplayedIndex(_random.nextInt(widget.books.length));
    _phase = _PickPhase.result;
  }

  void _pick() {
    if (_phase == _PickPhase.spinning || widget.books.isEmpty) {
      return;
    }

    _cancelRun();

    if (_reduceMotion || widget.books.length == 1) {
      setState(_selectFinalBook);
      return;
    }

    setState(() {
      _phase = _PickPhase.spinning;
      _setDisplayedIndex(_nextPreviewIndex());
    });

    _scheduleStep(0, _runToken);
  }

  void _scheduleStep(int step, int token) {
    _timer = Timer(Duration(milliseconds: _intervals[step]), () {
      if (!mounted || token != _runToken) return;
      _timer = null;

      if (step == _intervals.length - 1 || _reduceMotion) {
        setState(_selectFinalBook);
        return;
      }

      setState(() {
        _setDisplayedIndex(_nextPreviewIndex());
      });

      _scheduleStep(step + 1, token);
    });
  }

  String _title(T book) {
    final title = widget.titleOf(book).trim();
    return title.isEmpty ? '未命名书籍' : title;
  }

  String _author(T book) {
    final author = widget.authorOf(book).trim();
    return author.isEmpty ? '佚名' : author;
  }

  @override
  void dispose() {
    _cancelRun();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.books.isEmpty) {
      return const SizedBox.shrink();
    }

    final spinning = _phase == _PickPhase.spinning;
    final result = _phase == _PickPhase.result;
    final book = _displayedBook;

    final status = switch (_phase) {
      _PickPhase.idle => '待抽取',
      _PickPhase.spinning => '抽取中',
      _PickPhase.result => '已选中',
    };

    final buttonStyle = ElevatedButton.styleFrom(
      backgroundColor: _accent,
      foregroundColor: Colors.white,
      disabledBackgroundColor: _border,
      disabledForegroundColor: _muted,
      elevation: 0,
      minimumSize: const Size(120, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );

    return Container(
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
                const Expanded(
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
                    style: const TextStyle(
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
              '从当前展出的 ${widget.books.length} 本中，抽取一本',
              style: const TextStyle(
                fontSize: 13,
                height: 1.6,
                color: _muted,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Divider(height: 1, thickness: 1, color: _border),
            ),
            Semantics(
              liveRegion: result,
              label: result && book != null
                  ? '已选中：${_title(book)}，作者：${_author(book)}'
                  : spinning
                      ? '正在抽取书籍'
                      : '等待抽取书籍',
              child: ExcludeSemantics(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 88),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedSwitcher(
                      duration: _reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 55),
                      reverseDuration: _reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 40),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        );
                      },
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                      },
                      child: SizedBox(
                        key: ValueKey(_switchSerial),
                        width: double.infinity,
                        child: book == null
                            ? const Text(
                                '翻开一份意外的阅读档案。',
                                style: TextStyle(
                                  fontFamily: 'serif',
                                  fontSize: 17,
                                  height: 1.6,
                                  color: _muted,
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _title(book),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'serif',
                                      fontSize: 20,
                                      height: 1.4,
                                      fontWeight: FontWeight.w600,
                                      color: _ink,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _author(book),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.5,
                                      color: _muted,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (result && book != null)
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton(
                    style: buttonStyle,
                    onPressed: () => widget.onOpenDetail(book),
                    child: const Text('开始阅读'),
                  ),
                  TextButton(
                    // 只有一本时直接展示结果，不进行无意义的重复抽取。
                    onPressed: widget.books.length > 1 ? _pick : null,
                    style: TextButton.styleFrom(
                      foregroundColor: _accent,
                      minimumSize: const Size(100, 44),
                    ),
                    child: const Text('再抽一次'),
                  ),
                ],
              )
            else
              ElevatedButton(
                style: buttonStyle,
                onPressed: spinning ? null : _pick,
                child: Text(spinning ? '抽取中…' : '抽取一本'),
              ),
          ],
        ),
      ),
    );
  }
}
