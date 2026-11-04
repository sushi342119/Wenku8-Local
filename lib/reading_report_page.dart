import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'gallery_save_button.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'reading_export_theme.dart';
import 'reading_report_options.dart';
import 'reading_report_range.dart';
import 'reading_statistics_analysis_view.dart';
import 'reading_statistics_data.dart';
import 'reading_visual_theme_picker.dart';

class ReadingReportPage extends StatefulWidget {
  const ReadingReportPage({
    super.key,
    required this.state,
    required this.repository,
    this.now,
    this.initialRange,
  });

  final LibraryState state;
  final NovelRepository repository;
  final DateTime? now;
  final ReadingReportRange? initialRange;

  @override
  State<ReadingReportPage> createState() => _ReadingReportPageState();
}

class _ReadingReportPageState extends State<ReadingReportPage> {
  final _posterKey = GlobalKey();
  ReadingReportOptions _options = const ReadingReportOptions();
  late ReadingStatisticsData _data;

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRange;
    if (initial != null) {
      _options = _options.copyWith(
        period: initial.period,
        from: initial.from,
        until: initial.until,
        clearDates: !initial.custom,
      );
    }
    _rebuildData();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final loaded = await ReadingReportOptions.load();
    if (!mounted) return;
    final initial = widget.initialRange;
    setState(() {
      _options = initial == null
          ? loaded
          : loaded.copyWith(
              period: initial.period,
              from: initial.from,
              until: initial.until,
              clearDates: !initial.custom,
            );
      _rebuildData();
    });
  }

  void _rebuildData() {
    final end = _options.endAt(_now);
    final days = _options.daysAt(_now);
    _data = ReadingStatisticsData(
      state: widget.state,
      repository: widget.repository,
      now: end,
      period: days,
      snapshotAt: _now,
    );
  }

  Future<void> _update(ReadingReportOptions next) async {
    setState(() {
      _options = next;
      _rebuildData();
    });
    await next.save();
  }

  Future<void> _savePoster(String? token) async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        _posterKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('报告画布尚未就绪');
    final image = await boundary.toImage(pixelRatio: 2.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData == null) throw StateError('报告生成失败');
    await LocalPlatform.saveImageToGallery(
      byteData.buffer.asUint8List(),
      'wenku8-reading-report-${DateTime.now().millisecondsSinceEpoch}.png',
      authorizationToken: token,
    );
    if (mounted) showNovelFeedback(context, '阅读报告已保存到相册');
  }

  @override
  Widget build(BuildContext context) {
    final exportTheme = readingExportTheme(_options.template.theme);
    final artAsset = readingExportArt(_options.template.theme, at: _now);
    return ArchiveFeaturePage(
      title: '八式阅读报告',
      code: 'STATISTICS / REPORT POSTER',
      child: ListView(
        padding: featurePadding(context),
        children: [
          const ArchiveSection(title: '报告画风', code: 'REPORT / 8 THEMES'),
          const SizedBox(height: 12),
          ReadingVisualThemePicker(
            value: _options.template.theme,
            presentationFor: (theme) =>
                ReadingVisualThemePresentation.fromExportTheme(theme, at: _now),
            onChanged: (theme) {
              final template = ReadingReportTemplate.values.firstWhere(
                (item) => item.theme == theme,
                orElse: () => ReadingReportTemplate.archive,
              );
              _update(_options.copyWith(template: template));
            },
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final period in const [7, 30, 90, 365])
                GlassTextButton(
                  compact: true,
                  selected:
                      !_options.range.custom && _options.period == period,
                  onPressed: () => _update(
                    _options.copyWith(period: period, clearDates: true),
                  ),
                  child: AppText('近 $period 天'),
                ),
              GlassTextButton(
                compact: true,
                selected: _options.range.custom,
                onPressed: () async {
                  final picked = await pickReadingReportRange(
                    context,
                    now: _now,
                    range: _options.range,
                  );
                  if (picked != null && mounted) {
                    await _update(
                      _options.copyWith(from: picked.start, until: picked.end),
                    );
                  }
                },
                child: const AppText('自定义区间'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          RepaintBoundary(
            key: _posterKey,
            child: Container(
              decoration: BoxDecoration(
                color: exportTheme.background,
                borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 180,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.asset(
                          artAsset,
                          fit: BoxFit.cover,
                          alignment: exportTheme.previewAlignment,
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                exportTheme.background.withValues(alpha: 0.15),
                                exportTheme.background,
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 16,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText(
                                '${exportTheme.label} · ${_options.title}',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: exportTheme.foreground,
                                ),
                              ),
                              const SizedBox(height: 4),
                              AppText(
                                '${statisticsDate(_data.dates.first)} — ${statisticsDate(_data.dates.last)} · 累计 ${statisticsDuration(_data.periodSeconds)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: exportTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: exportTheme.foreground),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _ReportMetricTile(
                                  label: '活跃天数',
                                  value: '${_data.activeDays} 天',
                                  foreground: exportTheme.foreground,
                                  muted: exportTheme.muted,
                                ),
                              ),
                              Expanded(
                                child: _ReportMetricTile(
                                  label: '最长连续',
                                  value: '${_data.longestStreak} 天',
                                  foreground: exportTheme.foreground,
                                  muted: exportTheme.muted,
                                ),
                              ),
                              Expanded(
                                child: _ReportMetricTile(
                                  label: '相伴书目',
                                  value: '${_data.periodBooks} 本',
                                  foreground: exportTheme.foreground,
                                  muted: exportTheme.muted,
                                ),
                              ),
                            ],
                          ),
                          for (final module in _options.orderedModules) ...[
                            const SizedBox(height: 16),
                            ReadingStatisticsAnalysisView(
                              bookFor: (id) =>
                                  widget.state.localLibrary?.bookFor(id) != null
                                  ? widget.state.localLibrary!.toNovel(
                                      widget.state.localLibrary!.bookFor(id)!,
                                    )
                                  : widget.state.cachedNovel(id),
                              data: _data,
                              module: module,
                            ),
                          ],
                          const SizedBox(height: 16),
                          AppText(
                            _options.note,
                            style: TextStyle(
                              fontSize: 12,
                              color: exportTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          GallerySaveButton(
            foreground: Theme.of(context).colorScheme.onPrimary,
            background: Theme.of(context).colorScheme.primary,
            onSave: _savePoster,
            onError: (error) =>
                showNovelFeedback(context, gallerySaveFailureMessage(error)),
            builder: (onPressed) => GlassPillButton(
              key: const ValueKey('reading-report-save-poster'),
              icon: CupertinoIcons.photo_on_rectangle,
              label: '保存报告长图到相册',
              onPressed: onPressed,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportMetricTile extends StatelessWidget {
  const _ReportMetricTile({
    required this.label,
    required this.value,
    required this.foreground,
    required this.muted,
  });

  final String label;
  final String value;
  final Color foreground;
  final Color muted;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AppText(label, style: TextStyle(fontSize: 12, color: muted)),
      const SizedBox(height: 4),
      AppText(
        value,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    ],
  );
}
