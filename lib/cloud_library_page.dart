import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'app_ui.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'cloud_sources.dart';
import 'offline_cache.dart' show formatCacheBytes;

typedef ImportCloudBook = Future<Novel> Function(String name, String path);
typedef ImportCloudBatch =
    Future<({int imported, int failed})> Function(String name, String path);

class CloudLibraryPage extends StatelessWidget {
  const CloudLibraryPage({
    super.key,
    required this.settings,
    required this.onImport,
    this.onImportBatch,
    this.reduceMotion = false,
  });
  final CloudSourceSettings settings;
  final ImportCloudBook onImport;
  final ImportCloudBatch? onImportBatch;
  final bool reduceMotion;
  Future<void> _edit(BuildContext context, CloudSourceKind kind) async {
    final config = await pushNovelPage<CloudSourceConfig>(
      context,
      CloudConnectionPage(settings: settings, kind: kind),
      reduceMotion: reduceMotion,
    );
    if (context.mounted && config != null) await _browse(context, config);
  }

  Future<void> _browse(BuildContext context, CloudSourceConfig config) =>
      pushNovelPage<void>(
        context,
        CloudBookBrowser(
          config: config,
          settings: settings,
          onImport: onImport,
          onImportBatch: onImportBatch,
        ),
        reduceMotion: reduceMotion,
      );
  @override
  Widget build(BuildContext context) => _CloudScaffold(
    title: '网盘导入',
    code: 'LOCAL / CLOUD SOURCES',
    child: AnimatedBuilder(
      animation: settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ArchiveSection(title: '网盘来源', code: 'BOOKS / DOCUMENTS'),
          const SizedBox(height: 12),
          const AppText(
            '浏览网盘，选择书籍后导入本机。导入完成即可离线阅读。',
            style: TextStyle(fontSize: 13, height: 1.65),
          ),
          const SizedBox(height: 24),
          if (settings.error != null)
            AppText(
              settings.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final kind in CloudSourceKind.values) ...[
            ContentPanel(
              key: ValueKey('cloud-source-${kind.name}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: AppText(
                          kind == CloudSourceKind.quark
                              ? '夸克网盘 · 实验性'
                              : kind.label,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      ArchiveIcon(
                        kind != CloudSourceKind.quark
                            ? CupertinoIcons.cloud
                            : CupertinoIcons.folder,
                        size: 22,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AppText(switch (kind) {
                    CloudSourceKind.webdav =>
                      '连接 OpenList、AList、NAS 或其他 WebDAV 服务。百度网盘等可先在 OpenList 挂载。',
                    CloudSourceKind.quark =>
                      '使用本人网页 Cookie 直连，无需另搭服务。接口变化或登录失效时需要重新配置。',
                    CloudSourceKind.s3 => '连接 Amazon S3 或 S3 兼容存储，按文件夹浏览并导入书籍。',
                  }, style: const TextStyle(fontSize: 13, height: 1.65)),
                  const SizedBox(height: 12),
                  if (settings[kind] case final config?) ...[
                    AppText(
                      kind != CloudSourceKind.quark
                          ? config.endpoint.host
                          : '已保存本机连接',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    GlassPillButton(
                      key: ValueKey('cloud-browse-${kind.name}'),
                      icon: CupertinoIcons.folder_open,
                      label: '浏览书籍',
                      onPressed: () => _browse(context, config),
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        GlassTextButton(
                          onPressed: () => _edit(context, kind),
                          child: const AppText('修改连接'),
                        ),
                        GlassTextButton(
                          onPressed: () async {
                            try {
                              await settings.save(kind, null);
                            } catch (e) {
                              if (context.mounted) {
                                showNovelFeedback(
                                  context,
                                  cloudFailureMessage(e),
                                );
                              }
                            }
                          },
                          child: const AppText('移除连接'),
                        ),
                      ],
                    ),
                  ] else
                    GlassPillButton(
                      key: ValueKey('cloud-add-${kind.name}'),
                      icon: CupertinoIcons.plus,
                      label: switch (kind) {
                        CloudSourceKind.webdav => '添加 WebDAV 连接',
                        CloudSourceKind.quark => '配置夸克 Cookie',
                        CloudSourceKind.s3 => '添加 S3 连接',
                      },
                      onPressed: () => _edit(context, kind),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    ),
  );
}

class CloudConnectionPage extends StatefulWidget {
  const CloudConnectionPage({
    super.key,
    required this.settings,
    required this.kind,
    this.syncConnection = false,
  }) : assert(!syncConnection || kind == CloudSourceKind.s3);
  final CloudSourceSettings settings;
  final CloudSourceKind kind;
  final bool syncConnection;
  @override
  State<CloudConnectionPage> createState() => _CloudConnectionPageState();
}

class _CloudConnectionPageState extends State<CloudConnectionPage> {
  final _address = TextEditingController(),
      _user = TextEditingController(),
      _password = TextEditingController(),
      _cookie = TextEditingController();
  final _bucket = TextEditingController(),
      _region = TextEditingController(),
      _prefix = TextEditingController(),
      _token = TextEditingController(),
      _syncPath = TextEditingController();
  bool _pathStyle = true;
  bool _http = false, _busy = false;
  String? _error;
  CloudBookClient? _testing;
  @override
  void initState() {
    super.initState();
    final savedSync = widget.syncConnection ? widget.settings.s3Sync : null;
    final config = savedSync?.config ?? widget.settings[widget.kind];
    _address.text = config?.address ?? '';
    _user.text = config?.username ?? '';
    _password.text = config?.password ?? '';
    _cookie.text = config?.cookie ?? '';
    _http = config?.allowHttp ?? false;
    _bucket.text = config?.bucket ?? '';
    _region.text = config?.region ?? 'us-east-1';
    _prefix.text = config?.prefix ?? '';
    _token.text = config?.sessionToken ?? '';
    _pathStyle = config?.pathStyle ?? true;
    _syncPath.text = savedSync?.path ?? 'wenku8/library.wenku8sync';
  }

  @override
  void dispose() {
    _testing?.close();
    for (final c in [
      _address,
      _user,
      _password,
      _cookie,
      _bucket,
      _region,
      _prefix,
      _token,
      _syncPath,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var config = CloudSourceConfig(
        kind: widget.kind,
        address: _address.text.trim(),
        username: _user.text.trim(),
        password: _password.text,
        cookie: _cookie.text.trim(),
        allowHttp: _http,
        bucket: _bucket.text.trim(),
        region: _region.text.trim(),
        prefix: _prefix.text.trim(),
        sessionToken: _token.text.trim(),
        pathStyle: _pathStyle,
      );
      config.validate();
      if (widget.syncConnection) {
        final connection = S3SyncConnection(
          config: config,
          path: _syncPath.text.trim(),
        );
        connection.validate();
        await widget.settings.saveS3Sync(connection);
        if (mounted) Navigator.pop(context, config);
        return;
      }
      final client = _testing = CloudBookClient(config);
      await client.list(client.root);
      if (client is QuarkBookClient) config = client.config;
      if (!mounted) return;
      await widget.settings.save(widget.kind, config);
      if (mounted) Navigator.pop(context, config);
    } catch (e) {
      if (mounted) setState(() => _error = cloudFailureMessage(e));
    } finally {
      _testing?.close();
      _testing = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    String? helper,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 9),
        CupertinoTextField(
          key: ValueKey('cloud-field-$label'),
          onTap: () => AppHaptics.play(context, HapticCue.selection),
          onSubmitted: (_) => AppHaptics.play(context, HapticCue.action),
          controller: controller,
          enabled: !_busy,
          placeholder: hint,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: label.contains('地址')
              ? TextInputType.url
              : TextInputType.text,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: .045),
            borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
          ),
        ),
        if (helper != null) ...[
          const SizedBox(height: 7),
          AppText(
            helper,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => _CloudScaffold(
    title: widget.syncConnection
        ? 'S3 云端同步'
        : '连接 ${widget.kind == CloudSourceKind.webdav
              ? 'WebDAV'
              : widget.kind == CloudSourceKind.s3
              ? 'S3'
              : '夸克网盘'}',
    code: widget.syncConnection ? 'LIBRARY / S3 SYNC' : 'LOCAL / CONNECTION',
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.kind == CloudSourceKind.webdav) ...[
              const AppText(
                'OpenList 地址一般以 /dav/ 结尾。账号需要 WebDAV 读取权限。',
                style: TextStyle(height: 1.65),
              ),
              const SizedBox(height: 24),
              _field('WebDAV 地址', _address, hint: 'https://你的域名/dav/'),
              _field('用户名', _user),
              _field('密码', _password, secret: true),
              Row(
                children: [
                  const Expanded(child: AppText('允许 HTTP 连接')),
                  AppControls.toggle(
                    context,
                    value: _http,
                    onChanged: _busy ? null : (v) => setState(() => _http = v),
                  ),
                ],
              ),
              AnimatedOptionSection(
                expanded: _http,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: AppText(
                    'HTTP 不加密传输账号和书籍，仅在可信局域网中使用。',
                    style: TextStyle(height: 1.6),
                  ),
                ),
              ),
            ] else if (widget.kind == CloudSourceKind.s3) ...[
              AppText(
                widget.syncConnection
                    ? '两台设备填写相同的桶与同步文件路径。同步需要读取、写入此文件的权限，只有点按「立即同步」才会传输。'
                    : '填写存储服务的 Endpoint 和桶名。连接只需列目录、读取对象的权限。',
                style: const TextStyle(height: 1.65),
              ),
              const SizedBox(height: 24),
              _field(
                'Endpoint 地址',
                _address,
                hint: 'https://s3.us-east-1.amazonaws.com',
              ),
              _field('存储桶 Bucket', _bucket),
              _field('区域 Region', _region, hint: 'us-east-1'),
              _field('Access Key ID', _user),
              _field('Secret Access Key', _password, secret: true),
              _field('目录前缀（可选）', _prefix, hint: 'books/'),
              if (widget.syncConnection)
                _field(
                  '同步文件路径',
                  _syncPath,
                  hint: 'wenku8/library.wenku8sync',
                  helper: '位于目录前缀内；使用独立的 .wenku8sync 文件。',
                ),
              _field('Session Token（可选）', _token, secret: true),
              Row(
                children: [
                  const Expanded(child: AppText('路径式寻址')),
                  AppControls.toggle(
                    context,
                    value: _pathStyle,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _pathStyle = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: AppText('允许 HTTP 连接')),
                  AppControls.toggle(
                    context,
                    value: _http,
                    onChanged: _busy ? null : (v) => setState(() => _http = v),
                  ),
                ],
              ),
              AnimatedOptionSection(
                expanded: _http,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: AppText(
                    'HTTP 不加密传输连接信息和书籍，仅在可信局域网中使用。',
                    style: TextStyle(height: 1.6),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const AppText(
                '凭据只保存在本机加密存储，不写入阅读备份。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
            ] else ...[
              const AppText(
                '在电脑登录 pan.quark.cn，打开开发者工具的「网络」，复制网盘请求中的 Cookie 请求头。只填写 Cookie 的值。',
                style: TextStyle(height: 1.7),
              ),
              const SizedBox(height: 24),
              _field(
                'Cookie',
                _cookie,
                hint: '__pus=…; __puus=…',
                secret: true,
              ),
              const AppText(
                '登录凭据仅加密保存在这台设备。导入只读取文件，不移动或删除网盘内容。',
                style: TextStyle(height: 1.65),
              ),
            ],
            const SizedBox(height: 20),
            if (_busy)
              BookRowSkeleton(
                label: widget.syncConnection ? '正在保存同步连接' : '正在检查目录读取权限',
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: AppText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            GlassPillButton(
              key: const ValueKey('cloud-connect'),
              icon: CupertinoIcons.link,
              label: _busy
                  ? widget.syncConnection
                        ? '正在保存'
                        : '正在连接'
                  : widget.syncConnection
                  ? '保存同步连接'
                  : '连接并浏览',
              onPressed: _busy ? null : _connect,
            ),
            if (_busy && !widget.syncConnection)
              GlassTextButton(
                onPressed: () => _testing?.cancel(),
                child: const AppText('取消连接'),
              ),
          ],
        ),
      ),
    ),
  );
}

class CloudBookBrowser extends StatefulWidget {
  const CloudBookBrowser({
    super.key,
    required this.config,
    required this.settings,
    required this.onImport,
    this.onImportBatch,
    this.client,
  });
  final CloudSourceConfig config;
  final CloudSourceSettings settings;
  final ImportCloudBook onImport;
  final ImportCloudBatch? onImportBatch;
  final CloudBookClient? client;
  @override
  State<CloudBookBrowser> createState() => _CloudBookBrowserState();
}

class _CloudBookBrowserState extends State<CloudBookBrowser> {
  late CloudBookClient _client;
  final _folders = <({String id, String name})>[];
  final _selected = <String, CloudBookEntry>{};
  final _imported = <String>{};
  List<CloudBookEntry> _entries = [];
  int? _next;
  bool _loading = true,
      _importing = false,
      _cancelled = false,
      _committing = false;
  int _generation = 0, _received = 0;
  int? _total;
  String? _error, _current, _loadedFolder;
  @override
  void initState() {
    super.initState();
    _client =
        widget.client ??
        CloudBookClient(widget.config, settings: widget.settings);
    _folders.add((id: _client.root, name: '全部文件'));
    _load();
  }

  @override
  void dispose() {
    _client.close();
    _generation++;
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final token = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await _client.list(
        _folders.last.id,
        page: more ? _next! : 1,
      );
      if (!mounted || token != _generation) return;
      setState(() {
        final old = more ? _entries : <CloudBookEntry>[];
        final values = {
          for (final e in old) e.id: e,
          for (final e in listing.entries) e.id: e,
        };
        _entries = values.values.toList();
        _loadedFolder = _folders.last.id;
        _next = listing.nextPage;
      });
    } catch (e) {
      if (mounted && token == _generation) {
        setState(() => _error = cloudFailureMessage(e));
      }
    } finally {
      if (mounted && token == _generation) setState(() => _loading = false);
    }
  }

  void _enter(CloudBookEntry entry) {
    if (_importing || _loading) return;
    setState(() {
      _folders.add((id: entry.id, name: entry.name));
      _entries = [];
      _selected.clear();
      _next = null;
    });
    _load();
  }

  void _up() {
    if (_folders.length <= 1 || _importing) return;
    setState(() {
      _folders.removeLast();
      _entries = [];
      _selected.clear();
      _next = null;
    });
    _load();
  }

  Future<void> _import(List<CloudBookEntry> entries) async {
    if (_importing || entries.isEmpty) return;
    setState(() {
      _importing = true;
      _cancelled = false;
      _error = null;
    });
    var count = 0;
    var failed = 0;
    Directory? work;
    try {
      work = await Directory(
        '${(await getTemporaryDirectory()).path}/cloud-book-import',
      ).create(recursive: true);
      final batch = await work.createTemp('batch-');
      work = batch;
      for (final entry in entries) {
        if (!mounted || _cancelled) break;
        setState(() {
          _current = entry.name;
          _received = 0;
          _total = entry.size > 0 ? entry.size : null;
        });
        final file = File('${work.path}/book');
        try {
          await _client.download(
            entry,
            file,
            onProgress: (received, total) {
              // Throttle UI updates, not downloads or parsing, to avoid rebuilding
              // the glass list on every socket chunk.
              if (mounted &&
                  (received - _received >= 128 * 1024 || received == total)) {
                setState(() {
                  _received = received;
                  _total = total;
                });
              }
            },
          );
          if (!mounted || _cancelled) break;
          setState(() => _committing = true);
          var complete = true;
          if (widget.onImportBatch != null) {
            final batch = await widget.onImportBatch!(entry.name, file.path);
            count += batch.imported;
            failed += batch.failed;
            complete = batch.failed == 0;
          } else {
            await widget.onImport(entry.name, file.path);
            count++;
          }
          if (complete) {
            _selected.remove(entry.id);
            _imported.add(entry.id);
          }
        } finally {
          _committing = false;
          if (await file.exists()) await file.delete();
        }
      }
      if (mounted) {
        showNovelFeedback(
          context,
          _cancelled
              ? '已取消，已导入 $count 本'
              : failed > 0
              ? '已导入 $count 本 · $failed 本未导入，返回后可查看详情'
              : '已导入 $count 本，返回书库即可阅读',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              '${cloudFailureMessage(e)}${count > 0 ? ' · 已导入 $count 本' : ''}',
        );
      }
    } finally {
      if (work != null &&
          work.path.split('/').last.startsWith('batch-') &&
          await work.exists()) {
        await work.delete(recursive: true);
      }
      if (_cancelled) {
        _client = CloudBookClient(
          widget.settings[widget.config.kind] ?? widget.config,
          settings: widget.settings,
        );
      }
      if (mounted) {
        setState(() {
          _importing = false;
          _current = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_committing && _folders.length == 1,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_committing) _up();
    },
    child: _CloudScaffold(
      title: widget.config.label,
      code: 'LOCAL / FILE BROWSER',
      onBack: _folders.length > 1 ? _up : null,
      sliverBody: LoadedContentSequence(
        generation: _folders.last.id,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: AppText(
                            _folders.last.name,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        GlassIconButton(
                          icon: CupertinoIcons.refresh,
                          label: '刷新网盘目录',
                          onPressed: _loading || _importing
                              ? null
                              : () => _load(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const AppText(
                      '支持电子书与常见文档，可勾选批量导入；ZIP 内的分卷会一起识别。',
                      style: TextStyle(height: 1.65),
                    ),
                    const SizedBox(height: 16),
                    if (_importing) ...[
                      AppText(
                        '正在导入 · $_current',
                        style: const TextStyle(height: 1.6),
                      ),
                      const SizedBox(height: 8),
                      AppText(
                        _committing
                            ? '正在解析目录与插图'
                            : '${(_received / 1024).round()} KB${_total == null ? '' : ' / ${(_total! / 1024).round()} KB'}',
                      ),
                      GlassTextButton(
                        onPressed: _committing
                            ? null
                            : () {
                                _cancelled = true;
                                _client.cancel();
                              },
                        child: const AppText('取消导入'),
                      ),
                    ] else if (_selected.isNotEmpty) ...[
                      GlassPillButton(
                        icon: CupertinoIcons.arrow_down_doc,
                        label: '导入选中的 ${_selected.length} 本',
                        onPressed: () => _import(_selected.values.toList()),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_error != null) ...[
                      AppText(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          height: 1.6,
                        ),
                      ),
                      GlassTextButton(
                        onPressed: _loading || _importing
                            ? null
                            : () => _load(),
                        child: const AppText('刷新目录'),
                      ),
                    ],
                    if (_loading &&
                        _entries.isEmpty &&
                        _loadedFolder != _folders.last.id)
                      const BookRowSkeleton(label: '正在读取网盘目录'),
                    if (!_loading && _error == null && _entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: AppText(
                          '这个目录没有可导入的书籍。',
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverList.builder(
                itemCount: _entries.length,
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  return LoadedContentItem(
                    key: ValueKey(('cloud-entry', entry.id)),
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          ArchiveIcon(
                            entry.folder
                                ? CupertinoIcons.folder
                                : CupertinoIcons.doc_text,
                            size: 24,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: JellyTapSurface(
                              onTap: _importing || _loading
                                  ? null
                                  : () => entry.folder
                                        ? _enter(entry)
                                        : _import([entry]),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AppText(
                                      entry.name,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        height: 1.5,
                                      ),
                                    ),
                                    if (!entry.folder)
                                      AppText(
                                        _imported.contains(entry.id)
                                            ? '已导入'
                                            : entry.size > 0
                                            ? formatCacheBytes(entry.size)
                                            : '大小未知',
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (entry.folder)
                            const ArchiveIcon(
                              CupertinoIcons.chevron_forward,
                              size: 16,
                            )
                          else
                            GlassIconButton(
                              icon: _selected.containsKey(entry.id)
                                  ? CupertinoIcons.checkmark_circle_fill
                                  : CupertinoIcons.circle,
                              label: '选择 ${entry.name}',
                              onPressed: _importing
                                  ? null
                                  : () => setState(() {
                                      if (_selected.containsKey(entry.id)) {
                                        _selected.remove(entry.id);
                                      } else {
                                        _selected[entry.id] = entry;
                                      }
                                    }),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                24,
                12,
                24,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_loading && _entries.isNotEmpty)
                      const BookRowSkeleton(label: '正在读取更多文件'),
                    if (!_loading && _next != null)
                      GlassTextButton(
                        onPressed: _importing ? null : () => _load(more: true),
                        child: const AppText('加载更多文件'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CloudScaffold extends StatelessWidget {
  const _CloudScaffold({
    required this.title,
    required this.code,
    this.child,
    this.sliverBody,
    this.onBack,
  });
  final String title, code;
  final Widget? child, sliverBody;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Atmosphere(
      child: GlassHeaderLayout(
        header: ArchiveHeaderBar(
          leading: GlassIconButton(
            icon: CupertinoIcons.back,
            label: '返回',
            onPressed: onBack ?? () => Navigator.maybePop(context),
          ),
          title: ArchiveRouteTitle(title: title, code: code),
        ),
        body:
            sliverBody ??
            SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              child: child,
            ),
      ),
    ),
  );
}
