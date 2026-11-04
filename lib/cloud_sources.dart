import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'book_import_limits.dart';
part 'cloud_s3.dart';

enum CloudSourceKind {
  webdav('OpenList / WebDAV'),
  quark('夸克网盘'),
  s3('S3 / 兼容对象存储');

  const CloudSourceKind(this.label);
  final String label;
}

/// Only this device's encrypted vault contains connection secrets. This record
/// is deliberately separate from SharedPreferences and LibraryBackup.
class CloudSourceConfig {
  const CloudSourceConfig({
    required this.kind,
    this.address = '',
    this.username = '',
    this.password = '',
    this.cookie = '',
    this.allowHttp = false,
    this.bucket = '',
    this.region = 'us-east-1',
    this.prefix = '',
    this.sessionToken = '',
    this.pathStyle = true,
  });
  final CloudSourceKind kind;
  final String address, username, password, cookie;
  final bool allowHttp;
  final String bucket, region, prefix, sessionToken;
  final bool pathStyle;
  String get label => kind.label;
  Uri get endpoint {
    final uri = Uri.parse(address.trim());
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  void validate() {
    if (kind == CloudSourceKind.webdav || kind == CloudSourceKind.s3) {
      final uri = Uri.tryParse(address.trim());
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.scheme != 'https' && !(uri.scheme == 'http' && allowHttp)) ||
          address.length > 2048) {
        throw CloudSourceFailure(
          kind == CloudSourceKind.s3
              ? '请填写完整的 HTTPS S3 Endpoint，不要包含桶名、查询参数或登录信息'
              : '请填写完整的 HTTPS WebDAV 地址，例如 https://你的域名/dav/',
        );
      }
      if (kind == CloudSourceKind.s3 &&
          (!RegExp(r'^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$').hasMatch(bucket) ||
              !RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(region) ||
              username.trim().isEmpty ||
              password.isEmpty ||
              RegExp(r'[\r\n\x00]').hasMatch(sessionToken + prefix) ||
              sessionToken.length > 16384 ||
              prefix.length > 1024)) {
        throw const CloudSourceFailure(
          '请检查存储桶、区域、Access Key ID 和 Secret Access Key',
        );
      }
      if (username.contains(':') ||
          RegExp(r'[\r\n\x00]').hasMatch(username + password) ||
          password.length > 8192) {
        throw CloudSourceFailure(
          kind == CloudSourceKind.s3
              ? '请检查 Access Key ID 和 Secret Access Key'
              : '请检查 WebDAV 用户名和密码',
        );
      }
    } else if (cookie.trim().isEmpty ||
        cookie.length > 16384 ||
        RegExp(r'[\r\n\x00]').hasMatch(cookie) ||
        !RegExp(r'(?:^|;\s*)__puus=[^;]+').hasMatch(cookie)) {
      throw const CloudSourceFailure('请粘贴本人夸克网页的完整 Cookie，需要包含 __puus');
    }
  }

  Map<String, Object> toRecord() => {
    'kind': kind.name,
    'address': address.trim(),
    'username': username,
    'password': password,
    'cookie': cookie,
    'allowHttp': allowHttp,
    if (kind == CloudSourceKind.s3) ...{
      'bucket': bucket,
      'region': region,
      'prefix': prefix,
      'sessionToken': sessionToken,
      'pathStyle': pathStyle,
    },
  };
  factory CloudSourceConfig.fromRecord(Map<String, dynamic> record) {
    final value = CloudSourceConfig(
      kind: CloudSourceKind.values.byName(record['kind']),
      address: record['address'] ?? '',
      username: record['username'] ?? '',
      password: record['password'] ?? '',
      cookie: record['cookie'] ?? '',
      allowHttp: record['allowHttp'] == true,
      bucket: record['bucket'] ?? '',
      region: record['region'] ?? 'us-east-1',
      prefix: record['prefix'] ?? '',
      sessionToken: record['sessionToken'] ?? '',
      pathStyle: record['pathStyle'] != false,
    );
    value.validate();
    return value;
  }
  CloudSourceConfig withCookie(String value) =>
      CloudSourceConfig(kind: kind, cookie: value);
}

abstract interface class CloudConfigStorage {
  Future<String?> read();
  Future<void> write(String? value);
}

