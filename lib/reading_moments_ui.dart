import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'app_interactions.dart';
import 'gallery_save_button.dart';
import 'local_platform.dart';
import 'reading_moment_content.dart';
import 'reading_moment_cover.dart';
import 'reading_moment_export.dart';
import 'reading_moment_reveal.dart';
import 'reading_moments.dart';
import 'reading_visual_theme.dart';
import 'reading_export_theme.dart';

/// This presenter never records, consumes or marks an event. The automatic
/// reader path alone takes a pending event before invoking the dialog.
Future<void> showReadingMoment(
  BuildContext context, {
  required ReadingMoment moment,
  required bool reduceMotion,
  bool celebrate = true,
  bool confetti = true,
  bool isPreview = false,
  ReadingVisualTheme theme = ReadingVisualTheme.archive,
}) async {
  final quiet = reduceMotion || MediaQuery.disableAnimationsOf(context);
  if (celebrate && !isPreview) AppHaptics.play(context, HapticCue.success);
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭阅读纪念',
    barrierColor: Colors.black.withValues(alpha: .36),
    transitionDuration: quiet
        ? Duration.zero
        : const Duration(milliseconds: 260),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, _, _) => ReadingMomentDialog(
      moment: moment,
      reduceMotion: quiet,
      celebrate: celebrate,
      confetti: confetti,
      isPreview: isPreview,
      theme: theme,
    ),
  );
}

Future<void> showReadingMomentPreview(
  BuildContext context, {
  required bool reduceMotion,
  required ReadingVisualTheme theme,
  bool confetti = true,
}) {
  final example = ReadingMomentPresentation.preview(theme);
  return showReadingMoment(
    context,
    moment: example.moment,
    reduceMotion: reduceMotion,
    confetti: confetti,
    isPreview: true,
    theme: theme,
  );
}

class ReadingMomentDialog extends StatefulWidget {
  const ReadingMomentDialog({
    super.key,
    required this.moment,
    required this.reduceMotion,
    this.celebrate = true,
    this.confetti = true,
    this.isPreview = false,
    this.theme = ReadingVisualTheme.archive,
  });
  final ReadingMoment moment;
  final bool reduceMotion, celebrate, confetti, isPreview;
  final ReadingVisualTheme theme;

  @override
  State<ReadingMomentDialog> createState() => _ReadingMomentDialogState();
}

