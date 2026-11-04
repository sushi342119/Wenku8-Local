part of 'cloud_sources.dart';

/// S3 encodes UTF-8 bytes rather than form data; spaces are %20, never '+'.
String s3Encode(String value) {
  final out = StringBuffer();
  for (final b in utf8.encode(value)) {
    if ((b >= 65 && b <= 90) ||
        (b >= 97 && b <= 122) ||
        (b >= 48 && b <= 57) ||
        b == 45 ||
        b == 46 ||
        b == 95 ||
        b == 126) {
      out.writeCharCode(b);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

Map<String, String> s3SignedHeaders(
  CloudSourceConfig config,
  Uri uri, {
  String method = 'GET',
  DateTime? now,
  Map<String, String> extra = const {},
  String? payloadHash,
}) {
  final utc = (now ?? DateTime.now()).toUtc();
  String two(int v) => '$v'.padLeft(2, '0');
  final day = '${utc.year}${two(utc.month)}${two(utc.day)}';
  final stamp = '${day}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  final payload = payloadHash ?? sha256.convert(const <int>[]).toString();
  final headers = <String, String>{
    'host': uri.authority,
    'x-amz-date': stamp,
    'x-amz-content-sha256': payload,
    if (config.sessionToken.isNotEmpty)
      'x-amz-security-token': config.sessionToken,
    for (final entry in extra.entries)
      entry.key.toLowerCase(): entry.value.trim().replaceAll(
        RegExp(r'\s+'),
        ' ',
      ),
  };
  final names = headers.keys.toList()..sort();
  final query =
      <(String, String)>[
        for (final entry in uri.queryParametersAll.entries)
          for (final value in entry.value)
            (s3Encode(entry.key), s3Encode(value)),
      ]..sort((a, b) {
        final key = a.$1.compareTo(b.$1);
        return key != 0 ? key : a.$2.compareTo(b.$2);
      });
  final canonical = [
    method,
    '/${uri.pathSegments.map(s3Encode).join('/')}',
    query.map((entry) => '${entry.$1}=${entry.$2}').join('&'),
    '${names.map((name) => '$name:${headers[name]}').join('\n')}\n',
    names.join(';'),
    payload,
  ].join('\n');
  final scope = '$day/${config.region}/s3/aws4_request';
  final message =
      'AWS4-HMAC-SHA256\n$stamp\n$scope\n${sha256.convert(utf8.encode(canonical))}';
  List<int> hmac(List<int> key, String value) =>
      Hmac(sha256, key).convert(utf8.encode(value)).bytes;
  var key = hmac(utf8.encode('AWS4${config.password}'), day);
  for (final value in [config.region, 's3', 'aws4_request']) {
    key = hmac(key, value);
  }
  return {
    ...headers,
    'Authorization':
        'AWS4-HMAC-SHA256 Credential=${config.username}/$scope, '
        'SignedHeaders=${names.join(';')}, Signature=${Hmac(sha256, key).convert(utf8.encode(message))}',
  };
}

class S3SyncConnection {
  const S3SyncConnection({
    required this.config,
    this.path = 'wenku8/library.wenku8sync',
  });
  final CloudSourceConfig config;

  /// Relative to the configured prefix, never to the bucket root.
  final String path;
  String get objectKey => '${_s3Root(config)}$path';

  void validate() {
    config.validate();
    if (config.kind != CloudSourceKind.s3 ||
        path.isEmpty ||
        path.startsWith('/') ||
        !path.endsWith('.wenku8sync') ||
        objectKey.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
        RegExp(r'[\\\x00-\x1f]').hasMatch(objectKey) ||
        utf8.encode(objectKey).length > 1024) {
      throw const CloudSourceFailure(
        '请填写目录内的 .wenku8sync 文件路径，例如 wenku8/library.wenku8sync',
      );
    }
  }

  Map<String, Object> toRecord() => {
    ...config.toRecord(),
    'purpose': 'book-sync',
    'objectPath': path,
  };
  factory S3SyncConnection.fromRecord(Map<String, dynamic> value) {
    final connection = S3SyncConnection(
      config: CloudSourceConfig.fromRecord(value),
      path: value['objectPath'] as String,
    );
    connection.validate();
    return connection;
  }
}

String _s3Root(CloudSourceConfig config) => config.prefix.isEmpty
    ? ''
    : config.prefix.endsWith('/')
    ? config.prefix
    : '${config.prefix}/';

Uri _s3Uri(CloudSourceConfig config, String key, [Map<String, String>? query]) {
  final endpoint = config.endpoint;
  final base = endpoint.pathSegments.toList();
  if (base.isNotEmpty && base.last.isEmpty) base.removeLast();
  final authority = endpoint
      .replace(
        host: config.pathStyle
            ? endpoint.host
            : '${config.bucket}.${endpoint.host}',
      )
      .authority;
  final path = [
    ...base,
    if (config.pathStyle) config.bucket,
    ...key.split('/'),
  ].map(s3Encode).join('/');
  final params = query == null
      ? null
      : (query.entries
            .map((e) => '${s3Encode(e.key)}=${s3Encode(e.value)}')
            .toList()
          ..sort());
  return Uri.parse(
    '${endpoint.scheme}://$authority/$path${params == null ? '' : '?${params.join('&')}'}',
  );
}

/// The ETag is an opaque concurrency token, not a content checksum.
class S3ObjectRevision {
  const S3ObjectRevision.absent() : etag = null;
  const S3ObjectRevision.existing(String value) : etag = value;
  final String? etag;
}

class S3SyncObjectClient {
  S3SyncObjectClient(this.connection, {CloudHttp? http})
    : http = http ?? CloudHttp() {
    connection.validate();
  }
  static const maxBytes = 256 * 1024 * 1024;
  final S3SyncConnection connection;
  final CloudHttp http;
  CloudSourceConfig get _config => connection.config;
  Uri get _uri => _s3Uri(_config, connection.objectKey);
  static const _redirect = 'S3 地址发生跳转，请检查 Endpoint 和 Region；连接不会向跳转地址发送密钥';

  Future<S3ObjectRevision> read(File target) async {
    final response = await http.request(
      'GET',
      _uri,
      headers: (uri) => s3SignedHeaders(_config, uri),
      allowHttp: _config.allowHttp,
      redirectMessage: _redirect,
      allowedStatuses: const {404},
      authenticationMessage:
          '无法读取同步文件，请检查 S3 凭据和 GetObject 权限；首次同步还需允许检查该路径是否存在',
    );
    if (response.statusCode == 404) {
      await response.listen((_) {}).cancel();
      await target.writeAsBytes(const [], flush: true);
      return const S3ObjectRevision.absent();
    }
    final etag = response.headers.value(HttpHeaders.etagHeader);
    if (etag == null || etag.isEmpty || etag.startsWith('W/')) {
      await response.listen((_) {}).cancel();
      throw const CloudSourceFailure('该 S3 服务未返回可用的 ETag，无法安全合并同步文件');
    }
    await http.save(
      response,
      target,
      limitBytes: maxBytes,
      limitMessage: '同步文件超过 256 MiB，未读取或覆盖云端',
    );
    return S3ObjectRevision.existing(etag);
  }

  Future<void> write(File source, S3ObjectRevision expected) async {
    final size = await source.length();
    if (size <= 0 || size > maxBytes) {
      throw const CloudSourceFailure('同步文件为空或超过 256 MiB，未写入云端');
    }
    // Required by SigV4. Stream the file so signing/upload does not allocate a
    // second full-size book bundle on the UI isolate.
    final payload = (await sha256.bind(source.openRead()).first).toString();
    try {
      final response = await http.request(
        'PUT',
        _uri,
        headers: (uri) => s3SignedHeaders(
          _config,
          uri,
          method: 'PUT',
          payloadHash: payload,
          extra: {
            'content-type': 'application/octet-stream',
            if (expected.etag case final etag?)
              'if-match': etag
            else
              'if-none-match': '*',
          },
        ),
        bodyFile: source,
        allowHttp: _config.allowHttp,
        redirectMessage: _redirect,
        allowedStatuses: const {409, 412},
        authenticationMessage:
            'S3 同步需要此文件的 GetObject 和 PutObject 权限，请检查连接凭据与存储桶策略',
      );
      await response.listen((_) {}).cancel();
      if (response.statusCode == 409 || response.statusCode == 412) {
        throw const CloudSourceFailure('另一台设备更新了云端，未覆盖它的内容。请再次同步，读取最新记录后合并');
      }
    } on TimeoutException {
      throw const CloudSourceFailure('上传结果尚未确认，本机同步副本已保留。请检查网络后再次同步，将先重新读取云端');
    } on SocketException {
      throw const CloudSourceFailure('上传连接中断，结果尚未确认。本机同步副本已保留，再次同步会先重新读取云端');
    } on HttpException {
      throw const CloudSourceFailure('上传响应不完整，结果尚未确认。本机同步副本已保留，再次同步会先重新读取云端');
    }
  }

  void close() => http.close();
}

class S3BookClient implements CloudBookClient {
  S3BookClient(this.config, {CloudHttp? http}) : http = http ?? CloudHttp() {
    config.validate();
  }
  final CloudSourceConfig config;
  final CloudHttp http;
  final _tokens = <(String, int), String>{};
  @override
  String get root => _s3Root(config);
  Uri _uri(String key, [Map<String, String>? query]) {
    if (query == null && !key.startsWith(root)) {
      throw const CloudSourceFailure('文件不在已配置的 S3 目录内');
    }
    return _s3Uri(config, key, query);
  }

  Map<String, String> _headers(Uri uri) => s3SignedHeaders(config, uri);
  @override
  Future<CloudBookListing> list(String folder, {int page = 1}) async {
    if (!folder.startsWith(root) ||
        (folder.isNotEmpty && !folder.endsWith('/')) ||
        page < 1) {
      throw const CloudSourceFailure('S3 目录无效，请返回上级后重试');
    }
    if (page == 1) _tokens.removeWhere((key, _) => key.$1 == folder);
    final token = _tokens[(folder, page)];
    if (page > 1 && token == null) {
      throw const CloudSourceFailure('目录页已失效，请刷新目录');
    }
    final uri = _uri('', {
      'list-type': '2',
      'delimiter': '/',
      'encoding-type': 'url',
      'max-keys': '1000',
      'prefix': folder,
      'continuation-token': ?token,
    });
    final response = await http.request(
      'GET',
      uri,
      headers: _headers,
      allowHttp: config.allowHttp,
      redirectMessage: 'S3 地址发生跳转，请检查 Endpoint 和 Region；连接不会向跳转地址发送密钥',
    );
    final document = XmlDocument.parse(utf8.decode(await http.bytes(response)));
    final node = document.rootElement;
    if (node.name.local != 'ListBucketResult') {
      throw const CloudSourceFailure('该地址未返回 S3 目录，请检查 Endpoint 和桶名');
    }
    String value(XmlElement parent, String name) =>
        parent.childElements
            .where((e) => e.name.local == name)
            .firstOrNull
            ?.innerText ??
        '';
    final encoded = value(node, 'EncodingType') == 'url';
    String keyValue(XmlElement parent, String name) {
      final text = value(parent, name);
      return encoded ? Uri.decodeComponent(text) : text;
    }

    final entries = <String, CloudBookEntry>{};
    for (final child in node.childElements) {
      final directory = child.name.local == 'CommonPrefixes';
      if (!directory && child.name.local != 'Contents') continue;
      final key = keyValue(child, directory ? 'Prefix' : 'Key');
      if (!key.startsWith(folder) || key == folder || !key.startsWith(root)) {
        continue;
      }
      final relative = key.substring(folder.length);
      final name = directory && relative.endsWith('/')
          ? relative.substring(0, relative.length - 1)
          : relative;
      if (name.isEmpty ||
          name.contains('/') ||
          !directory && key.endsWith('/')) {
        continue;
      }
      final entry = CloudBookEntry(
        id: key,
        name: name,
        folder: directory,
        size: int.tryParse(value(child, 'Size')) ?? 0,
      );
      if (directory || entry.isBook) entries[key] = entry;
    }
    final more = value(node, 'IsTruncated') == 'true';
    if (more) {
      final next = value(node, 'NextContinuationToken');
      if (next.isEmpty) throw const CloudSourceFailure('S3 目录分页信息缺失，请刷新重试');
      _tokens[(folder, page + 1)] = next;
    }
    final result = entries.values.toList()
      ..sort(
        (a, b) => a.folder != b.folder
            ? (a.folder ? -1 : 1)
            : a.name.compareTo(b.name),
      );
    return CloudBookListing(result, nextPage: more ? page + 1 : null);
  }

  @override
  Future<void> download(
    CloudBookEntry entry,
    File target, {
    void Function(int, int?)? onProgress,
  }) async {
    if (!entry.isBook) throw const CloudSourceFailure('请选择支持的电子书或文档');
    final response = await http.request(
      'GET',
      _uri(entry.id),
      headers: _headers,
      allowHttp: config.allowHttp,
      redirectMessage: 'S3 地址发生跳转，请检查 Endpoint 和 Region；连接不会向跳转地址发送密钥',
    );
    await http.save(
      response,
      target,
      bookName: entry.name,
      onProgress: onProgress,
    );
  }

  @override
  void cancel() => http.close();
  @override
  void close() => http.close();
}