class AndroidCloudConfigStorage implements CloudConfigStorage {
  static const channel = MethodChannel('org.mewx.wenku8/cloud_sources');
  static const _fallbackKey = 'cloud_sources_fallback_v1';
  @override
  Future<String?> read() async {
    try {
      return await channel.invokeMethod<String>('read');
    } on MissingPluginException {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_fallbackKey);
    }
  }

  @override
  Future<void> write(String? value) async {
    try {
      await channel.invokeMethod<void>('write', value);
    } on MissingPluginException {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_fallbackKey);
      } else {
        await prefs.setString(_fallbackKey, value);
      }
    }
  }
}

class CloudSourceSettings extends ChangeNotifier {
  CloudSourceSettings({CloudConfigStorage? storage})
    : storage = storage ?? AndroidCloudConfigStorage();
  final CloudConfigStorage storage;
  final Map<CloudSourceKind, CloudSourceConfig> _configs = {};
  S3SyncConnection? _s3Sync;
  S3SyncConnection? get s3Sync => _s3Sync;
  Future<void> _writes = Future.value();
  bool _disposed = false;
  String? error;
  CloudSourceConfig? operator [](CloudSourceKind kind) => _configs[kind];
  Future<void> load() async {
    try {
      final text = await storage.read();
      final values = text == null ? <dynamic>[] : jsonDecode(text);
      if (values is! List ||
          values.length > CloudSourceKind.values.length + 1) {
        throw const FormatException();
      }
      final loaded = <CloudSourceKind, CloudSourceConfig>{};
      S3SyncConnection? sync;
      for (final value in values) {
        if (value is Map && value['purpose'] == 'book-sync') {
          if (sync != null) throw const FormatException();
          sync = S3SyncConnection.fromRecord(Map<String, dynamic>.from(value));
          continue;
        }
        final config = CloudSourceConfig.fromRecord(
          Map<String, dynamic>.from(value),
        );
        loaded[config.kind] = config;
      }
      _configs
        ..clear()
        ..addAll(loaded);
      _s3Sync = sync;
      error = null;
    } catch (_) {
      error = '无法读取本机网盘连接，请重新保存连接';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> save(CloudSourceKind kind, CloudSourceConfig? value) =>
      _save(kind, value);
  Future<void> _save(
    CloudSourceKind kind,
    CloudSourceConfig? value, {
    String? expectedCookie,
  }) {
    value?.validate();
    final work = _writes.catchError((Object _) {}).then((_) async {
      if (expectedCookie != null && _configs[kind]?.cookie != expectedCookie) {
        return;
      }
      final next = {..._configs};
      if (value == null) {
        next.remove(kind);
      } else {
        next[kind] = value;
      }
      await _writeRecords(next, _s3Sync);
      _configs
        ..clear()
        ..addAll(next);
      error = null;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    return work;
  }

  Future<void> _writeRecords(
    Map<CloudSourceKind, CloudSourceConfig> configs,
    S3SyncConnection? sync,
  ) => storage.write(
    configs.isEmpty && sync == null
        ? null
        : jsonEncode([
            ...configs.values.map((c) => c.toRecord()),
            if (sync != null) sync.toRecord(),
          ]),
  );

  /// Sync is a separate, explicitly saved connection. Editing or removing an
  /// import source never silently changes the destination receiving books.
  Future<void> saveS3Sync(S3SyncConnection? value) {
    value?.validate();
    final work = _writes.catchError((Object _) {}).then((_) async {
      await _writeRecords(_configs, value);
      _s3Sync = value;
      error = null;
      if (!_disposed) notifyListeners();
    });
    _writes = work;
    return work;
  }

  /// A late response from an old client must not restore a removed account.
  Future<void> rotate(CloudSourceConfig previous, String cookie) => _save(
    previous.kind,
    previous.withCookie(cookie),
    expectedCookie: previous.cookie,
  );

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class CloudSourceFailure implements Exception {
  const CloudSourceFailure(this.message, {this.authentication = false});
  final String message;
  final bool authentication;
  @override
  String toString() => message;
}

class CloudTransferCancelled implements Exception {
  const CloudTransferCancelled();
}

String cloudFailureMessage(Object failure) => switch (failure) {
  CloudSourceFailure e => e.message,
  CloudTransferCancelled _ => '已取消，已导入的书籍仍保留',
  TimeoutException _ => '连接超时，请检查网络后重试',
  HandshakeException _ => '证书验证失败，请检查服务端 HTTPS 配置',
  SocketException _ => '无法连接网盘，请检查地址和网络',
  FormatException e => e.message.isEmpty ? '网盘返回的数据格式有误' : e.message,
  PlatformException e
      when e.code == 'document' || e.code == 'picker' || e.code == 'busy' =>
    e.message ?? '文件操作失败，请重新选择原书',
  FileSystemException e =>
    e.osError?.errorCode == 28 ? '存储空间不足，请清理空间后重新导入' : '无法读取或保存原书，请检查文件与存储空间',
  _ => '操作未完成，请重试；本地书籍已保留',
};

class CloudBookEntry {
  const CloudBookEntry({
    required this.id,
    required this.name,
    required this.folder,
    this.size = 0,
  });
  final String id, name;
  final bool folder;
  final int size;
  bool get isBook => !folder && supportsBookImport(name);
}

class CloudBookListing {
  const CloudBookListing(this.entries, {this.nextPage});
  final List<CloudBookEntry> entries;
  final int? nextPage;
}

abstract class CloudBookClient {
  factory CloudBookClient(
    CloudSourceConfig config, {
    CloudSourceSettings? settings,
  }) => switch (config.kind) {
    CloudSourceKind.webdav => WebDavBookClient(config),
    CloudSourceKind.quark => QuarkBookClient(config, settings: settings),
    CloudSourceKind.s3 => S3BookClient(config),
  };
  String get root;
  Future<CloudBookListing> list(String folder, {int page = 1});
  Future<void> download(
    CloudBookEntry entry,
    File target, {
    void Function(int received, int? total)? onProgress,
  });
  void cancel();
  void close();
}

/// A bounded, cancellable request. Redirects are followed explicitly so DAV
/// Basic authentication and Quark sessions never leak to unrelated origins.
class CloudHttp {
  CloudHttp({HttpClient Function()? clientFactory})
    : _factory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _factory;
  HttpClient? _client;
  bool _closed = false;
  static const maxBookBytes = maxLocalEpubBytes;
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
  static void validateUrl(Uri uri, {bool allowHttp = false}) {
    if ((uri.scheme != 'https' && !(allowHttp && uri.scheme == 'http')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const CloudSourceFailure('网盘返回了不安全的文件地址');
    }
  }

  Future<HttpClientResponse> request(
    String method,
    Uri uri, {
    required Map<String, String> Function(Uri) headers,
    List<int>? body,
    File? bodyFile,
    bool redirects = false,
    bool allowHttp = false,
    String? redirectMessage,
    Set<int> allowedStatuses = const {},
    String? authenticationMessage,
  }) async {
    if (_closed) throw const CloudTransferCancelled();
    validateUrl(uri, allowHttp: allowHttp);
    _client ??= _factory()..connectionTimeout = const Duration(seconds: 20);
    final client = _client!;
    try {
      for (var hop = 0; hop < 6; hop++) {
        final req = await client
            .openUrl(method, uri)
            .timeout(const Duration(seconds: 20));
        req.followRedirects = false;
        headers(uri).forEach(req.headers.set);
        if (bodyFile != null) {
          req.contentLength = await bodyFile.length();
          await req
              .addStream(bodyFile.openRead())
              .timeout(const Duration(minutes: 10));
        } else if (body != null) {
          req.add(body);
        }
        final res = await req.close().timeout(const Duration(seconds: 25));
        if ({301, 302, 303, 307, 308}.contains(res.statusCode)) {
          final location = res.headers.value(HttpHeaders.locationHeader);
          await res.listen((_) {}).cancel();
          if (!redirects || location == null) {
            throw CloudSourceFailure(
              redirectMessage ?? '网盘地址发生跳转，请填写最终 WebDAV 地址或启用 OpenList 代理',
            );
          }
          final next = uri.resolve(location);
          // HTTPS may never be downgraded, even when a LAN HTTP endpoint was allowed.
          validateUrl(next, allowHttp: allowHttp && uri.scheme == 'http');
          uri = next;
          continue;
        }
        if ((res.statusCode < 200 || res.statusCode >= 300) &&
            !allowedStatuses.contains(res.statusCode)) {
          await res.listen((_) {}).cancel();
          if (res.statusCode == 401 || res.statusCode == 403) {
            throw CloudSourceFailure(
              authenticationMessage ?? '连接凭据已失效或没有读取权限，请重新配置连接',
              authentication: true,
            );
          }
          if (res.statusCode == 404) {
            throw const CloudSourceFailure('文件或目录不存在，请刷新后重试');
          }
          if (res.statusCode == 429) {
            throw const CloudSourceFailure('请求过于频繁，请稍后重试');
          }
          throw CloudSourceFailure('网盘请求失败（HTTP ${res.statusCode}）');
        }
        return res;
      }
      throw const CloudSourceFailure('文件跳转次数过多，请检查服务端代理设置');
    } catch (_) {
      if (_closed) throw const CloudTransferCancelled();
      rethrow;
    }
  }

  Future<Uint8List> bytes(
    HttpClientResponse res, {
    int limit = 4 * 1024 * 1024,
  }) async {
    if (res.contentLength > limit) {
      await res.listen((_) {}).cancel();
      throw const CloudSourceFailure('网盘返回的数据过大');
    }
    final result = BytesBuilder(copy: false);
    try {
      await for (final part in res.timeout(const Duration(seconds: 25))) {
        if (_closed) throw const CloudTransferCancelled();
        if (result.length + part.length > limit) {
          throw const CloudSourceFailure('网盘返回的数据过大');
        }
        result.add(part);
      }
    } catch (_) {
      if (_closed) throw const CloudTransferCancelled();
      rethrow;
    }
    return result.takeBytes();
  }

  Future<void> save(
    HttpClientResponse res,
    File target, {
    String? bookName,
    int? limitBytes,
    String? limitMessage,
    void Function(int, int?)? onProgress,
  }) async {
    final importingHtml =
        bookName != null &&
        RegExp(r'\.(html?|xhtml)$', caseSensitive: false).hasMatch(bookName);
    if (!importingHtml &&
        (res.headers.contentType?.mimeType == 'text/html' ||
            res.headers.contentType?.mimeType == 'application/xhtml+xml')) {
      await res.listen((_) {}).cancel();
      throw const CloudSourceFailure('网盘返回了登录网页，请更新连接或开启 OpenList 下载代理');
    }
    final total = res.contentLength < 0 ? null : res.contentLength;
    final limit =
        limitBytes ??
        (bookName == null ? maxBookBytes : localBookByteLimit(bookName));
    final sizeMessage =
        limitMessage ??
        (bookName == null
            ? '单本书籍不能超过 256 MiB'
            : localBookSizeMessage(bookName));
    if ((total ?? 0) > limit) {
      await res.listen((_) {}).cancel();
      throw CloudSourceFailure(sizeMessage);
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final part in res.timeout(const Duration(seconds: 25))) {
        if (_closed) throw const CloudTransferCancelled();
        received += part.length;
        if (received > limit) {
          throw CloudSourceFailure(sizeMessage);
        }
        sink.add(part);
        await sink.flush();
        onProgress?.call(received, total);
      }
      if (received == 0 || (total != null && received != total)) {
        throw const CloudSourceFailure('书籍下载不完整，请重试');
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      if (_closed) throw const CloudTransferCancelled();
      rethrow;
    }
  }

  void close() {
    _closed = true;
    _client?.close(force: true);
  }
}

class WebDavBookClient implements CloudBookClient {
  WebDavBookClient(this.config, {CloudHttp? http})
    : http = http ?? CloudHttp() {
    config.validate();
  }
  final CloudSourceConfig config;
  final CloudHttp http;
  @override
  String get root => config.endpoint.toString();
  Uri _resource(String id) {
    final uri = Uri.parse(id).normalizePath(),
        base = config.endpoint.normalizePath();
    final segments = uri.pathSegments,
        prefix = base.pathSegments.where((e) => e.isNotEmpty).toList();
    if (!CloudHttp.sameOrigin(uri, base) ||
        uri.hasQuery ||
        uri.hasFragment ||
        segments.any(
          (s) => s == '..' || s == '.' || s.contains('/') || s.contains('\\'),
        ) ||
        segments.length < prefix.length ||
        !listEquals(segments.take(prefix.length).toList(), prefix)) {
      throw const CloudSourceFailure('文件地址不在已配置的 WebDAV 目录内');
    }
    return uri;
  }

  Map<String, String> _headers(Uri uri) => {
    'User-Agent': 'Wenku8/0.3 WebDAV',
    if (CloudHttp.sameOrigin(uri, config.endpoint) &&
        (config.username.isNotEmpty || config.password.isNotEmpty))
      'Authorization':
          'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
  };
  @override
  Future<CloudBookListing> list(String folder, {int page = 1}) async {
    final uri = _resource(folder);
    final res = await http.request(
      'PROPFIND',
      uri,
      allowHttp: config.allowHttp,
      headers: (u) => {
        ..._headers(u),
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: utf8.encode(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>',
      ),
    );
    final document = XmlDocument.parse(utf8.decode(await http.bytes(res)));
    if (document.rootElement.name.local != 'multistatus') {
      throw const CloudSourceFailure('该地址不是 WebDAV 服务，请检查 /dav/ 路径');
    }
    final entries = <CloudBookEntry>[];
    final seen = <String>{};
    for (final node in document.rootElement.childElements.where(
      (e) => e.name.local == 'response',
    )) {
      final href = node.childElements
          .where((e) => e.name.local == 'href')
          .firstOrNull
          ?.innerText;
      if (href == null) continue;
      Uri candidate;
      try {
        candidate = _resource(uri.resolve(href).toString());
      } on CloudSourceFailure {
        continue;
      }
      final parent = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final parts = candidate.pathSegments.where((s) => s.isNotEmpty).toList();
      if (parts.length != parent.length + 1 ||
          !listEquals(parent, parts.take(parent.length).toList()) ||
          !seen.add(candidate.toString())) {
        continue;
      }
      XmlElement? props;
      for (final stat in node.childElements.where(
        (e) => e.name.local == 'propstat',
      )) {
        if (stat.childElements.any(
          (e) =>
              e.name.local == 'status' &&
              RegExp(r'\s200\s').hasMatch(e.innerText),
        )) {
          props = stat.childElements
              .where((e) => e.name.local == 'prop')
              .firstOrNull;
          break;
        }
      }
      if (props == null) continue;
      String? prop(String name) => props!.childElements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText;
      final directory = props.descendants.whereType<XmlElement>().any(
        (e) => e.name.local == 'collection',
      );
      final entry = CloudBookEntry(
        id: candidate.toString(),
        name: prop('displayname')?.trim().isNotEmpty == true
            ? prop('displayname')!
            : parts.last,
        folder: directory,
        size: int.tryParse(prop('getcontentlength') ?? '') ?? 0,
      );
      if (entry.folder || entry.isBook) entries.add(entry);
    }
    entries.sort(
      (a, b) =>
          a.folder != b.folder ? (a.folder ? -1 : 1) : a.name.compareTo(b.name),
    );
    return CloudBookListing(entries);
  }

  @override
  Future<void> download(
    CloudBookEntry entry,
    File target, {
    void Function(int, int?)? onProgress,
  }) async {
    if (!entry.isBook) {
      throw const CloudSourceFailure('请选择支持的电子书或文档');
    }
    final res = await http.request(
      'GET',
      _resource(entry.id),
      headers: _headers,
      redirects: true,
      allowHttp: config.allowHttp,
    );
    await http.save(res, target, bookName: entry.name, onProgress: onProgress);
  }

  @override
  void cancel() => http.close();
  @override
  void close() => http.close();
}

/// An independently implemented read-only client of the web wire protocol
/// documented by OpenList. No upstream Go driver is bundled or translated.
class QuarkBookClient implements CloudBookClient {
  QuarkBookClient(this.config, {this.settings, CloudHttp? http, Uri? api})
    : http = http ?? CloudHttp(),
      api = api ?? Uri.parse('https://drive.quark.cn/1/clouddrive') {
    config.validate();
  }
  CloudSourceConfig config;
  final CloudSourceSettings? settings;
  final CloudHttp http;
  final Uri api;
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  @override
  String get root => '0';
  Map<String, String> _headers(Uri uri) => {
    'User-Agent': userAgent,
    'Referer': 'https://pan.quark.cn/',
    if (CloudHttp.sameOrigin(uri, api) ||
        (uri.scheme == 'https' &&
            (uri.host == 'quark.cn' || uri.host.endsWith('.quark.cn'))))
      'Cookie': config.cookie,
  };
  Future<Map<String, dynamic>> _call(
    String path, {
    Map<String, String> query = const {},
    Object? body,
  }) async {
    final uri = api.replace(
      path: '${api.path}$path',
      queryParameters: {'pr': 'ucpro', 'fr': 'pc', ...query},
    );
    final res = await http.request(
      body == null ? 'GET' : 'POST',
      uri,
      headers: (u) => {
        ..._headers(u),
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json',
      },
      body: body == null ? null : utf8.encode(jsonEncode(body)),
      allowHttp: api.scheme == 'http',
    );
    final bytes = await http.bytes(res);
    var cookie = config.cookie;
    for (final value in res.cookies.where(
      (c) => c.name == '__puus' || c.name == '__pus',
    )) {
      final pattern = RegExp('(^|;\\s*)${value.name}=[^;]*');
      cookie = cookie.contains(pattern)
          ? cookie.replaceFirstMapped(
              pattern,
              (m) => '${m[1]}${value.name}=${value.value}',
            )
          : '$cookie; ${value.name}=${value.value}';
    }
    if (cookie != config.cookie) {
      await settings?.rotate(config, cookie);
      config = config.withCookie(cookie);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) {
      throw const CloudSourceFailure('夸克返回的数据格式有误');
    }
    if (data['code'] != 0 || (data['status'] is num && data['status'] >= 400)) {
      if (data['status'] == 401 ||
          data['status'] == 403 ||
          data['code'] == 401) {
        throw const CloudSourceFailure(
          '夸克登录已失效，请更新 Cookie',
          authentication: true,
        );
      }
      throw const CloudSourceFailure('夸克暂时无法完成请求，请稍后重试或更新 Cookie');
    }
    return data;
  }

  @override
  Future<CloudBookListing> list(String folder, {int page = 1}) async {
    final data = await _call(
      '/file/sort',
      query: {
        'pdir_fid': folder,
        '_size': '100',
        '_page': '$page',
        '_fetch_total': '1',
        'fetch_all_file': '1',
        'fetch_risk_file_name': '1',
        '_sort': 'file_type:asc,file_name:asc',
      },
    );
    final rows = data['data']?['list'];
    if (rows is! List) throw const CloudSourceFailure('夸克目录数据有误');
    final entries = <CloudBookEntry>[];
    for (final row in rows) {
      if (row is! Map ||
          row['fid'] is! String ||
          row['file_name'] is! String ||
          row['file'] is! bool) {
        continue;
      }
      final entry = CloudBookEntry(
        id: row['fid'],
        name: row['file_name'],
        folder: row['file'] != true,
        size: row['size'] is int ? row['size'] : 0,
      );
      if (entry.folder || entry.isBook) entries.add(entry);
    }
    final total = data['metadata']?['_total'];
    return CloudBookListing(
      entries,
      nextPage: (total is num ? page * 100 < total : rows.length == 100)
          ? page + 1
          : null,
    );
  }

  @override
  Future<void> download(
    CloudBookEntry entry,
    File target, {
    void Function(int, int?)? onProgress,
  }) async {
    if (!entry.isBook) {
      throw const CloudSourceFailure('请选择支持的电子书或文档');
    }
    final value = await _call(
      '/file/download',
      body: {
        'fids': [entry.id],
      },
    );
    final rows = value['data'];
    if (rows is! List ||
        rows.isEmpty ||
        rows.first is! Map ||
        rows.first['download_url'] is! String) {
      throw const CloudSourceFailure('夸克没有返回可用的下载地址');
    }
    final uri = Uri.parse(rows.first['download_url']);
    CloudHttp.validateUrl(uri);
    final res = await http.request(
      'GET',
      uri,
      headers: _headers,
      redirects: true,
    );
    await http.save(res, target, bookName: entry.name, onProgress: onProgress);
  }

  @override
  void cancel() => http.close();
  @override
  void close() => http.close();
}
