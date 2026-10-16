import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_interactions.dart';
import '../app_ui.dart';
import 'app_updates.dart';

class AppUpdatesScope extends InheritedNotifier<AppUpdates> {
  const AppUpdatesScope({
    super.key,
    required AppUpdates updates,
    required super.child,
  }) : super(notifier: updates);
  static AppUpdates? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdatesScope>()?.notifier;
}

class AppUpdateMonitor extends StatefulWidget {
  const AppUpdateMonitor({
    super.key,
    required this.updates,
    required this.child,
  });
  final AppUpdates updates;
  final Widget child;
  @override
  State<AppUpdateMonitor> createState() => _AppUpdateMonitorState();
}

class _AppUpdateMonitorState extends State<AppUpdateMonitor>
    with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.updates.loadInstalled().catchError((Object _) {}));
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 8), () {
      if (mounted) unawaited(widget.updates.check(automatic: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedule();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AppUpdatesScope(updates: widget.updates, child: widget.child);
}

class AppUpdatePage extends StatelessWidget {
  const AppUpdatePage({super.key, this.updates});
  final AppUpdates? updates;
  @override
  Widget build(BuildContext context) => updates == null
      ? _page(context)
      : AnimatedBuilder(
          animation: updates!,
          builder: (context, _) => _page(context),
        );

  Widget _page(BuildContext context) {
    final service = updates;
    final padding = MediaQuery.paddingOf(context);
    final version = service?.installed?.version ?? currentAppVersion;
    final build = service?.installed?.build ?? currentAppBuild;
    final available = service?.available ?? false;
    return Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: Row(
            children: [
              GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回设置',
                onPressed: () => Navigator.pop(context),
              ),
              const Expanded(
                child: ArchiveRouteTitle(
                  title: '关于轻小说文库',
                  code: 'SYSTEM / ABOUT',
                ),
              ),
            ],
          ),
          body: ListView(
            key: const ValueKey('update-page-scroll'),
            padding: EdgeInsets.fromLTRB(
              24 + padding.left,
              padding.top + FrostedHeader.toolbarHeight + 20,
              24 + padding.right,
              padding.bottom + 32,
            ),
            children: [
              const ArchiveSection(title: '轻小说文库', code: 'WENKU8 / FLUTTER'),
              const SizedBox(height: 12),
              Text(
                '当前版本 $version · 构建 $build',
                key: const ValueKey('installed-app-version'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              if (service != null) ...[
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '自动检查更新',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 12),
                          CupertinoSwitch(
                            key: const ValueKey('automatic-update-check'),
                            value: service.autoCheck,
                            activeTrackColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            onChanged: (value) async {
                              try {
                                await service.setAutoCheck(value);
                              } catch (_) {
                                if (context.mounted) {
                                  showNovelFeedback(context, '设置保存失败，请重试');
                                }
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '打开应用时检查 GitHub Releases，下载与安装由你确认。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      GlassTextButton(
                        key: const ValueKey('check-app-update'),
                        onPressed: service.checking || service.downloading
                            ? null
                            : () => service.check(),
                        child: Text(service.checking ? '正在检查版本' : '检查更新'),
                      ),
                      if (service.checking) ...[
                        const SizedBox(height: 12),
                        const SizedBox(
                          height: 16,
                          child: LoadingSkeleton(layout: SkeletonLayout.inline),
                        ),
                      ] else if (service.checked && !available) ...[
                        const SizedBox(height: 12),
                        Text(
                          service.release == null ? '暂未发布可用的正式版本' : '已是最新版本',
                        ),
                      ],
                      if (service.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          service.error!,
                          key: const ValueKey('update-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (available) ...[
                  const SizedBox(height: 24),
                  ArchiveSection(
                    title: '发现新版本 ${service.release!.version.name}',
                    code: 'GITHUB / RELEASE',
                  ),
                  const SizedBox(height: 14),
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ReleaseNotes(
                          service.release!.notes.isEmpty
                              ? '此版本未提供更新说明。'
                              : service.release!.notes,
                        ),
                        const SizedBox(height: 16),
                        if (service.downloading) ...[
                          Text(
                            '已下载 ${(service.bytes / 1024 / 1024).toStringAsFixed(1)} / ${(service.asset!.size / 1024 / 1024).toStringAsFixed(1)} MB',
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: (service.bytes / service.asset!.size).clamp(
                              0.0,
                              1.0,
                            ),
                            color: Theme.of(context).colorScheme.primary,
                            minHeight: 2,
                          ),
                          GlassTextButton(
                            onPressed: service.cancelDownload,
                            child: const Text('取消下载'),
                          ),
                        ] else if (service.downloaded != null) ...[
                          if (service.needsPermission)
                            Text(
                              '请允许本应用安装更新，返回后再次点击「安装更新」。',
                              style: TextStyle(
                                height: 1.5,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (service.needsPermission)
                            GlassTextButton(
                              onPressed: () => _open(
                                context,
                                service.platform.allowInstalls,
                              ),
                              child: const Text('允许安装更新'),
                            ),
                          GlassTextButton(
                            key: const ValueKey('install-app-update'),
                            onPressed: service.install,
                            child: const Text('安装更新'),
                          ),
                        ] else if (service.asset != null)
                          GlassTextButton(
                            key: const ValueKey('download-app-update'),
                            onPressed: service.download,
                            child: Text(
                              '下载更新 · ${(service.asset!.size / 1024 / 1024).toStringAsFixed(1)} MB',
                            ),
                          )
                        else
                          const Text('此版本暂无适合本机的 APK。'),
                        GlassTextButton(
                          onPressed: () => _open(
                            context,
                            () => service.platform.openRelease(
                              service.release!.page,
                            ),
                          ),
                          child: const Text('在 GitHub 查看此版本'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 28),
              ],
              const ArchiveSection(
                title: '本版更新',
                code: 'RELEASE / $currentAppVersion',
              ),
              const SizedBox(height: 14),
              const ContentPanel(child: ReleaseNotes(currentReleaseNotes)),
              const SizedBox(height: 28),
              const ArchiveSection(title: '项目与许可', code: 'SOURCE / LICENSES'),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '基于 MewX 与原项目贡献者的轻小说文库 Android 客户端重构。原项目 GPL v2 或后续版本许可保留；本 Flutter 组合版本按 GPL v3 分发。',
                      style: TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '小说正文、封面和插图的权利属于各自权利人。',
                      style: TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '内置字体：Adobe 思源宋体 CN，SIL OFL 1.1。在线语音协议适配：rany2/edge-tts，LGPL v3。接口运行库 libcpp.so 原样保留，其授权独立于本项目源码。',
                      style: TextStyle(height: 1.6),
                    ),
                    GlassTextButton(
                      key: const ValueKey('app-open-source-licenses'),
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: '轻小说文库',
                        applicationVersion: currentAppVersion,
                        applicationLegalese:
                            'Copyright © MewX and contributors\nFlutter modifications © 2026 Wenku8 Flutter contributors',
                      ),
                      child: const Text('开源许可与字体授权'),
                    ),
                    if (service != null) ...[
                      const SizedBox(height: 12),
                      GlassTextButton(
                        onPressed: () => _open(
                          context,
                          () => service.platform.openRelease(
                            Uri.https(
                              'github.com',
                              '/$updateRepository/releases/',
                            ),
                          ),
                        ),
                        child: const Text('GitHub 项目与版本'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '暂时无法打开，请稍后重试');
    }
  }
}

class ReleaseNotes extends StatelessWidget {
  const ReleaseNotes(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final line in text.trim().split('\n'))
        if (line.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              line
                  .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
                  .replaceFirst(RegExp(r'^[-*]\s+'), '· '),
              style: TextStyle(
                height: 1.6,
                fontWeight: line.startsWith('#')
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
    ],
  );
}
