import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'library_state.dart';

/// Separate from the legacy API/JNI contract. Only explicit user file actions
/// open the Android picker; the normal reader does not alter system settings.
abstract final class LocalPlatform {
  static const channel = MethodChannel('org.mewx.wenku8/local_tools');
  static bool get android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static Future<bool> exportBackup(String text, String name) async =>
      await channel.invokeMethod<bool>('exportBackup', {
        'text': text,
        'name': name,
      }) ??
      false;
  static Future<String?> importBackup() =>
      channel.invokeMethod<String>('importBackup');
  static Future<Map<Object?, Object?>?> importLegacyData() =>
      channel.invokeMapMethod<Object?, Object?>('importLegacyData');

  // ---- 本地书库：SAF 文件夹 / 文本 / PDF ----
  /// 打开系统文件夹选择器，返回持久授权的 tree URI；用户取消返回 null。
  static Future<String?> pickLocalFolder() =>
      channel.invokeMethod<String>('pickLocalFolder');

  /// 扫描已授权文件夹中的 txt / pdf。
  /// 返回 (entries, complete, reason)：entries 为 [{uri, name, size, modified}]；
  /// complete 为 false 表示扫描不完整（此时禁止执行删除）。
  static Future<({List<Map<String, Object?>> entries, bool complete, String? reason})>
      scanLocalFolder(String treeUri) async {
    final result = await channel.invokeMethod<Map<Object?, Object?>>(
      'scanLocalFolder',
      {'treeUri': treeUri},
    );
    if (result == null) {
      return (entries: <Map<String, Object?>>[], complete: false, reason: 'null_result');
    }
    final rawEntries = result['entries'];
    final List<Map<String, Object?>> entries = rawEntries is List
        ? rawEntries
            .whereType<Map<Object?, Object?>>()
            .map((m) => m.map((k, v) => MapEntry('$k', v)))
            .toList()
        : <Map<String, Object?>>[];
    // 缺少 complete 字段时按不完整处理（兼容旧原生版本）。
    final bool complete = result['complete'] == true;
    final String? reason = result['reason'] as String?;
    return (entries: entries, complete: complete, reason: reason);
  }

  /// 读取文本文件并自动识别 UTF-8 / GB18030 编码。
  static Future<String> readLocalText(String docUri) async =>
      await channel.invokeMethod<String>('readLocalText', {'docUri': docUri}) ??
      '';

  static Future<int> pdfPageCount(String docUri) async =>
      await channel.invokeMethod<int>('pdfPageCount', {'docUri': docUri}) ?? 0;

  /// 渲染 PDF 单页为缓存 PNG，返回绝对路径。
  static Future<String> renderPdfPage(
    String docUri,
    int page,
    int widthPx,
  ) async =>
      await channel.invokeMethod<String>('renderPdfPage', {
        'docUri': docUri,
        'page': page,
        'widthPx': widthPx,
      }) ??
      '';

  /// 删除某 PDF 的全部渲染缓存。
  static Future<void> clearPdfCache(String docUri) =>
      channel.invokeMethod<bool>('clearPdfCache', {'docUri': docUri});
  static Future<void> shareText(String text) =>
      channel.invokeMethod<void>('shareText', {'text': text});
  static final Set<Object> _awakeOwners = {};
  static bool _requestedAwake = false;

  static void keepScreen(Object owner, bool enabled) {
    if (enabled && android) {
      _awakeOwners.add(owner);
    } else {
      _awakeOwners.remove(owner);
    }
    final awake = _awakeOwners.isNotEmpty;
    if (awake == _requestedAwake) return;
    _requestedAwake = awake;
    // No polling, permanent ticker, global timeout change or wake lock.
    channel.invokeMethod<void>('keepScreenOn', awake).catchError((Object _) {});
  }
}

/// Route/lifecycle notifications rebuild only this zero-size binding, not the
/// reader's article. Covering/leaving the page or backgrounding releases it.
class ReaderScreenBinding extends StatefulWidget {
  const ReaderScreenBinding({super.key, required this.state});
  final LibraryState state;
  @override
  State<ReaderScreenBinding> createState() => _ReaderScreenBindingState();
}

class _ReaderScreenBindingState extends State<ReaderScreenBinding>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool _current = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.readerBehaviorChanges.addListener(_update);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  void _update() => LocalPlatform.keepScreen(
    this,
    mounted && _foreground && _current && widget.state.keepScreenOn,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
    _update();
  }

  @override
  void didUpdateWidget(ReaderScreenBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.readerBehaviorChanges.removeListener(_update);
      widget.state.readerBehaviorChanges.addListener(_update);
      _update();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  @override
  void dispose() {
    widget.state.readerBehaviorChanges.removeListener(_update);
    WidgetsBinding.instance.removeObserver(this);
    LocalPlatform.keepScreen(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
