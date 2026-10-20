import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const updateRepository = String.fromEnvironment(
  'UPDATE_REPOSITORY',
  defaultValue: 'sushi342119/Wenku8-Local',
);
const currentAppVersion = '1.2.2';
const currentAppBuild = 1008;
// 试验版（source-trial 分支）走独立更新通道：只认 source- 前缀的 tag。
// 构建时通过 --dart-define=TRIAL_CHANNEL=true 开启。
const trialChannel = bool.fromEnvironment(
  'TRIAL_CHANNEL',
  defaultValue: false,
);
const currentReleaseNotes = '''
【书源试验版】
1. 新增书源试验入口：123小说网（单站点接入试验）
2. 支持搜索、目录解析、正文下载转本地 TXT 入库
3. 站点基址可在设置中手动修改
''';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch, [this.build = 0]);
  final int major, minor, patch, build;
  static ReleaseVersion? parse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 4; i++) int.tryParse(match[i] ?? '0')];
    if (parts.any((n) => n == null || n > 2100000000)) return null;
    return ReleaseVersion(parts[0]!, parts[1]!, parts[2]!, parts[3]!);
  }

  String get name => '$major.$minor.$patch';
  @override
  int compareTo(ReleaseVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (build, other.build),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    return 0;
  }
}

class InstalledApp {
  const InstalledApp({
    required this.version,
    required this.build,
    required this.abis,
  });
  final String version;
  final int build;
  final List<String> abis;
  ReleaseVersion? get releaseVersion {
    final parsed = ReleaseVersion.parse(version);
    return parsed == null
        ? null
        : ReleaseVersion(parsed.major, parsed.minor, parsed.patch, build);
  }
}

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    this.digest,
  });
  final String name;
  final Uri url;
  final int size;
  final String? digest;
}

class AppRelease {
  const AppRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.page,
    required this.assets,
  });
  final String tag, notes;
  final ReleaseVersion version;
  final Uri page;
  final List<UpdateAsset> assets;
  static AppRelease? fromGithub(
    Map<String, dynamic> json,
    String repository, {
    bool trial = false,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const FormatException('更新仓库格式错误');
    }
    if (json['draft'] == true) return null;
    // 试验 release 发布为 prerelease，避免占用 /releases/latest 影响正式版；
    // 试验通道接受 prerelease，正式通道不接受。
    if (!trial && json['prerelease'] == true) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    // 严格通道隔离：试验 tag 必须带 source- 前缀，正式 tag 不带；
    // 不匹配直接拒绝，不依赖调用方过滤。
    final isTrialTag = tag.startsWith('source-');
    if (isTrialTag != trial) return null;
    final versionTag = isTrialTag ? tag.substring('source-'.length) : tag;
    final version = ReleaseVersion.parse(versionTag);
    if (version == null) return null;
    final assets = <UpdateAsset>[];
    for (final raw in (json['assets'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final name = raw['name'];
      final url = Uri.tryParse(raw['browser_download_url']?.toString() ?? '');
      // GitHub 的 browser_download_url 会把 tag 中的 + 编码为 %2B
      //（如 source-v1.2.2+1006 → source-v1.2.2%2B1006），两种写法都接受。
      final encodedTag = tag.replaceAll('+', '%2B');
      final underRelease =
          url?.path.startsWith('/$repository/releases/download/$tag/') ==
              true ||
          url?.path.startsWith(
                '/$repository/releases/download/$encodedTag/',
              ) ==
              true;
      final size = raw['size'];
      if (name is! String ||
          !name.startsWith('wenku8-') ||
          !name.endsWith('.apk') ||
          url == null ||
          url.scheme != 'https' ||
          url.host != 'github.com' ||
          url.userInfo.isNotEmpty ||
          url.port != 443 ||
          !underRelease ||
          url.pathSegments.last != name ||
          size is! int ||
          size <= 0 ||
          size > 300 * 1024 * 1024) {
        continue;
      }
      final digest = raw['digest']?.toString();
      assets.add(
        UpdateAsset(
          name: name,
          url: url,
          size: size,
          digest:
              digest != null &&
                  RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)
              ? digest.substring(7).toLowerCase()
              : null,
        ),
      );
    }
    return AppRelease(
      tag: tag as String,
      version: version,
      notes: json['body'] is String ? json['body'] as String : '',
      page: Uri.https('github.com', '/$repository/releases/tag/$tag'),
      assets: assets,
    );
  }

  bool isNewerThan(InstalledApp app) {
    final installed = app.releaseVersion;
    if (installed == null) return false;
    final semantic = ReleaseVersion(version.major, version.minor, version.patch)
        .compareTo(
          ReleaseVersion(installed.major, installed.minor, installed.patch),
        );
    return semantic > 0 || (semantic == 0 && version.build > installed.build);
  }

  UpdateAsset? assetFor(List<String> abis) {
    for (final abi in abis) {
      for (final asset in assets) {
        if (asset.name.endsWith('-$abi.apk')) return asset;
      }
    }
    for (final asset in assets) {
      if (asset.name.endsWith('-universal.apk')) return asset;
    }
    return null;
  }
}

