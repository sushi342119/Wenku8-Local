import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_ui.dart';
import 'app_palette.dart';
import 'app_licenses.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'haptic_preferences.dart';
import 'legacy_wenku_repository.dart';
import 'library_state.dart';
import 'listening/audio_output.dart';
import 'listening/cache.dart';
import 'listening/controller.dart';
import 'listening/store.dart';
import 'listening/widgets.dart';
import 'local_library.dart';
import 'native_effects.dart';
import 'offline_cache.dart';
import 'offline_repository.dart';
import 'pages.dart';
import 'performance_preferences.dart';
import 'reading_widget_cards.dart';
import 'reading_widget_controller.dart';
import 'touch_sampling.dart';
import 'local_platform.dart';
import 'ui_preferences.dart';
import 'updates/app_updates.dart';
import 'updates/update_page.dart';
import 'wenku_errors.dart';

class _StartupFailure implements Exception {
  const _StartupFailure(this.item, this.error, this.stackTrace);

  final String item;
  final Object error;
  final StackTrace stackTrace;
}

Future<T> _requiredStartup<T>(
  String item,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } catch (error, stackTrace) {
    throw _StartupFailure(item, error, stackTrace);
  }
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  try {
    try {
      registerAppLicenses();
    } catch (_) {}
    try {
      TouchSamplingPolicy(binding);
    } catch (_) {}
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError(
        (Object _) {},
      ),
    );
    final state = await _requiredStartup('本地阅读状态', LibraryState.load);
    if (state.appPalette.source == AppPaletteSource.system ||
        !state.appPalette.themedIcon) {
      try {
        await state.refreshSystemPalette();
      } catch (_) {}
    }
    if (chineseLocale(
          state.language.locale ?? binding.platformDispatcher.locale,
        ).countryCode !=
        'CN') {
      try {
        await ChineseText.prepare();
      } catch (_) {}
    }
    try {
      await TagStore.load();
    } catch (_) {}
    try {
      await state.loadFonts();
    } catch (_) {}
    // Automatic glass tier: RAM ≤ 4 GB or Android ≤ 10 starts on 轻. A failed
    // query keeps 标准; the user can always pick a tier by hand.
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        state.setDeviceProfile(
          DeviceProfile.fromMap(await LocalPlatform.deviceProfile()),
        );
      } catch (_) {}
    }
    if (state.effectivePerformance.needsRuntimeEffects) {
      try {
        await NativeEffects.prepare();
      } catch (_) {}
    }
    final brightness = switch (state.theme) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    try {
      SystemChrome.setSystemUIOverlayStyle(novelSystemUiStyle(brightness));
    } catch (_) {}
    final remote = LegacyWenkuRepository();
    final NovelRepository repository;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final local = await _requiredStartup('本地书库', LocalLibraryStore.load);
      NovelRepository remoteRepository = remote;
      try {
        remoteRepository = OfflineNovelRepository(
          remote: remote,
          cache: await OfflineCacheStore.forApp(),
        );
      } catch (_) {}
      repository = CompositeNovelRepository(
        local: local,
        remote: remoteRepository,
      );
    } else {
      repository = const DemoNovelRepository();
    }
    if (repository is CompositeNovelRepository) {
      state.bindLocalChapters(repository.local);
    }
    ListeningController? listening;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        listening = ListeningController(
          repository: repository,
          audio: await SpeechAudioCache.forApp(),
          store: ListeningStore(await SharedPreferences.getInstance()),
          outputFactory: createListeningOutput,
        );
      } catch (_) {}
    }
    AppUpdates? updates;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        updates = AppUpdates(
          preferences: await SharedPreferences.getInstance(),
        );
      } catch (_) {}
    }
    runApp(
      NovelApp(
        state: state,
        repository: repository,
        listening: listening,
        updates: updates,
      ),
    );
    if (listening != null) {
      unawaited(prepareListeningService(listening).catchError((Object _) {}));
    }
  } catch (error, stackTrace) {
    final failure = error is _StartupFailure
        ? error
        : _StartupFailure('启动初始化', error, stackTrace);
    runApp(_StartupFailureApp(failure: failure));
  }
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.failure});

  final _StartupFailure failure;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '书屿',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('应用启动失败')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '初始化失败项：${failure.item}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Text(describeSafeError(failure.error, fallback: '本地数据暂时无法读取，请重试')),
              const SizedBox(height: 24),
              const Text('请重启应用后重试。应用没有自动删除本地书库、书架或恢复记录。'),
            ],
          ),
        ),
      ),
    );
  }
}

class NovelApp extends StatefulWidget {
  const NovelApp({
    super.key,
    required this.state,
    required this.repository,
    this.listening,
    this.updates,
  });

  final LibraryState state;
  final NovelRepository repository;
  final ListeningController? listening;
  final AppUpdates? updates;
  @override
  State<NovelApp> createState() => _NovelAppState();
}

