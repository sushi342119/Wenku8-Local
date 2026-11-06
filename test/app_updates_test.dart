import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/updates/app_updates.dart';

import 'fixtures/legacy_app_updates_v1_8_1_48.dart' as legacy;

const _repo = 'example/reader';
Map<String, dynamic> _json({
  String tag = 'v0.3.0',
  List<Map<String, dynamic>>? assets,
}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'body': '### 新功能\n- 阅读改进',
  'assets':
      assets ??
      [
        for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64'])
          {
            'name': 'wenku8-0.3.0-$abi.apk',
            'size': 16,
            'browser_download_url':
                'https://github.com/$_repo/releases/download/$tag/wenku8-0.3.0-$abi.apk',
          },
      ],
};

// Example future version for migration tests; this does not bump the app.
const _migrationTag = 'v1.8.2+49';
Map<String, dynamic> _namedAsset(
  String name, {
  bool encodeTag = true,
  String? url,
}) => {
  'name': name,
  'size': 16,
  'browser_download_url':
      url ??
      'https://github.com/$_repo/releases/download/'
          '${encodeTag ? _migrationTag.replaceAll('+', '%2B') : _migrationTag}/'
          '${Uri.encodeComponent(name)}',
};
String _apk(String prefix, [String abi = 'arm64-v8a']) =>
    '$prefix-$_migrationTag-$abi.apk';
AppRelease _migrationRelease(List<Map<String, dynamic>> assets) =>
    AppRelease.fromGithub(_json(tag: _migrationTag, assets: assets), _repo)!;

const _installed = InstalledApp(
  version: '0.2.0',
  build: 2,
  abis: ['arm64-v8a', 'armeabi-v7a'],
);

class _Platform implements UpdatePlatform {
  String result = 'opened';
  String? failure;
  int installs = 0;
  @override
  Future<InstalledApp> installedApp() async => _installed;
  @override
  Future<String> install(File apk, String version) async {
    installs++;
    if (failure != null) {
      throw PlatformException(code: 'APK_REJECTED', message: failure);
    }
    return result;
  }

  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> openRelease(Uri page) async {}
}

class _Source implements UpdateSource {
  AppRelease? release = AppRelease.fromGithub(_json(), _repo);
  int checks = 0;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<AppRelease?> latest() async {
    checks++;
    if (fail) throw const SocketException('offline');
    return release;
  }

  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int) progress,
  ) async {
    await file.writeAsBytes([1, 2, 3]);
    progress(3);
    if (gate != null) await gate!.future;
    task.check();
    if (fail) throw const SocketException('offline');
  }
}

class _Headers extends Fake implements HttpHeaders {
  _Headers([this.location]);
  final String? location;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
}

class _Reply extends Stream<List<int>> implements HttpClientResponse {
  _Reply(this.statusCode, this.chunks, [String? location])
    : headers = _Headers(location);
  @override
  final int statusCode;
  final List<List<int>> chunks;
  @override
  final HttpHeaders headers;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.reply);
  final _Reply reply;
  @override
  final HttpHeaders headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  Future<HttpClientResponse> close() async => reply;
}