abstract interface class UpdatePlatform {
  Future<InstalledApp> installedApp();
  Future<String> install(File apk, String version);
  Future<void> allowInstalls();
  Future<void> openRelease(Uri page);
}

class AndroidUpdatePlatform implements UpdatePlatform {
  static const channel = MethodChannel('org.mewx.wenku8/app_updates');
  @override
  Future<InstalledApp> installedApp() async {
    final info = await channel.invokeMapMethod<String, dynamic>('info');
    if (info == null) throw const FormatException('无法读取当前版本');
    return InstalledApp(
      version: info['version'] as String,
      build: info['build'] as int,
      abis: (info['abis'] as List).cast<String>(),
    );
  }

  @override
  Future<String> install(File apk, String version) async =>
      await channel.invokeMethod<String>('install', {
        'path': apk.path,
        'version': version,
      }) ??
      'opened';
  @override
  Future<void> allowInstalls() => channel.invokeMethod<void>('allowInstalls');
  @override
  Future<void> openRelease(Uri page) =>
      channel.invokeMethod<void>('openRelease', page.toString());
}

class UpdateCancelled implements Exception {}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class UpdateDownload {
  bool cancelled = false;
  HttpClient? _client;
  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }

  void check() {
    if (cancelled) throw UpdateCancelled();
  }
}

abstract interface class UpdateSource {
  Future<AppRelease?> latest();
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int bytes) progress,
  );
}

class GithubUpdateSource implements UpdateSource {
  GithubUpdateSource({
    this.repository = updateRepository,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;
  final String repository;
  final HttpClient Function() _clientFactory;
  @override
  Future<AppRelease?> latest() async {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const FormatException('更新仓库格式错误');
    }
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      // 试验通道：列出 releases，取最新的 source- 前缀正式版；
      // 与正式通道隔离，互不串包。
      if (trialChannel) return await _latestTrial(client);
      final request = await client.getUrl(
        Uri.https('api.github.com', '/repos/$repository/releases/latest'),
      );
      _setGithubHeaders(request);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) {
        throw HttpException('GitHub ${response.statusCode}');
      }
      final data = await _readBody(response);
      return AppRelease.fromGithub(
        jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
        repository,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 试验通道：取最新的 source- 前缀 Release。
  Future<AppRelease?> _latestTrial(HttpClient client) async {
    final request = await client.getUrl(
      Uri.https('api.github.com', '/repos/$repository/releases', {
        'per_page': '20',
      }),
    );
    _setGithubHeaders(request);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw HttpException('GitHub ${response.statusCode}');
    }
    final data = await _readBody(response);
    final list = jsonDecode(utf8.decode(data));
    if (list is! List) return null;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final tag = item['tag_name'];
      if (tag is! String || !tag.startsWith('source-')) continue;
      final release = AppRelease.fromGithub(item, repository, trial: true);
      if (release != null) return release;
    }
    return null;
  }