class _ReadingMomentDialogState extends State<ReadingMomentDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;
  Animation<double>? _routeAnimation;
  bool _revealReady = false;
  Future<Uint8List?>? _coverLoading;
  Uint8List? _coverBytes;
  bool _coverResolved = false;
  bool _showBookDetails = true;
  bool _exporting = false;
  String? _feedback;
  bool _failedExport = false;

  ReadingMomentPresentation get _presentation => ReadingMomentPresentation(
    moment: widget.moment,
    theme: widget.theme,
    isPreview: widget.isPreview,
    showBookDetails: _showBookDetails,
    coverBytes: _coverBytes,
  );

  @override
  void initState() {
    super.initState();
    final animate = !widget.reduceMotion && widget.celebrate && widget.confetti;
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 960),
      value: animate ? 0 : 1,
    );
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
    final completion = widget.moment.completion;
    if (!widget.isPreview && completion != null) {
      _coverLoading = loadReadingMomentCover(completion).then((bytes) async {
        if (bytes != null && mounted) {
          await precacheImage(MemoryImage(bytes), context);
        }
        _coverResolved = true;
        _revealReady = true;
        if (mounted) {
          setState(() => _coverBytes = bytes);
          _startRevealWhenVisible();
        }
        return bytes;
      });
    } else {
      _revealReady = true;
    }
  }

  void _routeStatus(AnimationStatus _) => _startRevealWhenVisible();

  void _startRevealWhenVisible() {
    if (!mounted ||
        !_revealReady ||
        _reveal.value >= 1 ||
        _reveal.isAnimating) {
      return;
    }
    if (widget.reduceMotion || MediaQuery.disableAnimationsOf(context)) return;
    if (_routeAnimation != null &&
        _routeAnimation!.status != AnimationStatus.completed) {
      return;
    }
    _reveal.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (!identical(route, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_routeStatus);
      _routeAnimation = route;
      _routeAnimation?.addStatusListener(_routeStatus);
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.stop();
      _reveal.value = 1;
    }
    _startRevealWhenVisible();
  }

  Future<void> _export({
    required bool share,
    String? authorizationToken,
  }) async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _feedback = null;
      _failedExport = false;
    });
    try {
      if (_showBookDetails && !_coverResolved && _coverLoading != null) {
        await _coverLoading;
        if (!mounted) return;
      }
      if (!mounted) return;
      final bytes = await renderReadingMomentPresentationPng(
        context,
        _presentation,
      );
      if (!mounted) return;
      final name = widget.isPreview
          ? '阅读纪念-效果预览.png'
          : '阅读纪念-${widget.moment.kind.name}-${widget.moment.earnedAt.millisecondsSinceEpoch}.png';
      if (share) {
        await LocalPlatform.shareImage(bytes, name);
      } else {
        await LocalPlatform.saveImageToGallery(
          bytes,
          name,
          authorizationToken: authorizationToken,
        );
        if (mounted) showNovelFeedback(context, '已保存到相册');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failedExport = true;
          _feedback = share ? '分享未完成，请重试' : gallerySaveFailureMessage(error);
        });
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeStatus);
    _reveal.dispose();
    super.dispose();
  }

  Widget _fileActions(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scheme = Theme.of(context).colorScheme;
      final textSize = MediaQuery.textScalerOf(context).scale(14);
      final icons = constraints.maxWidth >= 300 && textSize <= 17;
      final vertical =
          constraints.maxWidth < textSize * 8 + 66 + (icons ? 50 : 0) ||
          (LocalPlatform.harmony &&
              constraints.maxWidth < GallerySaveButton.minimumWidth * 2 + 10);
      Widget label(String value, IconData icon) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icons) ...[ArchiveIcon(icon, size: 17), const SizedBox(width: 8)],
          AppText(value, style: const TextStyle(fontSize: 14)),
        ],
      );
      Widget saveLabel(VoidCallback? onPressed) => GlassTextButton(
        key: const ValueKey('reading-moment-save'),
        onPressed: onPressed,
        child: label('保存图片', CupertinoIcons.arrow_down_to_line),
      );
      final save = LocalPlatform.harmony && _reveal.value < 1
          ? saveLabel(null)
          : GallerySaveButton(
              enabled: !_exporting,
              foreground: scheme.surface,
              background: scheme.onSurface,
              onSave: (token) =>
                  _export(share: false, authorizationToken: token),
              onError: (error) => setState(() {
                _failedExport = true;
                _feedback = gallerySaveFailureMessage(error);
              }),
              builder: saveLabel,
            );
      final share = GlassTextButton(
        key: const ValueKey('reading-moment-share'),
        onPressed: _exporting ? null : () => _export(share: true),
        child: label(_exporting ? '正在生成' : '分享', CupertinoIcons.share),
      );
      return vertical
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [save, const SizedBox(height: 6), share],
            )
          : Row(
              children: [
                Expanded(child: save),
                const SizedBox(width: 10),
                Expanded(child: share),
              ],
            );
    },
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, available) => Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 344,
                maxHeight: available.maxHeight * .8,
              ),
              child: ReadingMomentReveal(
                animation: _reveal,
                accent: readingExportTheme(widget.theme).accent,
                child: Material(
                  color: scheme.surface,
                  shape: const BeveledRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    child: Column(
                      key: const ValueKey('reading-moment-popup'),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _MomentSheetHeader(
                          title: widget.isPreview ? '效果预览' : '阅读纪念',
                          subtitle:
                              '${widget.moment.earnedAt.year}年'
                              '${widget.moment.earnedAt.month}月${widget.moment.earnedAt.day}日',
                          closeKey: const ValueKey('reading-moment-close'),
                        ),
                        const SizedBox(height: 14),
                        Flexible(
                          child: SingleChildScrollView(
                            key: const ValueKey('reading-moment-popup-content'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Material(
                                color: Colors.transparent,
                                child: ReadingMomentContent(
                                  presentation: _presentation,
                                  compact: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (widget.moment.completion != null)
                          Row(
                            children: [
                              const ArchiveIcon(CupertinoIcons.eye, size: 18),
                              const SizedBox(width: 10),
                              const Expanded(child: AppText('书籍信息')),
                              AppControls.toggle(
                                context,
                                key: const ValueKey(
                                  'reading-moment-book-details',
                                ),
                                value: _showBookDetails,
                                onChanged: _exporting
                                    ? null
                                    : (value) => setState(
                                        () => _showBookDetails = value,
                                      ),
                              ),
                            ],
                          ),
                        if (LocalPlatform.fileActions) ...[
                          const SizedBox(height: 8),
                          _fileActions(context),
                        ],
                        if (_feedback != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Semantics(
                              liveRegion: true,
                              child: AppText(
                                _feedback!,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: _failedExport
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
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
      ),
    );
  }
}

class _MomentSheetHeader extends StatelessWidget {
  const _MomentSheetHeader({
    required this.title,
    required this.closeKey,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Key closeKey;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              title,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              AppText(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(width: 12),
      GlassIconButton(
        key: closeKey,
        icon: CupertinoIcons.xmark,
        label: '关闭$title',
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );
}

Future<void> showReadingMomentsHistory(
  BuildContext context, {
  required ReadingMomentsStore store,
  required bool reduceMotion,
}) => showJellySheet<void>(
  context: context,
  reduceMotion: reduceMotion,
  heightFactor: .82,
  maxWidth: 640,
  builder: (context) =>
      ReadingMomentsHistorySheet(store: store, reduceMotion: reduceMotion),
);

/// A modal history selector, not a destination page. Selecting a record shows
/// the same immutable dialog used by the reader without consuming its queue.
class ReadingMomentsHistorySheet extends StatelessWidget {
  const ReadingMomentsHistorySheet({
    super.key,
    required this.store,
    required this.reduceMotion,
  });
  final ReadingMomentsStore store;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final moments = store.moments;
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MomentSheetHeader(
              title: '阅读纪念',
              subtitle: moments.isEmpty ? null : '已珍藏 ${moments.length} 个时刻',
              closeKey: const ValueKey('reading-moments-history-close'),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: moments.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: AppText(
                          '每天读满五分钟，留下一个阅读日。\n值得记住的时刻，会在这里相遇。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, height: 1.8),
                        ),
                      ),
                    )
                  : ListView.separated(
                      key: const ValueKey('reading-moments-history-list'),
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: moments.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final moment = moments[index];
                        final completion = moment.completion;
                        final title = completion?.title.trim();
                        return InkWell(
                          key: ValueKey('reading-moment-history-${moment.id}'),
                          onTap: () => showReadingMoment(
                            context,
                            moment: moment,
                            reduceMotion: reduceMotion,
                            celebrate: false,
                            theme: ReadingVisualTheme.fromId(
                              store.preferences.themeId,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Row(
                              children: [
                                ArchiveIcon(
                                  completion != null
                                      ? CupertinoIcons.bookmark
                                      : moment.kind ==
                                            ReadingMomentKind.duration
                                      ? CupertinoIcons.clock
                                      : CupertinoIcons.sparkles,
                                  size: 21,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AppText(
                                        title != null && title.isNotEmpty
                                            ? title
                                            : moment.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          height: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      AppText(
                                        '${readingMomentDate(moment.earnedAt)} · ${completion != null
                                            ? completion.finished
                                                  ? '读完留念'
                                                  : '读到当前结尾'
                                            : moment.subtitle}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.5,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const ArchiveIcon(
                                  CupertinoIcons.chevron_right,
                                  size: 14,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}
