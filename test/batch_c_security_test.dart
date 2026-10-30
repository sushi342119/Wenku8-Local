import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_typography.dart';
import 'package:wenku8_flutter/filename_tags.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/legacy_transport.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/listening/edge_tts.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/local_scan_follow_up.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/wenku_errors.dart';

import 'support/offline_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Http extends HttpOverrides {
  _Http(this.client);
  final HttpClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

class _HandshakeClient implements HttpClient {
  _HandshakeClient(this.failure);
  final WebSocketException failure;
  int connections = 0;
  int voiceRefreshes = 0;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    connections++;
    throw failure;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    voiceRefreshes++;
    throw const SocketException('synthetic offline');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('error summaries and restored failures discard untrusted details', () {
    final failure = StateError('synthetic-sensitive-detail');
    expect(describeSafeError(failure), isNot(contains('synthetic-sensitive-detail')));
    final task = LocalChapterRemap.create(
      bookId: localNovelIdBase,
      oldChapters: const [(offset: 0, length: 10)],
      newChapters: const [(offset: 0, length: 10)],
    ).withFailure(failure);
    expect(task.lastError, 'StateError: 章节迁移失败');
    final old = task.toJson()..['lastError'] = 'synthetic-sensitive-detail';
    expect(LocalChapterRemap.fromJson(old).toJson()['lastError'], '章节迁移失败');
    expect(LocalScanFollowUpException(LocalScanFollowUp(cleanupError: failure)).toString(),
      isNot(contains('synthetic-sensitive-detail')));
  });

  test('filename tags reject traversal, controls and UTF-8 byte overflow', () {
    for (final tag in ['.', '..', '../x', 'x/y', 'x\\y', 'x\u0000', 'x\u0001', 'x\u007f', '字' * 22]) {
      expect(() => appendFilenameTags('book.txt', [tag]), throwsArgumentError);
    }
    expect(() => appendFilenameTags('${'字' * 82}.txt', ['已读']), throwsArgumentError);
    expect(appendFilenameTags('book.txt', ['字' * 21]), contains('字' * 21));
  });

  test('backup rejects external covers, excessive fields and search controls', () async {
    final snapshot = offlineFixtureBook(71).toSnapshot();
    final position = const ReadingPosition(
      chapter: 0, chapterId: 1, offset: 0, fraction: 0,
      fontSize: 18, width: 390, updatedAt: 1,
    ).toJson();
    for (final records in <Map<String, Object>>[
      {'recentSearches': ['bad\u0000']},
      {'recentSearches': ['字' * 121]},
      {'novel_meta_71': jsonEncode({...snapshot, 'coverUrl': 'https://outside.invalid/cover'})},
      {'novel_meta_71': jsonEncode({...snapshot, 'coverUrl': 'https://wenku8.com:8443/cover'})},
      {'reader_bookmarks_71': jsonEncode([{'id': 'mark', 'chapterTitle': '字' * 2049, 'position': position}])},
      {'reader_bookmarks_71': jsonEncode([{'id': 'x' * 129, 'chapterTitle': 'title', 'position': position}])},
    ]) {
      await expectLater(LibraryBackup.fromRecords(records), throwsFormatException);
    }
    final valid = await LibraryBackup.fromRecords({
      'recentSearches': ['  Book  ', 'book'],
      'novel_meta_71': jsonEncode({...snapshot, 'coverUrl': 'https://img.wenku8.com/cover'}),
    });
    expect(valid.records['recentSearches'], ['Book']);
  });

  test('illustration boundary rejects invalid addresses before invoking native', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(LegacyTransport.channel, (call) async {
      calls++;
      expect((call.arguments as Map)['url'], 'https://pic.wenku8.cn/image');
      return Uint8List.fromList([1]);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(LegacyTransport.channel, null));
    for (final url in [
      'file:///synthetic-image', 'https://outside.invalid/image',
      'https://wenku8.com:8443/image', 'https://user@wenku8.com/image',
      'https://wenku8.com.outside.invalid/image',
    ]) {
      expect(normalizeReaderIllustrationUrl(url), isNull);
      await expectLater(LegacyTransport.illustration(url), throwsFormatException);
    }
    expect(calls, 0);
    await LegacyTransport.illustration('http://pic.wenku8.cn/image');
    expect(calls, 1);
  });