  static void _setGithubHeaders(HttpClientRequest request) {
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'Wenku8-Flutter');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
  }

  static Future<List<int>> _readBody(HttpClientResponse response) async {
    final data = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      data.addAll(chunk);
      if (data.length > 1024 * 1024) throw const FormatException('版本说明过大');
    }
    return data;
  }

  @override
  Future<void> download(
    UpdateAsset asset,
    File file,
    UpdateDownload task,
    void Function(int bytes) progress,
  ) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    task._client = client;
    IOSink? sink;
    try {
      var url = asset.url;
      HttpClientResponse? response;
      for (var hop = 0; hop < 6; hop++) {
        task.check();
        if (url.scheme != 'https' ||
            url.userInfo.isNotEmpty ||
            url.port != 443 ||
            !const {
              'github.com',
              'release-assets.githubusercontent.com',
              'objects.githubusercontent.com',
            }.contains(url.host)) {
          throw const FormatException('安装包下载地址无效');
        }
        final request = await client.getUrl(url);
        request.followRedirects = false;
        final candidate = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (const [301, 302, 303, 307, 308].contains(candidate.statusCode)) {
          final location = candidate.headers.value(HttpHeaders.locationHeader);
          if (location == null) throw const FormatException('下载重定向无效');
          url = url.resolve(location);
          await candidate.drain<void>();
          continue;
        }
        response = candidate;
        break;
      }
      if (response == null || response.statusCode != 200) {
        throw const HttpException('安装包下载失败');
      }
      sink = file.openWrite();
      var count = 0;
      final digest = _DigestSink();
      final hashing = asset.digest == null
          ? null
          : sha256.startChunkedConversion(digest);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        task.check();
        count += chunk.length;
        if (count > asset.size) throw const FormatException('安装包大小不匹配');
        hashing?.add(chunk);
        sink.add(chunk);
        progress(count);
      }
      hashing?.close();
      await sink.flush();
      task.check();
      if (count != asset.size ||
          (asset.digest != null && digest.value.toString() != asset.digest)) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
    } finally {
      await sink?.close();
      client.close(force: true);
      task._client = null;
    }
  }
}

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    required this.preferences,
    UpdateSource? source,
    UpdatePlatform? platform,
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
  }) : source = source ?? GithubUpdateSource(),
       platform = platform ?? AndroidUpdatePlatform(),
       _directory = directory ?? getTemporaryDirectory,
       _clock = clock ?? DateTime.now;
  final SharedPreferences preferences;
  final UpdateSource source;
  final UpdatePlatform platform;
  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;
  InstalledApp? installed;
  AppRelease? release;
  String? error;
  File? downloaded;
  bool checking = false,
      downloading = false,
      checked = false,
      installing = false,
      needsPermission = false;
  int bytes = 0;
  bool _disposed = false;
  UpdateDownload? _download;
  Future<InstalledApp>? _loadingInfo;
  DateTime? _lastAttempt;
  bool get autoCheck => preferences.getBool('checkAppUpdates') ?? true;
  bool get available =>
      release != null && installed != null && release!.isNewerThan(installed!);
  UpdateAsset? get asset =>
      installed == null ? null : release?.assetFor(installed!.abis);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> setAutoCheck(bool value) async {
    if (!await preferences.setBool('checkAppUpdates', value)) {
      throw const FileSystemException('设置保存失败');
    }
    _notify();
  }

  Future<void> loadInstalled() async {
    if (_disposed || installed != null) return;
    try {
      final value = await (_loadingInfo ??= platform.installedApp());
      if (!_disposed) {
        installed = value;
        _notify();
      }
    } finally {
      _loadingInfo = null;
    }
  }

  Future<void> check({bool automatic = false}) async {
    if (_disposed || checking || downloading) return;
    final now = _clock();
    final stored = preferences.getInt('lastAppUpdateCheck');
    final last =
        _lastAttempt ??
        (stored == null ? null : DateTime.fromMillisecondsSinceEpoch(stored));
    if (automatic &&
        (!autoCheck ||
            (last != null &&
                now.difference(last) < const Duration(hours: 6)))) {
      return;
    }
    checking = true;
    error = null;
    _lastAttempt = now;
    _notify();
    try {
      await loadInstalled();
      final candidate = await source.latest();
      if (_disposed) return;
      if (candidate?.tag != release?.tag) {
        downloaded = null;
        needsPermission = false;
      }
      release = candidate;
      checked = true;
      await preferences.setInt(
        'lastAppUpdateCheck',
        now.millisecondsSinceEpoch,
      );
    } catch (_) {
      if (!_disposed) error = '无法检查更新，请确认 GitHub 网络连接后重试';
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<void> download() async {
    final selected = asset;
    if (_disposed || downloading || !available || selected == null) return;
    final task = UpdateDownload();
    _download = task;
    downloading = true;
    downloaded = null;
    needsPermission = false;
    error = null;
    bytes = 0;
    _notify();
    File? part;
    try {
      final root = Directory('${(await _directory()).path}/updates');
      await root.create(recursive: true);
      part = File('${root.path}/pending.apk.part');
      final notificationClock = Stopwatch()..start();
      await source.download(selected, part, task, (count) {
        bytes = count;
        if (notificationClock.elapsedMilliseconds >= 100 ||
            count == selected.size) {
          notificationClock.reset();
          _notify();
        }
      });
      task.check();
      final ready = File('${root.path}/update.apk');
      if (await ready.exists()) await ready.delete();
      downloaded = await part.rename(ready.path);
    } catch (failure) {
      if (!task.cancelled && !_disposed) {
        error = failure is FormatException ? failure.message : '下载失败，请检查网络后重试';
      }
    } finally {
      if (part != null && await part.exists()) await part.delete();
      _download = null;
      downloading = false;
      _notify();
    }
  }

  void cancelDownload() => _download?.cancel();
  Future<void> install() async {
    final apk = downloaded;
    if (apk == null || release == null || _disposed || installing) return;
    installing = true;
    _notify();
    try {
      final result = await platform.install(apk, release!.version.name);
      needsPermission = result == 'permission';
      error = null;
    } on PlatformException catch (failure) {
      error = failure.message ?? '无法打开安装程序，请重试';
    } catch (_) {
      error = '无法打开安装程序，请重试';
    } finally {
      installing = false;
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _download?.cancel();
    super.dispose();
  }
}
