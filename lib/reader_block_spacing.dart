import 'dart:math' as math;

/// Publisher block spacing is metadata, never a synthetic text paragraph.
/// Margins collapse; padding and explicit empty lines remain additive.
class ReaderBlockSpacing {
  const ReaderBlockSpacing({
    this.before = const [],
    this.after = const [],
    this.leading = const [],
    this.trailing = const [],
  });
  final List<String> before, after, leading, trailing;
  bool get empty =>
      before.isEmpty && after.isEmpty && leading.isEmpty && trailing.isEmpty;
  static final _length = RegExp(
    r'^(\d+(?:\.\d+)?|\.\d+)(em|rem|ex|lh|px|pt|%)?$',
  );
  static String? length(String? value) {
    final text = value?.trim().toLowerCase();
    final match = text == null ? null : _length.firstMatch(text);
    if (match == null) return null;
    final number = double.tryParse(match[1]!);
    if (number == null ||
        !number.isFinite ||
        number < 0 ||
        number > 0 && match[2] == null) {
      return null;
    }
    return text;
  }

  factory ReaderBlockSpacing.fromProperties(
    Map<String, String> values, {
    bool vertical = false,
  }) {
    List<String> edge(String kind, bool start) {
      final physical = vertical
          ? (start ? 'right' : 'left')
          : (start ? 'top' : 'bottom');
      final value = length(
        values['$kind-block-${start ? 'start' : 'end'}'] ??
            values['$kind-$physical'],
      );
      return value == null ? const [] : [value];
    }

    return ReaderBlockSpacing(
      before: edge('margin', true),
      after: edge('margin', false),
      leading: edge('padding', true),
      trailing: edge('padding', false),
    );
  }

  ReaderBlockSpacing merge(ReaderBlockSpacing other) => ReaderBlockSpacing(
    before: [...before, ...other.before],
    after: [...after, ...other.after],
    leading: [...leading, ...other.leading],
    trailing: [...trailing, ...other.trailing],
  );
  ReaderBlockSpacing get start =>
      ReaderBlockSpacing(before: before, leading: leading);
  ReaderBlockSpacing get end =>
      ReaderBlockSpacing(after: after, trailing: trailing);

  static double _pixels(
    String value,
    double font,
    double lineHeight,
    double width,
  ) {
    final match = _length.firstMatch(value)!;
    return double.parse(match[1]!) *
        switch (match[2]) {
          'em' || 'rem' => font,
          'ex' => font * .5,
          'lh' => font * lineHeight,
          '%' => width / 100,
          'pt' => 96 / 72,
          _ => 1.0,
        };
  }

  double gapBefore(
    ReaderBlockSpacing? previous, {
    required double font,
    required double lineHeight,
    required double width,
    required double defaultGap,
    bool overrideGap = false,
  }) {
    double maximum(List<String> values) => values.fold(
      0.0,
      (a, b) => math.max(a, _pixels(b, font, lineHeight, width)),
    );
    double total(List<String> values) =>
        values.fold(0.0, (a, b) => a + _pixels(b, font, lineHeight, width));
    if (previous != null && overrideGap) {
      return defaultGap + total(leading) + total(previous.trailing);
    }
    final prior = previous == null
        ? 0.0
        : previous.after.isEmpty
        ? defaultGap
        : maximum(previous.after);
    return math.max(prior, maximum(before)) +
        total(leading) +
        total(previous?.trailing ?? const []);
  }

  Map<String, Object> toJson() => {
    if (before.isNotEmpty) 'before': before,
    if (after.isNotEmpty) 'after': after,
    if (leading.isNotEmpty) 'leading': leading,
    if (trailing.isNotEmpty) 'trailing': trailing,
  };
  factory ReaderBlockSpacing.fromJson(Object? value) {
    if (value is! Map) return const ReaderBlockSpacing();
    List<String> values(String key) => value[key] is! List
        ? const []
        : [
            for (final item in (value[key] as List))
              if (item is String && length(item) != null) item,
          ];
    return ReaderBlockSpacing(
      before: values('before'),
      after: values('after'),
      leading: values('leading'),
      trailing: values('trailing'),
    );
  }
}
