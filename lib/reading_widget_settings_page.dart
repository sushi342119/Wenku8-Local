import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_interactions.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'reading_widget_controller.dart';
import 'reading_widget_design.dart';
import 'reading_widget_reference.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_skin_picker.dart';
import 'reading_widget_cards.dart';

class ReadingWidgetSettingsPage extends StatefulWidget {
  const ReadingWidgetSettingsPage({
    super.key,
    required this.state,
    this.bindTo,
  });
  final LibraryState state;
  final String? bindTo;
  @override
  State<ReadingWidgetSettingsPage> createState() => _WidgetCardsPageState();
}

class _WidgetCardsPageState extends State<ReadingWidgetSettingsPage> {
  late final cards = ReadingWidgetCards.forState(widget.state);
  String? _bindingCard;
  @override
  void initState() {
    super.initState();
    unawaited(
      ReadingWidgetController.forState(
        widget.state,
      ).attach().then((_) => cards.attach()),
    );
  }

  Future<void> _open(ReadingWidgetCardConfig card) async {
    if (widget.bindTo != null) {
      if (_bindingCard != null) return;
      setState(() => _bindingCard = card.id);
      try {
        await cards.publish();
        if (!mounted) return;
        if (cards.error != null) throw StateError(cards.error!);
        await ReadingWidgetBridge.channel.invokeMethod<void>('bindCard', {
          'widgetId': widget.bindTo,
          'cardId': card.id,
        });
        if (mounted) {
          showNovelFeedback(context, '已设置此小组件');
          Navigator.pop(context, true);
        }
      } catch (_) {
        if (mounted) showNovelFeedback(context, '小组件未能设置，请重试');
      } finally {
        if (mounted) setState(() => _bindingCard = null);
      }
    } else {
      await pushNovelPage<void>(
        context,
        ReadingWidgetCardEditor(state: widget.state, cardId: card.id),
        reduceMotion: widget.state.reduceMotion,
      );
    }
  }

