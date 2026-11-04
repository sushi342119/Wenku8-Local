import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'app_interactions.dart';
import 'book_sync.dart';
import 'cloud_library_page.dart';
import 'cloud_sources.dart';

class CloudBookSyncPanel extends StatelessWidget {
  const CloudBookSyncPanel({super.key, required this.sync});
  final BookSync sync;
  Future<void> _configure(
    BuildContext context,
    Future<void> Function() save,
  ) async {
    try {
      await save();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '同步设置保存失败，请重试');
    }
  }

  Future<void> _configureS3(BuildContext context) async {
    final settings = sync.cloudSources;
    if (settings == null || sync.busy) return;
    await pushNovelPage<CloudSourceConfig>(
      context,
      CloudConnectionPage(
        settings: settings,
        kind: CloudSourceKind.s3,
        syncConnection: true,
      ),
      reduceMotion: sync.state.reduceMotion,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sync,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: ArchiveSection(title: '云端同步', code: 'LIBRARY / SYNC'),
              ),
              GlassIconButton(
                icon: CupertinoIcons.xmark,
                label: '关闭同步设置',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const AppText('连接位置', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final provider in ['S3', 'OneDrive', 'Google Drive', '其他位置'])
                Semantics(
                  selected: sync.preferredProvider == provider,
                  child: GlassTextButton(
                    key: ValueKey('sync-provider-$provider'),
                    compact: true,
                    selected: sync.preferredProvider == provider,
                    onPressed: sync.busy
                        ? null
                        : () => _configure(
                            context,
                            () => sync.configure(provider: provider),
                          ),
                    child: AppText(
                      provider,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedOptionSection(
            expanded: sync.usingS3,
            child: _s3Location(context),
          ),
          AnimatedOptionSection(
            expanded: !sync.usingS3,
            child: _documentLocation(),
          ),
          const Divider(height: 28),
          const AppText('同步内容', style: TextStyle(fontWeight: FontWeight.w600)),
          _option(
            context,
            '本地原书',
            'TXT、EPUB 与书内插图',
            sync.syncOriginals,
            'sync-originals',
            (v) => sync.configure(originals: v),
          ),
          _option(
            context,
            '阅读进度与书签',
            '按更新时间合并，不覆盖较新的进度',
            sync.syncReading,
            'sync-reading',
            (v) => sync.configure(reading: v),
          ),
          _option(
            context,
            '本地分类',
            '分类名称与书籍归属',
            sync.syncCategories,
            'sync-categories',
            (v) => sync.configure(categories: v),
          ),
          const SizedBox(height: 14),
          if (sync.lastSync case final time?)
            AppText(
              '上次同步 ${DateTime.fromMillisecondsSinceEpoch(time).toLocal().toString().substring(0, 16)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 12),
          GlassPillButton(
            key: const ValueKey('sync-now'),
            icon: CupertinoIcons.arrow_2_circlepath,
            label: sync.busy ? '正在同步' : '立即同步',
            onPressed:
                sync.busy ||
                    !sync.connected ||
                    !(sync.syncOriginals ||
                        sync.syncReading ||
                        sync.syncCategories)
                ? null
                : sync.sync,
          ),
          if (sync.connected)
            GlassTextButton(
              onPressed: sync.busy ? null : sync.disconnect,
              child: const AppText('断开连接'),
            ),
          if (sync.status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AppText(sync.status!),
            ),
          AnimatedOptionSection(
            expanded: sync.error != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                AppText(
                  sync.error ?? '',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                GlassTextButton(
                  onPressed: sync.busy ? null : () => sync.recover('next'),
                  child: const AppText('从上次完整同步副本恢复到本机'),
                ),
                GlassTextButton(
                  onPressed: sync.busy ? null : () => sync.recover('before'),
                  child: const AppText('从写入前的云端副本恢复到本机'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppText(
            sync.usingS3
                ? '每次手动合并后写回同一同步文件；移除本机书籍不会删除云端原书。'
                : '文件选择器未显示网盘时，请先安装并登录对应网盘应用。只有获得读写授权的同步文件可以连接；移除本机书籍不会删除云端原书。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _s3Location(BuildContext context) {
    final connection = sync.s3Connection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (connection == null)
          const AppText(
            '连接 S3 或兼容存储，在不同设备间合并原书、阅读进度与分类。',
            style: TextStyle(height: 1.65),
          )
        else
          ContentPanel(
            key: const ValueKey('sync-s3-location'),
            child: ArchivePart(
              start: .24,
              end: .88,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const ArchiveIcon(CupertinoIcons.cloud, size: 18),
                      const SizedBox(width: 9),
                      Expanded(
                        child: AppText(
                          connection.config.bucket,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  AppText(
                    connection.config.endpoint.host,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 7),
                  AppText(
                    connection.objectKey,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: GlassTextButton(
            key: const ValueKey('sync-configure-s3'),
            onPressed: sync.busy || sync.cloudSources == null
                ? null
                : () => _configureS3(context),
            child: AppText(connection == null ? '配置 S3 同步' : '修改 S3 连接'),
          ),
        ),
      ],
    );
  }

  Widget _documentLocation() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AppText(
        sync.connection == null
            ? '在系统文件选择器侧栏选择 ${sync.preferredProvider}。首次新建同步文件，其他设备选择同一个文件。'
            : '已连接 ${sync.providerLabel}\n${sync.connection!['name']}',
        style: const TextStyle(height: 1.65),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        children: [
          GlassTextButton(
            key: const ValueKey('sync-create-document'),
            onPressed: sync.busy ? null : () => sync.connect(create: true),
            child: const AppText('新建同步文件'),
          ),
          GlassTextButton(
            key: const ValueKey('sync-select-document'),
            onPressed: sync.busy ? null : () => sync.connect(create: false),
            child: const AppText('选择已有文件'),
          ),
        ],
      ),
    ],
  );

  Widget _option(
    BuildContext context,
    String title,
    String detail,
    bool value,
    String key,
    Future<void> Function(bool) changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: ArchivePart(
      start: .24,
      end: .88,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                AppText(
                  detail,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppControls.toggle(
            context,
            key: ValueKey(key),
            value: value,
            onChanged: sync.busy
                ? null
                : (v) => _configure(context, () => changed(v)),
          ),
        ],
      ),
    ),
  );
}