  test('local cover never reaches native regardless of seeding order', () async {
    var calls = 0;
    const channel = MethodChannel('org.mewx.wenku8/legacy_api');
    messenger.setMockMethodCallHandler(channel, (call) async { calls++; return Uint8List(1); });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const id = localNovelIdBase + 1234;
    await expectLater(LegacyCover.bytes(id), throwsFormatException);
    LegacyCover.seedLocalBytes(id, Uint8List.fromList([1, 2]));
    expect(await LegacyCover.bytes(id), [1, 2]);
    expect(calls, 0);
  });

  test('platform failures do not expose provider message or unknown code', () async {
    messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      throw PlatformException(code: 'synthetic-sensitive-code', message: 'synthetic-sensitive-detail');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(LocalPlatform.channel, null));
    await expectLater(LocalPlatform.renameLocalDocument('content://synthetic/document/1', 'book.txt'),
      throwsA(isA<LocalRenameException>().having((error) => error.toString(), 'safe text', isNot(contains('synthetic-sensitive')))));
    await expectLater(deleteLocalDocumentWithChannel(LocalPlatform.channel, 'content://synthetic/document/1'),
      throwsA(isA<LocalDeleteException>().having((error) => error.toString(), 'safe text', isNot(contains('synthetic-sensitive')))));
  });

  for (final status in [403, 500, null]) {
    test('speech retries only a forbidden handshake: $status', () async {
      final client = _HandshakeClient(WebSocketException('synthetic-sensitive-detail status code: 403', status));
      final errors = <Object>[];
      await HttpOverrides.runWithHttpOverrides(() async {
        await expectLater(EdgeSpeechClient(onTransportError: errors.add).synthesize(
          '合成测试文字', defaultEdgeVoice, SpeechCancellation()), throwsA(isA<SpeechFailure>()));
      }, _Http(client));
      expect(client.connections, status == 403 ? 2 : 1);
      expect(client.voiceRefreshes, status == 403 ? 1 : 0);
      expect(errors, isNotEmpty);
      for (final error in errors) {
        expect(error.toString(), isNot(contains('synthetic-sensitive-detail')));
      }
    });
  }

  group('private font boundary', () {
    late Directory root;
    late PathProviderPlatform previous;
    late LibraryState state;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('batch-c-font-');
      await Directory('${root.path}/fonts').create();
      previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferences.setMockInitialValues({'appFontId': 'system'});
      state = await LibraryState.load();
    });
    tearDown(() async {
      state.dispose();
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
    test('magic-only fake font cannot be registered', () async {
      final file = File('${root.path}/fonts/fake.ttf');
      await file.writeAsBytes([0, 1, 0, 0, ...List.filled(8, 0)]);
      await expectLater(state.registerImportedFont(file.path, 'fake'), throwsStateError);
      expect(await file.exists(), false);
    });
    test('valid bundled font can be registered and removed', () async {
      final bytes = await rootBundle.load('assets/fonts/SourceHanSerifCN-Regular.otf');
      final file = File('${root.path}/fonts/valid.otf');
      await file.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      final id = await state.registerImportedFont(file.path, 'test font');
      expect(await file.exists(), true);
      await state.removeImportedFont(id);
      expect(await file.exists(), false);
    });
    test('outside paths and symlinks cannot register or delete outside files', () async {
      final outside = File('${root.path}/outside.ttf');
      await outside.writeAsBytes([0, 1, 0, 0]);
      final link = Link('${root.path}/fonts/link.ttf');
      await link.create(outside.path);
      for (final path in [outside.path, link.path]) {
        await expectLater(state.registerImportedFont(path, 'outside'), throwsStateError);
      }
      final entry = AppFontEntry(id: 'outside', displayName: 'outside', family: 'outside',
        source: AppFontSource.imported, filePath: link.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('importedFonts', jsonEncode([entry.toJson()]));
      state.dispose();
      state = await LibraryState.load();
      await state.removeImportedFont(entry.id);
      expect(await outside.exists(), true);
      expect(await link.exists(), true);
    });
  });
}
