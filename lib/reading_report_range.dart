import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'app_ui.dart';
import 'local_platform.dart';

/// Calendar-day range shared by the dashboard and the image report editor.
class ReadingReportRange {
  const ReadingReportRange({this.period = 30, this.from, this.until});
  final int period;
  final DateTime? from, until;
  bool get custom => from != null && until != null;
  int daysAt(DateTime now) => !custom
      ? period
      : DateTime.utc(until!.year, until!.month, until!.day)
                .difference(DateTime.utc(from!.year, from!.month, from!.day))
                .inDays +
            1;
  DateTime endAt(DateTime now) => until ?? now;
  Map<String, Object?> toJson() => {
    'period': period,
    'from': from?.toIso8601String(),
    'until': until?.toIso8601String(),
  };
  factory ReadingReportRange.fromJson(Map<String, dynamic> value) {
    final from = DateTime.tryParse('${value['from']}');
    final until = DateTime.tryParse('${value['until']}');
    final custom = from != null && until != null && !until.isBefore(from);
    return ReadingReportRange(
      period: const [7, 30, 90, 365].contains(value['period'])
          ? value['period'] as int
          : 30,
      from: custom ? from : null,
      until: custom ? until : null,
    );
  }
}

Future<DateTimeRange?> pickReadingReportRange(
  BuildContext context, {
  required DateTime now,
  required ReadingReportRange range,
}) {
  final today = DateTime(now.year, now.month, now.day);
  return showJellySheet<DateTimeRange>(
    context: context,
    reduceMotion: MediaQuery.disableAnimationsOf(context),
    maxWidth: 620,
    builder: (_) => ReadingReportDateSheet(today: today, range: range),
  );
}

/// The app's existing glass modal owns dismissal and motion; Cupertino owns dates.
class ReadingReportDateSheet extends StatefulWidget {
  const ReadingReportDateSheet({
    super.key,
    required this.today,
    required this.range,
  });
  final DateTime today;
  final ReadingReportRange range;
  @override
  State<ReadingReportDateSheet> createState() => _ReadingReportDateSheetState();
}

class _ReadingReportDateSheetState extends State<ReadingReportDateSheet> {
  late DateTime _start =
      widget.range.from ??
      DateTime(
        widget.today.year,
        widget.today.month,
        widget.today.day - widget.range.period + 1,
      );
  late DateTime _end = widget.range.until ?? widget.today;
  bool _editingEnd = false;
  String _date(DateTime value) => '${value.year}.${value.month}.${value.day}';

  void _changeDate(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    final previous = _editingEnd ? _end : _start;
    if (DateUtils.isSameDay(previous, date)) return;
    setState(() => _editingEnd ? _end = date : _start = date);
    // Cupertino supplies its own tick on iOS only. Other mobile hosts reuse
    // the app's immediate, bounded adjustment cue, never a second iOS pulse.
    if (LocalPlatform.android || LocalPlatform.harmony) {
      AppHaptics.play(context, HapticCue.detent);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: ArchiveSection(
                title: '选择统计日期',
                code: 'READING / DATE RANGE',
              ),
            ),
            GlassIconButton(
              icon: CupertinoIcons.xmark,
              label: '取消日期选择',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AppControls.segments<bool>(
          context,
          groupValue: _editingEnd,
          children: const {false: AppText('开始日期'), true: AppText('结束日期')},
          onValueChanged: (value) {
            if (value != null) setState(() => _editingEnd = value);
          },
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 204,
          child: CupertinoDatePicker(
            key: ValueKey(
              _editingEnd ? 'report-date-end' : 'report-date-start',
            ),
            mode: CupertinoDatePickerMode.date,
            initialDateTime: _editingEnd ? _end : _start,
            minimumDate: _editingEnd
                ? _start
                : DateTime(
                    widget.today.year < 2020 ? widget.today.year : 2020,
                    1,
                    1,
                  ),
            maximumDate: _editingEnd ? widget.today : _end,
            onDateTimeChanged: _changeDate,
          ),
        ),
        AppText(
          '${_date(_start)} — ${_date(_end)}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 16),
        GlassTextButton(
          key: const ValueKey('report-date-confirm'),
          onPressed: () =>
              Navigator.pop(context, DateTimeRange(start: _start, end: _end)),
          child: const AppText('使用此区间'),
        ),
      ],
    ),
  );
}
