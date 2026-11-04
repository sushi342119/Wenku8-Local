import 'package:flutter/cupertino.dart';
import 'app_ui.dart';

/// Small, visible sets of choices share the app's control surface and hit area.
class GlassChoiceGroup<T> extends StatelessWidget {
  const GlassChoiceGroup({
    super.key,
    required this.name,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.leading,
    this.optionName,
    this.labelSize = 14,
    this.optionSize = 13,
    this.enabled = true,
    this.columns,
  });
  final String name, label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final Widget Function(T)? leading;
  final String Function(T)? optionName;
  final double labelSize, optionSize;
  final bool enabled;
  final int? columns;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: AppText(
          label,
          style: TextStyle(fontSize: labelSize, fontWeight: FontWeight.w600),
        ),
      ),
      if (columns == null)
        _choices()
      else
        LayoutBuilder(
          builder: (context, constraints) {
            final count =
                constraints.maxWidth < 280 ||
                    MediaQuery.textScalerOf(context).scale(optionSize) >
                        optionSize * 1.3
                ? 1
                : columns!;
            return _choices(
              width: (constraints.maxWidth - 8 * (count - 1)) / count,
            );
          },
        ),
    ],
  );

  Widget _choices({double? width}) => Wrap(
    spacing: 8,
    children: [
      for (final entry in options.entries)
        SizedBox(
          width: width,
          child: Semantics(
            selected: entry.key == value,
            inMutuallyExclusiveGroup: true,
            child: GlassTextButton(
              compact: true,
              selected: entry.key == value,
              key: ValueKey(
                '$name-${optionName?.call(entry.key) ?? entry.key}',
              ),
              onPressed: enabled ? () => onChanged(entry.key) : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[
                    leading!(entry.key),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: AppText(
                      entry.value,
                      style: TextStyle(
                        fontSize: optionSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
