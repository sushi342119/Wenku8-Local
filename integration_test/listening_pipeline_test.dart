import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/audio_output.dart';
import 'package:wenku8_flutter/listening/cache.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';
import 'package:wenku8_flutter/listening/widgets.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android Edge MP3, native playback, seek, notification and reader controls',
    (tester) async {
      await NativeEffects.prepare();
      final prefs = await SharedPreferences.getInstance();
      final store = ListeningStore(prefs);
      await store.saveVoice(defaultEdgeVoice);
      await store.saveSpeed(1);
      await store.saveFollow(false);
      final library = await LibraryState.load();
      await library.setReduceMotion(true);
      const novel = Novel(
        id: 93001,
        title: '听书链路测试',
        author: '本地测试',
        genre: '测试',
        summary: '',
        colors: [Colors.grey, Colors.black],
        chapters: [
          NovelChapter(
            '夜色与书页',
            '夜色渐深，微风翻过书页。这是一段中文朗读测试。读书的时候，时光慢了下来，故事沿着月光继续。\n\n第二段正文，用来核对连续朗读与段落定位。',
          ),
          NovelChapter('下一章', '新的一章开始了，故事仍在继续。'),
        ],
      );
      final cache = await SpeechAudioCache.forApp();
      final controller = ListeningController(
        repository: const DemoNovelRepository(),
        audio: cache,
        store: store,
        outputFactory: createListeningOutput,
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: MaterialApp(
          theme: novelTheme(Brightness.light),
          builder: (context, child) =>
              ListeningScope(controller: controller, child: child!),
          home: ReaderPage(
            novel: novel,
            state: library,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        )),
      );
      await tester.pumpAndSettle();
      await controller.start(novel, chapter: 0);
      expect(
        controller.snapshot.value.phase,
        ListeningPhase.playing,
        reason: controller.snapshot.value.error,
      );
      expect(
        controller.progress.value.duration.inMilliseconds,
        greaterThan(1000),
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        controller.progress.value.position.inMilliseconds,
        greaterThan(100),
      );
      await controller.pause();
      final position = controller.progress.value.position;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        (controller.progress.value.position - position).inMilliseconds.abs(),
        lessThan(120),
      );
      await controller.seek(const Duration(seconds: 1));
      expect(controller.savedCursor(novel.id)!.positionMs, 1000);
      await controller.setSpeed(1.25);
      await controller.resume();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await controller.pause();
      expect(
        controller.progress.value.position.inMilliseconds,
        greaterThan(1000),
      );
      final entry = find
          .descendant(
            of: find.byKey(const ValueKey('reader-listening-entry')),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('音源与音色'), findsOneWidget);
      expect(tester.takeException(), null);
      if (const bool.fromEnvironment('CAPTURE_LISTENING')) {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('${Directory.systemTemp.path}/listening-panel.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        // ignore: avoid_print
        print('LISTENING_SCREENSHOT_PATH=${file.path}');
      }
      // Read-only capture window on the owned, no-audio emulator, never on the user's phone.
      // ignore: avoid_print
      print(
        'LISTENING_CAPTURE_READY duration=${controller.progress.value.duration.inMilliseconds} position=${controller.progress.value.position.inMilliseconds}',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await controller.stop();
      expect(controller.snapshot.value.phase, ListeningPhase.stopped);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
      library.dispose();
    },
  );
}