class _Client extends Fake implements HttpClient {
  _Client(this.replies);
  final List<_Reply> replies;
  final urls = <Uri>[];
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return _Request(replies.removeAt(0));
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'semantic versions compare numerically and build-only releases are newer',
    () {
      expect(
        ReleaseVersion.parse(
          'v0.10.0',
        )!.compareTo(ReleaseVersion.parse('0.9.9')!),
        greaterThan(0),
      );
      for (final tag in ['v1', 'v0.3.0-beta', 'v0.3.0/../../x', '0.3.0+bad']) {
        expect(ReleaseVersion.parse(tag), isNull);
      }
      expect(
        AppRelease.fromGithub(
          _json(tag: 'v0.2.0'),
          _repo,
        )!.isNewerThan(_installed),
        false,
      );
      expect(
        AppRelease.fromGithub(
          _json(tag: 'v0.2.0+3'),
          _repo,
        )!.isNewerThan(_installed),
        true,
      );
      expect(
        AppRelease.fromGithub(_json(), _repo)!.isNewerThan(_installed),
        true,
      );
    },
  );
  test(
    'stable, repository-bound assets select the device ABI without mixing architectures',
    () {
      final release = AppRelease.fromGithub(_json(), _repo)!;
      expect(
        release.assetFor(_installed.abis)!.name,
        endsWith('-arm64-v8a.apk'),
      );
      expect(release.assetFor(['riscv64']), isNull);
      for (final field in ['draft', 'prerelease']) {
        expect(AppRelease.fromGithub(_json()..[field] = true, _repo), isNull);
      }
      final bad = _json(
        assets: [
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 16,
            'browser_download_url': 'https://evil.example/a.apk',
          },
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 16,
            'browser_download_url':
                'https://github.com/other/repo/releases/download/v0.3.0/wenku8-x-arm64-v8a.apk',
          },
          {
            'name': 'wenku8-x-arm64-v8a.apk',
            'size': 0,
            'browser_download_url':
                'https://github.com/$_repo/releases/download/v0.3.0/wenku8-x-arm64-v8a.apk',
          },
        ],
      );
      expect(AppRelease.fromGithub(bad, _repo)!.assets, isEmpty);
    },
  );

  group('APK filename migration', () {
    test('both brands retain every supported ABI suffix', () {
      for (final prefix in ['shuyu', 'wenku8-local']) {
        for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
          final name = _apk(prefix, abi);
          final release = _migrationRelease([_namedAsset(name)]);
          expect(release.assetFor([abi])?.name, name);
          expect(release.assetFor(['riscv64']), isNull);
        }
      }
    });

    test('both brands accept raw and percent-encoded build tags', () {
      for (final prefix in ['shuyu', 'wenku8-local']) {
        for (final encodeTag in [false, true]) {
          final name = _apk(prefix);
          final asset = _migrationRelease([
            _namedAsset(name, encodeTag: encodeTag),
          ]).assetFor(['arm64-v8a']);
          expect(asset?.name, name);
          expect(asset?.url.pathSegments.last, name);
        }
      }
    });

    test('same ABI prefers shuyu independently of GitHub asset ordering', () {
      final names = [_apk('wenku8-local'), _apk('shuyu')];
      for (final order in [names, names.reversed.toList()]) {
        final release = _migrationRelease([
          for (final name in order) _namedAsset(name),
        ]);
        expect(release.assets, hasLength(2));
        expect(release.assetFor(['arm64-v8a'])?.name, _apk('shuyu'));
      }
    });

    test('device ABI order outranks branding, universal is last', () {
      final release = _migrationRelease([
        _namedAsset(_apk('shuyu', 'armeabi-v7a')),
        _namedAsset(_apk('shuyu', 'universal')),
        _namedAsset(_apk('wenku8-local')),
      ]);
      expect(
        release.assetFor(['arm64-v8a', 'armeabi-v7a'])?.name,
        _apk('wenku8-local'),
      );
      expect(
        release.assetFor(['armeabi-v7a', 'arm64-v8a'])?.name,
        _apk('shuyu', 'armeabi-v7a'),
      );
      expect(release.assetFor(['riscv64'])?.name, _apk('shuyu', 'universal'));
      expect(
        _migrationRelease([_namedAsset(_apk('shuyu'))]).assetFor(['riscv64']),
        isNull,
      );
      expect(
        _migrationRelease([
          _namedAsset(_apk('wenku8-local', 'universal')),
        ]).assetFor(['riscv64'])?.name,
        _apk('wenku8-local', 'universal'),
      );
    });

    test('new prefix preserves repository, tag, name and size checks', () {
      for (final prefix in ['shuyu', 'wenku8-local']) {
        final name = _apk(prefix);
        for (final url in [
          'https://evil.example/$name',
          'http://github.com/$_repo/releases/download/$_migrationTag/$name',
          'https://github.com/other/repo/releases/download/$_migrationTag/$name',
          'https://github.com/$_repo/releases/download/v9.0.0/$name',
          'https://github.com/$_repo/releases/download/$_migrationTag/other.apk',
          'https://user@github.com/$_repo/releases/download/$_migrationTag/$name',
          'https://github.com:444/$_repo/releases/download/$_migrationTag/$name',
        ]) {
          expect(
            _migrationRelease([_namedAsset(name, url: url)]).assets,
            isEmpty,
          );
        }
        for (final size in [0, -1, 300 * 1024 * 1024 + 1, '16']) {
          expect(
            _migrationRelease([_namedAsset(name)..['size'] = size]).assets,
            isEmpty,
          );
        }
        for (final field in ['draft', 'prerelease']) {
          expect(
            AppRelease.fromGithub(
              _json(tag: _migrationTag, assets: [_namedAsset(name)])
                ..[field] = true,
              _repo,
            ),
            isNull,
          );
        }
      }
      for (final name in [
        _apk('other'),
        'shuyu-source.zip',
        '${_apk('shuyu')}.sha256',
      ]) {
        expect(_migrationRelease([_namedAsset(name)]).assets, isEmpty);
      }
    });

    test(
      'frozen v1.8.1+48 skips bridge releases and finds the legacy alias',
      () {
        for (final encodeTag in [false, true]) {
          final assets = [
            _namedAsset(_apk('shuyu'), encodeTag: encodeTag),
            _namedAsset(_apk('wenku8-local'), encodeTag: encodeTag),
          ];
          for (final order in [assets, assets.reversed.toList()]) {
            final json = _json(tag: _migrationTag, assets: order);
            final oldRelease = legacy.AppRelease.fromGithub(json, _repo)!;
            expect(oldRelease.assets, hasLength(1));
            expect(
              oldRelease.assetFor(['arm64-v8a'])?.name,
              _apk('wenku8-local'),
            );
            expect(
              oldRelease.isNewerThan(
                const legacy.InstalledApp(
                  version: '1.8.1',
                  build: 48,
                  abis: ['arm64-v8a'],
                ),
              ),
              isTrue,
            );
            expect(
              AppRelease.fromGithub(json, _repo)!.assetFor(['arm64-v8a'])?.name,
              _apk('shuyu'),
            );
          }
        }
        // Negative control: a shuyu-only latest release strands old clients.
        final onlyNew = legacy.AppRelease.fromGithub(
          _json(tag: _migrationTag, assets: [_namedAsset(_apk('shuyu'))]),
          _repo,
        )!;
        expect(onlyNew.assetFor(['arm64-v8a']), isNull);
      },
    );
  });

  late Directory temp;
  late _Source source;
  late _Platform platform;
  late AppUpdates updates;
  var now = DateTime(2026, 10, 15);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('wenku8-update-test-');
    source = _Source();
    platform = _Platform();
    updates = AppUpdates(
      preferences: await SharedPreferences.getInstance(),
      source: source,
      platform: platform,
      directory: () async => temp,
      clock: () => now,
    );
  });
  tearDown(() async {
    updates.dispose();
    await temp.delete(recursive: true);
  });
  test(
    'automatic checks throttle and respect opt-out; manual retry is immediate',
    () async {
      await updates.check(automatic: true);
      await updates.check(automatic: true);
      expect(source.checks, 1);
      expect(updates.available, true);
      now = now.add(const Duration(hours: 7));
      await updates.check(automatic: true);
      expect(source.checks, 2);
      await updates.setAutoCheck(false);
      now = now.add(const Duration(hours: 7));
      await updates.check(automatic: true);
      expect(source.checks, 2);
      await updates.check();
      expect(source.checks, 3);
    },
  );
  test('no release and network failure remain recoverable', () async {
    source.release = null;
    await updates.check();
    expect(updates.checked, true);
    expect(updates.available, false);
    expect(updates.error, null);
    source.fail = true;
    await updates.check();
    expect(updates.error, isNotNull);
    source.fail = false;
    source.release = AppRelease.fromGithub(_json(), _repo);
    await updates.check();
    expect(updates.available, true);
    expect(updates.error, null);
  });
  test(
    'download, explicit permission and installation are separate actions',
    () async {
      await updates.check();
      await updates.download();
      expect(await updates.downloaded!.readAsBytes(), [1, 2, 3]);
      expect(platform.installs, 0);
      platform.result = 'permission';
      await updates.install();
      expect(updates.needsPermission, true);
      platform.result = 'opened';
      await updates.install();
      expect(updates.needsPermission, false);
      platform.failure = '安装包签名与当前版本不一致，无法覆盖升级';
      await updates.install();
      expect(updates.error, contains('签名'));
    },
  );
  test(
    'cancel and interrupted downloads remove partial files and can be retried',
    () async {
      await updates.check();
      source.gate = Completer<void>();
      final downloading = updates.download();
      for (var i = 0; i < 20 && updates.bytes == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      updates.cancelDownload();
      source.gate!.complete();
      await downloading;
      expect(updates.downloaded, isNull);
      expect(updates.error, null);
      expect(
        await File('${temp.path}/updates/pending.apk.part').exists(),
        false,
      );
      source.gate = null;
      source.fail = true;
      await updates.download();
      expect(updates.error, isNotNull);
      source.fail = false;
      await updates.download();
      expect(updates.downloaded, isNotNull);
    },
  );
  test(
    'GitHub transport checks status and treats 404 as no published release',
    () async {
      final client = _Client([
        _Reply(404, []),
        _Reply(200, [utf8.encode(jsonEncode(_json()))]),
        _Reply(403, []),
      ]);
      final github = GithubUpdateSource(
        repository: _repo,
        clientFactory: () => client,
      );
      expect(await github.latest(), isNull);
      expect((await github.latest())!.version.name, '0.3.0');
      await expectLater(github.latest(), throwsA(isA<HttpException>()));
      expect(
        client.urls.first.toString(),
        'https://api.github.com/repos/$_repo/releases/latest',
      );
    },
  );
  test(
    'APK transfer validates redirect destinations, byte count and supplied integrity digest',
    () async {
      final data = utf8.encode('signed APK fixture');
      final asset = UpdateAsset(
        name: 'wenku8-0.3.0-arm64-v8a.apk',
        url: Uri.parse(
          'https://github.com/$_repo/releases/download/v0.3.0/app.apk',
        ),
        size: data.length,
        digest: sha256.convert(data).toString(),
      );
      final file = File('${temp.path}/transfer.apk');
      final good = _Client([
        _Reply(302, [], 'https://release-assets.githubusercontent.com/asset'),
        _Reply(200, [data.sublist(0, 4), data.sublist(4)]),
      ]);
      await GithubUpdateSource(
        clientFactory: () => good,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(await file.readAsBytes(), data);
      final evil = _Client([
        _Reply(302, [], 'https://evil.example/package.apk'),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => evil,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      final incomplete = _Client([
        _Reply(200, [data.sublist(1)]),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => incomplete,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
      final changed = [...data]..[0] ^= 1;
      final tampered = _Client([
        _Reply(200, [changed]),
      ]);
      await expectLater(
        GithubUpdateSource(
          clientFactory: () => tampered,
        ).download(asset, file, UpdateDownload(), (_) {}),
        throwsFormatException,
      );
    },
  );

  test(
    'both APK names pass through parsing, transfer and install handoff',
    () async {
      final data = utf8.encode('APK transport fixture');
      for (final prefix in ['shuyu', 'wenku8-local']) {
        final name = _apk(prefix);
        final raw = _namedAsset(name)
          ..['size'] = data.length
          ..['digest'] = 'sha256:${sha256.convert(data)}';
        final client = _Client([
          _Reply(200, [
            utf8.encode(jsonEncode(_json(tag: _migrationTag, assets: [raw]))),
          ]),
          _Reply(
            302,
            [],
            'https://release-assets.githubusercontent.com/fixture',
          ),
          _Reply(200, [data]),
        ]);
        final service = AppUpdates(
          preferences: await SharedPreferences.getInstance(),
          source: GithubUpdateSource(
            repository: _repo,
            clientFactory: () => client,
          ),
          platform: platform,
          directory: () async => temp,
        );
        try {
          await service.check();
          expect(service.available, isTrue);
          expect(service.asset?.name, name);
          await service.download();
          expect(service.error, isNull);
          expect(await service.downloaded!.readAsBytes(), data);
          expect(service.downloaded!.path, '${temp.path}/updates/update.apk');
          expect(client.urls[1].pathSegments.last, name);
          expect(client.urls.last.host, 'release-assets.githubusercontent.com');
          final installs = platform.installs;
          await service.install();
          expect(service.error, isNull);
          expect(platform.installs, installs + 1);
        } finally {
          service.dispose();
        }
      }
    },
  );

  test(
    'missing digest retains the existing size-checked download behavior',
    () async {
      final data = utf8.encode('synthetic package fixture');
      final asset = UpdateAsset(
        name: 'wenku8-fixture.apk',
        url: Uri.parse(
          'https://github.com/$_repo/releases/download/v0.3.0/fixture.apk',
        ),
        size: data.length,
      );
      final file = File('${temp.path}/fixture.apk');
      final client = _Client([
        _Reply(200, [data]),
      ]);
      await GithubUpdateSource(
        clientFactory: () => client,
      ).download(asset, file, UpdateDownload(), (_) {});
      expect(await file.readAsBytes(), data);
    },
  );
}