  Future<void> _add() async {
    final design = await showJellySheet<ReadingWidgetDesign>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppText(
              '选择桌面内容',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            for (final design in ReadingWidgetCards.designs)
              GlassTextButton(
                onPressed: () => Navigator.pop(context, design),
                child: AppText(design.label),
              ),
          ],
        ),
      ),
    );
    if (design == null) return;
    final card = await cards.add(design);
    if (mounted) await _open(card);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _bindingCard == null,
    child: ArchiveFeaturePage(
      title: widget.bindTo == null ? '小组件' : '选择桌面内容',
      code: 'READING / WIDGETS',
      canPop: _bindingCard == null,
      child: AnimatedBuilder(
        animation: cards,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListView(
              padding: featurePadding(context),
              children: [
                for (final card in cards.cards)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: ContentPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: AppText(
                                  card.label,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              GlassTextButton(
                                onPressed: _bindingCard == null
                                    ? () => _open(card)
                                    : null,
                                compact: true,
                                child: AppText(
                                  widget.bindTo == null
                                      ? '设置'
                                      : _bindingCard == card.id
                                      ? '正在设置'
                                      : '使用此卡片',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          AspectRatio(
                            aspectRatio: 364 / 170,
                            child: FittedBox(
                              child: _cardPreview(
                                widget.state,
                                cards,
                                card,
                                ReadingDesktopSize.medium,
                                context,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                GlassTextButton(
                  onPressed: _bindingCard == null ? _add : null,
                  child: const AppText('新建小组件'),
                ),
                if (cards.error != null)
                  GlassTextButton(
                    onPressed: cards.publish,
                    child: AppText(cards.error!),
                  ),
                if (widget.bindTo == null) ...[
                  const SizedBox(height: 16),
                  const AppText(
                    '添加到桌面时选择内容与尺寸。每张卡片单独设置，可同时放置不同内容。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _cardPreview(
  LibraryState state,
  ReadingWidgetCards cards,
  ReadingWidgetCardConfig card,
  ReadingDesktopSize size,
  BuildContext context, {
  ReadingWidgetSkin? skin,
}) {
  final quote = cards.quotes(details: card.showBookDetails);
  return ReadingDesktopCard(
    data: ReadingWidgetController.forState(state).snapshot.styled(
      design: card.design,
      skin: skin ?? card.skin,
      showBookDetails: card.showBookDetails,
    ),
    size: size,
    brightness: switch (card.appearance) {
      ReadingWidgetAppearance.system => Theme.of(context).brightness,
      ReadingWidgetAppearance.light => Brightness.light,
      ReadingWidgetAppearance.dark => Brightness.dark,
    },
    quoteText: quote.firstOrNull?['text'],
    quoteSource: quote.firstOrNull?['source'] ?? '',
    quoteCount: quote.length,
  );
}

class ReadingWidgetCardEditor extends StatefulWidget {
  const ReadingWidgetCardEditor({
    super.key,
    required this.state,
    required this.cardId,
  });
  final LibraryState state;
  final String cardId;
  @override
  State<ReadingWidgetCardEditor> createState() =>
      _ReadingWidgetSettingsPageState();
}

class _ReadingWidgetSettingsPageState extends State<ReadingWidgetCardEditor> {
  late final _controller = ReadingWidgetController.forState(widget.state);
  late final _cards = ReadingWidgetCards.forState(widget.state);
  ReadingWidgetCardConfig get _card =>
      _cards.cards.firstWhere((card) => card.id == widget.cardId);
  bool _saving = true;
  String? _notice;
  ReadingDesktopSize _previewSize = ReadingDesktopSize.small;
  ReadingWidgetDesign get _design => _card.design;
  ReadingWidgetSkin get _skin => _card.skin;
  TextStyle get _supporting => TextStyle(
    fontSize: 13,
    height: 1.6,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      await _controller.attach();
      await _cards.attach();
      if (!mounted) return;
    } catch (_) {
      _notice = '设置暂未加载，请重试';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _configure({
    ReadingWidgetSkin? skin,
    int? dailyGoalMinutes,
    bool? details,
    ReadingWidgetAppearance? appearance,
  }) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      if (dailyGoalMinutes != null) {
        await _controller.configure(dailyGoalMinutes: dailyGoalMinutes);
      }
      await _cards.update(
        _card.copyWith(
          skin: skin,
          showBookDetails: details,
          appearance: appearance,
        ),
      );
      if (!mounted) return;
      if (_cards.error case final error?) {
        setState(() => _notice = error);
      } else {
        showNovelFeedback(context, '桌面组件设置已更新');
      }
    } catch (_) {
      if (mounted) setState(() => _notice = '桌面设置未能保存，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editGoal() async {
    final value = await showJellySheet<int>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (_) => _ReadingGoalEditor(initial: _controller.dailyGoalMinutes),
    );
    if (value != null && mounted) await _configure(dailyGoalMinutes: value);
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: _card.label,
    code: 'READING / WIDGETS',
    child: AnimatedBuilder(
      animation: Listenable.merge([_controller, _cards]),
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            key: const ValueKey('reading-widget-settings-list'),
            padding: featurePadding(context),
            children: [
              const ArchiveSection(title: '画面风格', code: '01 / APPEARANCE'),
              const SizedBox(height: 14),
              AppControls.segments<ReadingDesktopSize>(
                context,
                groupValue: _previewSize,
                children: {
                  for (final size in ReadingDesktopSize.values)
                    size: AppText(switch (size) {
                      ReadingDesktopSize.small => '小 2×2',
                      ReadingDesktopSize.medium => '中 4×2',
                      ReadingDesktopSize.large => '大 4×4',
                    }, key: ValueKey('reading-widget-size-${size.name}')),
                },
                onValueChanged: (size) {
                  if (size != null) setState(() => _previewSize = size);
                },
              ),
              const SizedBox(height: 16),
              ReadingWidgetSkinPicker(
                previewBuilder: (skin) => _cardPreview(
                  widget.state,
                  _cards,
                  _card,
                  _previewSize,
                  context,
                  skin: skin,
                ),
                value: _skin,
                size: _previewSize,
                snapshot: _controller.snapshot.styled(
                  design: _design,
                  skin: _skin,
                  showBookDetails: _card.showBookDetails,
                ),
                onChanged: _saving ? null : (skin) => _configure(skin: skin),
              ),
              const SizedBox(height: 28),
              const ArchiveSection(title: '显示模式', code: '02 / APPEARANCE'),
              const SizedBox(height: 14),
              AppControls.segments<ReadingWidgetAppearance>(
                context,
                groupValue: _card.appearance,
                children: const {
                  ReadingWidgetAppearance.system: AppText('跟随系统'),
                  ReadingWidgetAppearance.light: AppText('浅色'),
                  ReadingWidgetAppearance.dark: AppText('深色'),
                },
                onValueChanged: (value) {
                  if (!_saving) _configure(appearance: value);
                },
              ),
              const SizedBox(height: 28),
              const ArchiveSection(title: '阅读目标', code: '03 / GOAL'),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      _controller.dailyGoalMinutes == 0
                          ? '按自己的节奏阅读'
                          : readingGoalCaption(
                              _controller.dailyGoalMinutes,
                              _controller.snapshot.verifiedTodaySeconds,
                            ),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final goal in [0, 15, 30, 60])
                          GlassTextButton(
                            key: ValueKey('reading-goal-$goal'),
                            compact: true,
                            selected: _controller.dailyGoalMinutes == goal,
                            onPressed: _saving
                                ? null
                                : () => _configure(dailyGoalMinutes: goal),
                            child: AppText(goal == 0 ? '不设目标' : '$goal 分钟'),
                          ),
                        GlassTextButton(
                          key: const ValueKey('reading-goal-custom'),
                          compact: true,
                          selected: ![
                            0,
                            15,
                            30,
                            60,
                          ].contains(_controller.dailyGoalMinutes),
                          onPressed: _saving ? null : _editGoal,
                          child: AppText(
                            [
                                  0,
                                  15,
                                  30,
                                  60,
                                ].contains(_controller.dailyGoalMinutes)
                                ? '自定义'
                                : '${_controller.dailyGoalMinutes} 分钟',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              const ArchiveSection(title: '显示与更新', code: '04 / DISPLAY'),
              const SizedBox(height: 14),
              ContentPanel(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppText(
                            '显示书籍信息',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          AppText('在桌面显示书名与章节', style: _supporting),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Semantics(
                      label: '显示书籍信息',
                      child: AppControls.toggle(
                        context,
                        key: const ValueKey('reading-widget-book-details'),
                        value: _card.showBookDetails,
                        onChanged: _saving
                            ? null
                            : (value) => _configure(details: value),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassTextButton(
                key: const ValueKey('reading-widget-refresh'),
                onPressed: _saving ? null : () => _configure(),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const ArchiveIcon(CupertinoIcons.arrow_clockwise, size: 18),
                    const SizedBox(width: 10),
                    AppText(_saving ? '正在更新' : '更新桌面组件'),
                  ],
                ),
              ),
              if (_notice ?? _controller.error case final String notice)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: AppText(notice, style: _supporting),
                  ),
                ),
              const SizedBox(height: 18),
              AppText(
                LocalPlatform.ios
                    ? '长按主屏幕空白处，添加“阅读留白”小组件。'
                    : LocalPlatform.harmony
                    ? '长按应用图标，添加阅读服务卡片。'
                    : '长按桌面空白处，进入小组件并找到“阅读留白”。',
                style: _supporting,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReadingGoalEditor extends StatefulWidget {
  const _ReadingGoalEditor({required this.initial});
  final int initial;
  @override
  State<_ReadingGoalEditor> createState() => _ReadingGoalEditorState();
}

class _ReadingGoalEditorState extends State<_ReadingGoalEditor> {
  late final _input = TextEditingController(
    text: widget.initial > 0 ? '${widget.initial}' : '',
  );
  String? _error;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_input.text.trim());
    if (value == null || value < 1 || value > 1440) {
      setState(() => _error = '请输入 1–1440 分钟');
    } else {
      Navigator.pop(context, value);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppText(
          '每日阅读目标',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),
        TextField(
          key: const ValueKey('reading-goal-input'),
          controller: _input,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            labelText: '分钟',
            hintText: '例如 30',
            errorText: _error,
          ),
        ),
        const SizedBox(height: 24),
        GlassTextButton(onPressed: _save, child: const AppText('保存')),
        const SizedBox(height: 8),
        GlassTextButton(
          onPressed: () => Navigator.pop(context),
          child: const AppText('取消'),
        ),
      ],
    ),
  );
}
