import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;

enum AppLanguage {
  system('跟随系统', null),
  simplified('简体中文', Locale('zh', 'CN')),
  hongKong('繁體中文 · 香港', Locale('zh', 'HK')),
  taiwan('繁體中文 · 台灣', Locale('zh', 'TW'));

  const AppLanguage(this.label, this.locale);
  final String label;
  final Locale? locale;
  static AppLanguage fromRecord(Object? value) =>
      values.firstWhere((v) => v.name == value, orElse: () => system);
}

Locale chineseLocale(Locale? locale) => Locale(
  'zh',
  locale?.countryCode == 'HK' || locale?.countryCode == 'MO'
      ? 'HK'
      : locale?.countryCode == 'TW' || locale?.scriptCode == 'Hant'
      ? 'TW'
      : 'CN',
);

/// Offline OpenCC dictionary conversion. Text is converted once per bounded
/// cache entry, never in a painter or on a scroll/animation callback.
abstract final class ChineseText {
  static Future<void>? _loading;
  static Map<String, _Lexicon> _lexicons = {};
  static final _cache = <(String, bool, String), String>{};
  static int _cacheUnits = 0;
  static Future<_Lexicon>? _searchLexicon;

  /// Normalize queries for the simplified catalogue, not the user's stored
  /// book text or display preference. Dictionaries load only on first search.
  static Future<String> searchQuery(String source) async {
    if (!RegExp(r'[\u3400-\u9fff]').hasMatch(source)) return source;
    final lexicon = await (_searchLexicon ??= () async {
      const names = ['TSPhrases', 'TSCharacters'];
      final sources = await Future.wait([
        for (final name in names)
          rootBundle.loadString('assets/opencc/$name.txt'),
      ]);
      return compute(_readSearchLexicon, sources);
    }());
    return lexicon.convert(source);
  }

  static Future<List<String>> readerParagraphs(
    List<String> paragraphs,
    Locale locale,
  ) async {
    final region = chineseLocale(locale).countryCode!;
    if (region == 'CN') return paragraphs;
    final job = (paragraphs: paragraphs, region: region, lexicons: _lexicons);
    if (paragraphs.fold<int>(0, (sum, p) => sum + p.length) > 32 * 1024) {
      return compute(_readerParagraphs, job);
    }
    return _readerParagraphs(job);
  }

  static Future<void> prepare() => _loading ??= () async {
    const names = [
      'STCharacters',
      'STPhrases',
      'TWVariants',
      'HKVariants',
      'TWPhrasesIT',
      'TWPhrasesName',
      'TWPhrasesOther',
    ];
    final sources = await Future.wait(
      names.map((n) => rootBundle.loadString('assets/opencc/$n.txt')),
    );
    _lexicons = await compute(_readLexicons, {
      for (var i = 0; i < names.length; i++) names[i]: sources[i],
    });
  }();

  static String convert(String source, Locale locale, {bool reader = false}) {
    final region = chineseLocale(locale).countryCode!;
    if (region == 'CN' || source.isEmpty || _lexicons.isEmpty) return source;
    final key = (region, reader, source);
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    var text = _lexicons['standard']!.convert(source, preserveOffsets: reader);
    if (region == 'TW' && !reader) text = _lexicons['phrases']!.convert(text);
    text = _lexicons[region]!.convert(text, preserveOffsets: reader);
    if (source.length < 8192) {
      _cache[key] = text;
      _cacheUnits += source.length + text.length;
      while (_cache.length > 2048 || _cacheUnits > 256 * 1024) {
        final oldest = _cache.keys.first;
        _cacheUnits -= oldest.$3.length + _cache.remove(oldest)!.length;
      }
    }
    return text;
  }
}

List<String> _readerParagraphs(
  ({List<String> paragraphs, String region, Map<String, _Lexicon> lexicons})
  job,
) => [
  for (final text in job.paragraphs)
    text.trim() == '[插图]' ||
            text.trimLeft().startsWith('<!--image-->') ||
            job.lexicons.isEmpty
        ? text
        : job.lexicons[job.region]!.convert(
            job.lexicons['standard']!.convert(text, preserveOffsets: true),
            preserveOffsets: true,
          ),
];

class _Lexicon {
  _Lexicon(this.words) {
    for (final key in words.keys) {
      final head = key.codeUnitAt(0);
      if ((_longest[head] ?? 0) < key.length) _longest[head] = key.length;
    }
  }
  final Map<String, String> words;
  final _longest = <int, int>{};
  String convert(String input, {bool preserveOffsets = false}) {
    final out = StringBuffer();
    for (var i = 0; i < input.length;) {
      final bound = (_longest[input.codeUnitAt(i)] ?? 0).clamp(
        0,
        input.length - i,
      );
      String? value;
      var length = bound;
      for (; length > 0; length--) {
        value = words[input.substring(i, i + length)];
        if (value != null && (!preserveOffsets || value.length == length)) {
          break;
        }
        value = null;
      }
      if (value == null) {
        out.writeCharCode(input.codeUnitAt(i++));
      } else {
        out.write(value);
        i += length;
      }
    }
    return out.toString();
  }
}

