import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_ui.dart';
import 'app_licenses.dart';
import 'app_typography.dart';
import 'book_tags.dart';
import 'catalog.dart';
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
import 'touch_sampling.dart';
import 'updates/app_updates.dart';
import 'updates/update_page.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  registerAppLicenses();
  TouchSamplingPolicy(binding);
  // Do not hold the first frame while Android is applying window insets.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  final state = await LibraryState.load();
  await state.ensureFontLoaded();
  await TagStore.load();
  if (state.performance.needsRuntimeEffects) await NativeEffects.prepare();
  final brightness = switch (state.theme) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };
  SystemChrome.setSystemUIOverlayStyle(novelSystemUiStyle(brightness));
  final remote = LegacyWenkuRepository();
  final repository = defaultTargetPlatform == TargetPlatform.android
      ? CompositeNovelRepository(
          local: await LocalLibraryStore.load(),
          remote: OfflineNovelRepository(
            remote: remote,
            cache: await OfflineCacheStore.forApp(),
          ),
        )
      : const DemoNovelRepository();
  if (repository is CompositeNovelRepository) {
    state.bindLocalChapters(repository.local);
  }
  final listening = defaultTargetPlatform == TargetPlatform.android
      ? ListeningController(
          repository: repository,
          audio: await SpeechAudioCache.forApp(),
          store: ListeningStore(await SharedPreferences.getInstance()),
          outputFactory: createListeningOutput,
        )
      : null;
  runApp(
    NovelApp(
      state: state,
      repository: repository,
      listening: listening,
      updates: defaultTargetPlatform == TargetPlatform.android
          ? AppUpdates(preferences: await SharedPreferences.getInstance())
          : null,
    ),
  );
  if (listening != null) {
    // Register media commands without allocating a player or blocking the first
    // frame. A service-created engine also gets a handler, with no auto-play.
    unawaited(prepareListeningService(listening).catchError((Object _) {}));
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

class _NovelAppState extends State<NovelApp> {
  LibraryState get state => widget.state;
  NovelRepository get repository => widget.repository;
  ListeningController? get listening => widget.listening;
  AppUpdates? get updates => widget.updates;
  late String _lastFontId = state.appFontId;
  static final _themes =
      <(TargetPlatform, Brightness, String), ThemeData>{};

  ThemeData _theme(Brightness brightness) => _themes.putIfAbsent((
    defaultTargetPlatform,
    brightness,
    state.appFontId,
  ), () => novelTheme(
        brightness,
        fontFamily: state.currentFont.family,
        fontFamilyFallback: state.fontFamilyFallback,
      ));

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state.applicationChanges,
      builder: (context, child) {
        final typefaceChanged = _lastFontId != state.appFontId;
        _lastFontId = state.appFontId;
        return MaterialApp(
          title: '轻小说文库',
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
              preferences: state.performance,
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
                    builder: (context, child) => GlassAppearance(
                      blur: state.glassBlur,
                      opacity: state.glassOpacity,
                      child: ListeningScope(
                        controller: listening,
                        child: child!,
                      ),
                    ),
                  ),
                ),
              ),
            );
            return updates == null
                ? content
                : AppUpdateMonitor(updates: updates!, child: content);
          },
          home: Builder(
            builder: (context) {
              // A newly attached Android surface can report a zero-sized view.
              // Do not create a glass geometry texture until metrics are ready.
              if (MediaQuery.sizeOf(context).isEmpty) {
                return const SizedBox.shrink();
              }
              return HomeShell(state: state, repository: repository);
            },
          ),
        );
      },
    );
  }
}