class _NovelAppState extends State<NovelApp> with WidgetsBindingObserver {
  LibraryState get state => widget.state;
  NovelRepository get repository => widget.repository;
  ListeningController? get listening => widget.listening;
  AppUpdates? get updates => widget.updates;
  late String _lastFontId = state.appFontId;
  late final ReadingWidgetController _readingWidgets =
      ReadingWidgetController.forState(state);
  late final ReadingWidgetCards _widgetCards =
      ReadingWidgetCards.forState(state);
  Locale _systemLocale = chineseLocale(
    WidgetsBinding.instance.platformDispatcher.locale,
  );
  int _localeRequest = 0;
  Object? _themeKey;
  final _themes = <Brightness, ThemeData>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _readingWidgets.attach().then((_) {
        if (mounted) return _widgetCards.attach();
      }).catchError((Object _) {}),
    );
  }

  @override
  Future<void> didChangeLocales(List<Locale>? locales) async {
    final ticket = ++_localeRequest;
    final next = chineseLocale(locales?.firstOrNull);
    if (state.language == AppLanguage.system && next.countryCode != 'CN') {
      await ChineseText.prepare();
    }
    if (mounted && ticket == _localeRequest) {
      setState(() => _systemLocale = next);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.hidden) {
      unawaited(
        Future<void>.delayed(Duration.zero, _readingWidgets.publish)
            .catchError((Object _) {}),
      );
    }
    if (lifecycle == AppLifecycleState.resumed &&
        state.appPalette.source == AppPaletteSource.system) {
      unawaited(state.refreshSystemPalette());
    }
  }

  @override
  void dispose() {
    _widgetCards.dispose();
    _readingWidgets.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final key = (
      defaultTargetPlatform,
      state.appFontId,
      state.appPalette.source,
      state.appPalette.seed,
      state.systemTonalColors?.signature,
      state.paletteVariant,
    );
    if (_themeKey != key) {
      _themeKey = key;
      _themes.clear();
    }
    return _themes.putIfAbsent(
      brightness,
      () => novelTheme(
        brightness,
        fontFamily: state.currentFont.family,
        fontFamilyFallback: state.fontFamilyFallback,
        palette: state.appPalette,
        systemColors: state.systemTonalColors,
        originalVariant: state.paletteVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state.applicationChanges,
      builder: (context, child) {
        // 动效档: 标准 keeps v1.7.1 durations, 轻 (default) the shortened ones.
        NovelMotion.standard = state.motionLevel == MotionLevel.standard;
        final typefaceChanged = _lastFontId != state.appFontId;
        _lastFontId = state.appFontId;
        return MaterialApp(
          title: '书屿',
          locale: state.language.locale ?? _systemLocale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'HK'),
            Locale('zh', 'TW'),
          ],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          localeResolutionCallback: (locale, _) =>
              chineseLocale(state.language.locale ?? locale),
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NovelScrollBehavior(),
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: state.theme,
          themeAnimationDuration:
              typefaceChanged ||
                  state.effectiveReduceMotion ||
                  (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
              ? Duration.zero
              : NovelMotion.enter,
          themeAnimationCurve: NovelMotion.ease,
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final content = PerformanceScope(
              preferences: state.effectivePerformance,
              explicitReduceMotion:
                  media.disableAnimations || state.reduceMotion,
              child: MediaQuery(
                data: media.copyWith(
                  disableAnimations:
                      media.disableAnimations || state.effectiveReduceMotion,
                ),
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: novelSystemUiStyle(Theme.of(context).brightness),
                  child: AnimatedBuilder(
                    animation: state.glassChanges,
                    child: child,
                    builder: (context, child) {
                      final glass = state.resolvedGlass;
                      return GlassAppearance(
                        blur: glass.blur,
                        opacity: glass.opacity,
                        refractionScale: glass.tier.refractionScale,
                        edgeMode: glass.tier.edge,
                        highlight: glass.tier.highlight,
                        child: ListeningScope(
                          controller: listening,
                          child: child!,
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
            return HapticScope(
              preferences: state.haptics,
              child: updates == null
                  ? content
                  : AppUpdateMonitor(updates: updates!, child: content),
            );
          },
          home: _HomeViewport(state: state, repository: repository),
        );
      },
    );
  }
}

class _HomeViewport extends StatefulWidget {
  const _HomeViewport({required this.state, required this.repository});
  final LibraryState state;
  final NovelRepository repository;

  @override
  State<_HomeViewport> createState() => _HomeViewportState();
}

class _HomeViewportState extends State<_HomeViewport> {
  MediaQueryData? _lastMetrics;

  @override
  Widget build(BuildContext context) {
    final metrics = MediaQuery.of(context);
    final valid = !metrics.size.isEmpty &&
        metrics.size.width.isFinite && metrics.size.height.isFinite;
    if (valid) _lastMetrics = metrics;
    final retained = _lastMetrics;
    if (retained == null) return const SizedBox.shrink();
    return Offstage(
      offstage: !valid,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: retained.size.width,
        maxWidth: retained.size.width,
        minHeight: retained.size.height,
        maxHeight: retained.size.height,
        child: MediaQuery(
          data: retained,
          child: HomeShell(state: widget.state, repository: widget.repository),
        ),
      ),
    );
  }
}