_Lexicon _readSearchLexicon(List<String> sources) {
  final words = <String, String>{};
  for (final source in sources) {
    for (final line in source.split('\n')) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.trim().split('\t');
      if (fields.length == 2) {
        words.putIfAbsent(fields[0], () => fields[1].split(' ').first);
      }
    }
  }
  return _Lexicon(words);
}

Map<String, _Lexicon> _readLexicons(Map<String, String> sources) {
  Map<String, String> read(List<String> names) {
    final words = <String, String>{};
    for (final name in names) {
      for (final line in sources[name]!.split('\n')) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final fields = line.trim().split('\t');
        if (fields.length == 2) {
          words.putIfAbsent(fields[0], () => fields[1].split(' ').first);
        }
      }
    }
    return words;
  }

  return {
    'standard': _Lexicon(read(['STPhrases', 'STCharacters'])),
    'TW': _Lexicon(read(['TWVariants'])),
    'HK': _Lexicon(read(['HKVariants'])),
    'phrases': _Lexicon(
      read(['TWPhrasesIT', 'TWPhrasesName', 'TWPhrasesOther']),
    ),
  };
}

String appText(BuildContext context, String value) => ChineseText.convert(
  value,
  Localizations.maybeLocaleOf(context) ?? const Locale('zh', 'CN'),
);

/// All ordinary app labels share the locale; book source data stays unchanged.
class AppText extends StatefulWidget {
  const AppText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;
  @override
  State<AppText> createState() => _AppTextState();
}

class _AppTextState extends State<AppText> with SingleTickerProviderStateMixin {
  AnimationController? _motion;
  String? _region, _value;
  List<String> _from = const [], _to = const [];
  List<double> _delays = const [];
  int _generation = 0;
  void _sync() {
    final region = chineseLocale(
      Localizations.maybeLocaleOf(context),
    ).countryCode;
    final next = appText(context, widget.data);
    if (_region != null &&
        _region != region &&
        widget.data.length <= 512 &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      _from = (_value ?? next).characters.toList();
      _to = next.characters.toList();
      final random = math.Random(widget.data.hashCode ^ ++_generation);
      _delays = List.generate(
        math.max(_from.length, _to.length),
        (_) => random.nextDouble() * .52,
      );
      (_motion ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 780),
      )).forward(from: 0);
    } else if (_value != next ||
        _region != region ||
        MediaQuery.disableAnimationsOf(context)) {
      _motion?.stop();
      _motion?.value = 1;
    }
    _region = region;
    _value = next;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AppText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _motion?.dispose();
    super.dispose();
  }

  Widget _text({InlineSpan? span}) {
    final label = widget.semanticsLabel == null
        ? null
        : appText(context, widget.semanticsLabel!);
    if (span == null) {
      return Text(
        _value ?? appText(context, widget.data),
        style: widget.style,
        strutStyle: widget.strutStyle,
        textAlign: widget.textAlign,
        textDirection: widget.textDirection,
        locale: widget.locale,
        softWrap: widget.softWrap,
        overflow: widget.overflow,
        textScaler: widget.textScaler,
        maxLines: widget.maxLines,
        semanticsLabel: label,
        textWidthBasis: widget.textWidthBasis,
        textHeightBehavior: widget.textHeightBehavior,
        selectionColor: widget.selectionColor,
      );
    }
    return Text.rich(
      span,
      style: widget.style,
      strutStyle: widget.strutStyle,
      textAlign: widget.textAlign,
      textDirection: widget.textDirection,
      locale: widget.locale,
      softWrap: widget.softWrap,
      overflow: widget.overflow,
      textScaler: widget.textScaler,
      maxLines: widget.maxLines,
      semanticsLabel: label ?? _value,
      textWidthBasis: widget.textWidthBasis,
      textHeightBehavior: widget.textHeightBehavior,
      selectionColor: widget.selectionColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final motion = _motion;
    if (motion == null || motion.value == 1) return _text();
    return AnimatedBuilder(
      animation: motion,
      builder: (context, _) {
        if (motion.value == 1) return _text();
        final color =
            widget.style?.color ??
            DefaultTextStyle.of(context).style.color ??
            Theme.of(context).colorScheme.onSurface;
        return _text(
          span: TextSpan(
            children: [
              for (var i = 0; i < _delays.length; i++)
                _character(i, motion.value, color),
            ],
          ),
        );
      },
    );
  }

  InlineSpan _character(int i, double clock, Color color) {
    final t = ((clock - _delays[i]) / .48).clamp(0.0, 1.0);
    final alpha = (t < .5 ? 1 - t * 1.84 : .08 + (t - .5) * 1.84).clamp(
      .08,
      1.0,
    );
    final chars = t < .5 ? _from : _to;
    return TextSpan(
      text: i < chars.length ? chars[i] : '',
      style: TextStyle(color: color.withValues(alpha: color.a * alpha)),
    );
  }
}
