import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_palette.dart';
import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'palette_image.dart';
import 'personal_images.dart';

String paletteHex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
Color? parsePaletteHex(String text) {
  final value = text.trim().replaceFirst(RegExp(r'^#'), '');
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)
      ? Color(0xff000000 | int.parse(value, radix: 16))
      : null;
}

class PaletteSettingsPage extends StatefulWidget {
  const PaletteSettingsPage({super.key, required this.state, this.documents});
  final LibraryState state;
  final BookDocuments? documents;
  @override
  State<PaletteSettingsPage> createState() => _PaletteSettingsPageState();
}

class _PaletteSettingsPageState extends State<PaletteSettingsPage>
    with WidgetsBindingObserver {
  bool _busy = false;
  LibraryState get state => widget.state;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(state.refreshSystemPalette());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    if (value == AppLifecycleState.resumed) {
      unawaited(state.refreshSystemPalette());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _save(AppPalettePreferences value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await state.setAppPalette(value);
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '配色保存未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _image() async {
    if (_busy) return;
    setState(() => _busy = true);
    final documents = widget.documents ?? BookDocuments();
    try {
      final selected = await documents.pickImage();
      if (selected == null) return;
      late PaletteImage image;
      try {
        image = await PaletteImage.decode(
          await preparePersonalImage(selected.path!),
        );
      } finally {
        await documents.releaseBooks([selected]);
      }
      if (!mounted) return;
      Object? imageError;
      await precacheImage(
        ResizeImage(MemoryImage(image.png), width: 1024),
        context,
        onError: (error, _) => imageError = error,
      );
      if (imageError != null) throw const FormatException('图片预览未完成，请选择较小的图片');
      if (!mounted) return;
      final color = await pushNovelPage<Color>(
        context,
        PaletteImagePickerPage(image: image),
        reduceMotion: state.effectiveReduceMotion,
      );
      if (color != null) {
        await state.setAppPalette(
          state.appPalette.copyWith(
            source: AppPaletteSource.custom,
            seed: color.toARGB32(),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '图片取色未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _custom() async {
    final color = await showJellySheet<Color>(
      context: context,
      reduceMotion: state.effectiveReduceMotion,
      heightFactor: .76,
      builder: (_) => _SeedEditor(initial: state.appPalette.color),
    );
    if (color != null && mounted) {
      await _save(
        state.appPalette.copyWith(
          source: AppPaletteSource.custom,
          seed: color.toARGB32(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '主题配色',
    code: 'APPEARANCE / MONET',
    child: AnimatedBuilder(
      animation: state.settingsChanges,
      builder: (context, _) {
        final prefs = state.appPalette;
        final scheme = Theme.of(context).colorScheme;
        final system = state.systemTonalColors;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: featurePadding(context),
              children: [
                const ArchiveSection(
                  title: '莫奈配色',
                  code: '01 / TONAL PALETTE',
                  subtitle: '浅色与深色自动配套，阅读器保留独立配色。',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in const {
                      AppPaletteSource.original: '原色',
                      AppPaletteSource.system: '系统取色',
                      AppPaletteSource.custom: '自选配色',
                    }.entries)
                      GlassTextButton(
                        key: ValueKey('palette-source-${entry.key.name}'),
                        compact: true,
                        selected: prefs.source == entry.key,
                        onPressed:
                            _busy ||
                                entry.key == AppPaletteSource.system &&
                                    system == null
                            ? null
                            : () => _save(prefs.copyWith(source: entry.key)),
                        child: AppText(
                          entry.value,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                ),
                if (state.paletteError != null)
                  GlassTextButton(
                    onPressed: () => state.refreshSystemPalette(),
                    child: AppText(state.paletteError!),
                  ),
                if (state.paletteLoaded && system == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: AppText(
                      '当前设备未提供系统配色，可使用自选颜色或图片取色。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                _PalettePreview(scheme: scheme),
                AnimatedOptionSection(
                  expanded: prefs.source == AppPaletteSource.custom,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      const ArchiveSection(
                        title: '选择主色',
                        code: '02 / SOURCE COLOR',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final entry in const {
                            0xff607d71: '雾松',
                            0xff547d98: '浅海',
                            0xff887aa5: '鸢尾',
                            0xffa06a77: '胭脂',
                            0xff9b8452: '麦穗',
                            0xff72767d: '石墨',
                          }.entries)
                            _PaletteSwatch(
                              seed: entry.key,
                              label: entry.value,
                              selected: prefs.seed == entry.key,
                              onTap: _busy
                                  ? null
                                  : () =>
                                        _save(prefs.copyWith(seed: entry.key)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: GlassTextButton(
                              key: const ValueKey('palette-custom-color'),
                              onPressed: _busy ? null : _custom,
                              child: const AppText('自选颜色'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: GlassTextButton(
                              key: const ValueKey('palette-image-import'),
                              onPressed: _busy ? null : _image,
                              child: AppText(_busy ? '正在取色' : '图片取色'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      AppText(
                        '当前主色 ${paletteHex(prefs.color)}',
                        style: ArchiveDesign.codeStyle(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                const ArchiveSection(title: '桌面图标', code: '03 / APP ICON'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: AppText(
                        '图标莫奈取色',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    AppControls.toggle(
                      context,
                      key: const ValueKey('palette-themed-icon'),
                      value: prefs.themedIcon,
                      onChanged: _busy || !state.themedIconSupported
                          ? null
                          : (value) => _save(prefs.copyWith(themedIcon: value)),
                    ),
                  ],
                ),
                AppText(
                  '使用系统壁纸的主题图标配色；关闭时提供原图标。需 Android 13 及以上，并在支持的桌面开启「主题图标」，实际着色由桌面决定。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.7,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _PalettePreview extends StatelessWidget {
  const _PalettePreview({required this.scheme});
  final ColorScheme scheme;
  @override
  Widget build(BuildContext context) => ContentPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          '故事，自有它的颜色。',
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        AppText(
          '页面、玻璃与控件，温和地保持一致。',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 13,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (final color in [
              scheme.primary,
              scheme.secondary,
              scheme.tertiary,
              scheme.primaryContainer,
              scheme.surfaceContainerHighest,
            ])
              Expanded(
                child: Container(
                  height: 25,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

class _PaletteSwatch extends StatelessWidget {
  static final _schemes = <(int, Brightness), ColorScheme>{};
  const _PaletteSwatch({
    required this.seed,
    required this.label,
    required this.selected,
    this.onTap,
  });
  final int seed;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final colors = _schemes.putIfAbsent(
      (seed, brightness),
      () =>
          ColorScheme.fromSeed(seedColor: Color(seed), brightness: brightness),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: JellyTapSurface(
        key: ValueKey('palette-swatch-$seed'),
        onTap: onTap,
        child: SizedBox(
          width: 82,
          child: Column(
            children: [
              Container(
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                    width: selected ? 1.6 : .7,
                  ),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    for (final c in [
                      colors.primary,
                      colors.primaryContainer,
                      colors.tertiaryContainer,
                    ])
                      Expanded(
                        child: ColoredBox(
                          color: c,
                          child: const SizedBox.expand(),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              AppText(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeedEditor extends StatefulWidget {
  const _SeedEditor({required this.initial});
  final Color initial;
  @override
  State<_SeedEditor> createState() => _SeedEditorState();
}

class _SeedEditorState extends State<_SeedEditor> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: paletteHex(widget.initial));
  bool _valid = true;
  void _change(HSVColor value) {
    setState(() {
      _hsv = value;
      _valid = true;
      _hex.text = paletteHex(value.toColor());
    });
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.fromLTRB(
      24,
      18,
      24,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    shrinkWrap: true,
    children: [
      const ArchiveSection(title: '自选颜色', code: 'COLOR / SOURCE'),
      const SizedBox(height: 18),
      Container(
        height: 52,
        decoration: BoxDecoration(
          color: _hsv.toColor(),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      const SizedBox(height: 14),
      CupertinoTextField(
        key: const ValueKey('palette-hex'),
        onTap: () => AppHaptics.play(context, HapticCue.selection),
        onSubmitted: (_) => AppHaptics.play(context, HapticCue.action),
        controller: _hex,
        maxLength: 7,
        placeholder: '#607D71',
        style: Theme.of(context).textTheme.bodyMedium,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(4),
        ),
        onChanged: (text) {
          final c = parsePaletteHex(text);
          setState(() {
            _valid = c != null;
            if (c != null) _hsv = HSVColor.fromColor(c);
          });
        },
      ),
      const SizedBox(height: 12),
      for (final component in ['色相', '饱和度', '明度']) ...[
        AppText(component, style: const TextStyle(fontSize: 13)),
        AppControls.slider(
          context,
          value: component == '色相'
              ? _hsv.hue / 360
              : component == '饱和度'
              ? _hsv.saturation
              : _hsv.value,
          onChanged: (v) => _change(
            component == '色相'
                ? _hsv.withHue(v * 360)
                : component == '饱和度'
                ? _hsv.withSaturation(v)
                : _hsv.withValue(v),
          ),
        ),
      ],
      GlassTextButton(
        key: const ValueKey('palette-apply-color'),
        onPressed: !_valid
            ? null
            : () => Navigator.pop(context, _hsv.toColor()),
        child: const AppText('使用此颜色'),
      ),
    ],
  );
}

class PaletteImagePickerPage extends StatefulWidget {
  const PaletteImagePickerPage({super.key, required this.image});
  final PaletteImage image;
  @override
  State<PaletteImagePickerPage> createState() => _PaletteImagePickerPageState();
}

class _PaletteImagePickerPageState extends State<PaletteImagePickerPage> {
  late Color _color = Color(widget.image.seeds.first);
  late final ResizeImage _provider = ResizeImage(
    MemoryImage(widget.image.png),
    width: 1024,
  );
  Offset? _point;
  (int, int)? _lastSampleDetent;
  void _pick(Offset point, Size viewport, {bool dragging = false}) {
    final color = widget.image.colorAt(point, viewport);
    if (color != null) {
      final rect = widget.image.imageRect(viewport);
      final sample = Offset(
        (point.dx - rect.left) / rect.width,
        (point.dy - rect.top) / rect.height,
      );
      final detent = ((sample.dx * 20).floor(), (sample.dy * 20).floor());
      if (!dragging || detent != _lastSampleDetent) {
        AppHaptics.play(
          context,
          dragging ? HapticCue.detent : HapticCue.selection,
        );
        _lastSampleDetent = detent;
      }
      setState(() {
        _color = color;
        _point = sample;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_provider.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '图片取色',
    code: 'COLOR / IMAGE',
    child: ListView(
      padding: featurePadding(context),
      children: [
        const AppText(
          '点选或拖动图片取色',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: (MediaQuery.sizeOf(context).height * .42).clamp(160, 420),
          child: LayoutBuilder(
            builder: (context, box) => GestureDetector(
              key: const ValueKey('palette-image-sampling'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _pick(d.localPosition, box.biggest),
              onPanStart: (d) {
                _lastSampleDetent = null;
                _pick(d.localPosition, box.biggest, dragging: true);
              },
              onPanUpdate: (d) =>
                  _pick(d.localPosition, box.biggest, dragging: true),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(image: _provider, fit: BoxFit.contain),
                  if (_point case final p?)
                    Positioned(
                      left:
                          widget.image.imageRect(box.biggest).left +
                          p.dx * widget.image.imageRect(box.biggest).width -
                          10,
                      top:
                          widget.image.imageRect(box.biggest).top +
                          p.dy * widget.image.imageRect(box.biggest).height -
                          10,
                      child: IgnorePointer(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _color,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black38, blurRadius: 3),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          children: [
            for (final seed in widget.image.seeds)
              GlassTextButton(
                compact: true,
                selected: _color.toARGB32() == seed,
                onPressed: () => setState(() {
                  _color = Color(seed);
                  _point = null;
                }),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(seed),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            AppText(
              paletteHex(_color),
              style: ArchiveDesign.codeStyle(context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        GlassTextButton(
          key: const ValueKey('palette-image-apply'),
          onPressed: () => Navigator.pop(context, _color),
          child: const AppText('使用此颜色'),
        ),
      ],
    ),
  );
}
