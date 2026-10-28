import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'library_state.dart';

/// SAF 源文件删除失败（原生侧结构化错误码）。
/// code: permission（无写权限）/ unsupported（存储不支持删除）/
/// delete_rejected（provider 拒绝）/ invalid_uri（源文件地址失效）/
/// io_error（存储暂时不可用）/ unknown。
class LocalDeleteException implements Exception {
  const LocalDeleteException(this.code, [this.message]);
  final String code;
  final String? message;

  @override
  String toString() => 'LocalDeleteException($code, $message)';
}

/// 某 SAF 树目录的持久化权限：只作为是否重试删除的依据，
/// 不承诺 provider 支持删除。
class LocalTreePermission {
  const LocalTreePermission({
    required this.persistedRead,
    required this.persistedWrite,
  });

  final bool persistedRead;
  final bool persistedWrite;

  String get deletionHint =>
      (persistedRead && persistedWrite)
          ? ''
          : '当前授权读取或写权限未确认，App 暂不能凭此授权删除源文件；'
              '重新授权时请确认授予读写权限';
}

const _knownLocalDeleteCodes = <String>{
  'permission',
  'unsupported',
  'delete_rejected',
  'invalid_uri',
  'io_error',
};

/// 用可注入的 MethodChannel 删除 SAF 文档，便于测试协议解析。
/// 旧原生把 FileNotFound 映射成的 notFound:true 不再接受为成功。
Future<void> deleteLocalDocumentWithChannel(
  MethodChannel channel,
  String documentUri,
) async {
  final Map<String, dynamic>? result;
  try {
    result = await channel.invokeMapMethod<String, dynamic>(
      'deleteLocalDocument',
      {'docUri': documentUri},
    );
  } on PlatformException catch (error) {
    throw LocalDeleteException(
      _knownLocalDeleteCodes.contains(error.code) ? error.code : 'unknown',
      error.message,
    );
  }
  final outcome = result?['outcome'];
  // 兼容旧原生真实删除成功的返回。
  if (result?['deleted'] == true &&
      result?['notFound'] != true &&
      result?['code'] == null &&
      (outcome == 'deleted' || outcome == null)) {
    return;
  }
  if (result?['notFound'] == true || outcome == 'unconfirmed') {
    throw LocalDeleteException(
      'io_error',
      '文件提供方无法确认删除结果，请恢复连接后重试',
    );
  }
  final rawCode = result?['code'];
  final rawMessage = result?['message'];
  throw LocalDeleteException(
    rawCode is String && _knownLocalDeleteCodes.contains(rawCode)
        ? rawCode
        : 'unknown',
    rawMessage is String ? rawMessage : '未收到可确认的删除结果',
  );
}

/// Separate from the legacy API/JNI contract. Only explicit user file actions
/// open the Android picker; the normal reader does not alter system settings.
abstract final class LocalPlatform {
  static const channel = MethodChannel('org.mewx.wenku8/local_tools');
  static const _localIoTimeout = Duration(seconds: 30);
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
  static Future<
    ({List<Map<String, Object?>> entries, bool complete, String? reason})
  >
  scanLocalFolder(String treeUri) async {
    final result = await channel
        .invokeMethod<Map<Object?, Object?>>('scanLocalFolder', {
          'treeUri': treeUri,
        })
        .timeout(
          _localIoTimeout,
          onTimeout: () => throw TimeoutException('目录查询超时，请重试'),
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
      await channel
          .invokeMethod<String>('readLocalText', {'docUri': docUri})
          .timeout(
            _localIoTimeout,
            onTimeout: () => throw TimeoutException('源文件读取超时，请重试'),
          ) ??
      '';

  /// Native decoding streams into a temporary UTF-8 file; callers own cleanup.
  static Future<String> prepareLocalText(String docUri) async {
    final path = await channel
        .invokeMethod<String>('prepareLocalText', {'docUri': docUri})
        .timeout(
          _localIoTimeout,
          onTimeout: () => throw TimeoutException('源文件读取超时，请重试'),
        );
    if (path == null || path.isEmpty) throw StateError('原生文本解码未返回文件');
    return path;
  }

  static Future<String> fingerprintLocalText(String docUri) async {
    final fingerprint = await channel.invokeMethod<String>(
      'fingerprintLocalText', {'docUri': docUri},
    ).timeout(_localIoTimeout);
    if (fingerprint == null || fingerprint.isEmpty) {
      throw StateError('源文件 SHA-256 校验未返回结果');
    }
    return fingerprint;
  }

  static Future<({String path, String fingerprint})> prepareLocalTextSource(
    String docUri,
  ) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'prepareLocalText', {'docUri': docUri, 'withFingerprint': true},
    ).timeout(_localIoTimeout);
    final path = result?['path'] as String?;
    final fingerprint = result?['fingerprint'] as String?;
    if (path == null || path.isEmpty || fingerprint == null || fingerprint.isEmpty) {
      throw StateError('源文件解码或 SHA-256 校验未返回结果');
    }
    return (path: path, fingerprint: fingerprint);
  }

  /// 解码原始字节，自动识别 UTF-8 / GB18030 编码。
  /// encoding: 'auto'（默认，先 UTF-8 后 GB18030）、'utf-8'、'gb18030'
  static Future<String> decodeLocalText(
    Uint8List bytes, {
    String encoding = 'auto',
  }) async {
    final text = await channel.invokeMethod<String>(
      'decodeLocalText',
      {'bytes': bytes, 'encoding': encoding},
    );
    if (text == null) throw StateError('原生文本解码未返回结果');
    return text;
  }

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

  /// SAF：删除文档。provider 确认删除成功才算成功；无法确认时
  /// （如 FileNotFoundException）抛 io_error，保留本地记录，不再把
  /// “已不存在”当成删除成功。失败抛 [LocalDeleteException]
  /// 并带原生侧的结构化 code，供上层区分提示与兜底（重授权/仅移出书库）。
  static Future<void> deleteLocalDocument(String documentUri) =>
      deleteLocalDocumentWithChannel(channel, documentUri);

  /// 查询某 SAF 树 URI 的持久化读/写权限（原生侧查 persistedUriPermissions）。
  /// 查询失败时保守返回“读已确认、写未确认”，避免凭猜测重试删除。
  static Future<LocalTreePermission> queryTreePermission(
    String treeUri,
  ) async {
    try {
      final res = await channel
          .invokeMapMethod<String, dynamic>('queryTreePermission', {
            'treeUri': treeUri,
          })
          .timeout(
            _localIoTimeout,
            onTimeout: () => throw TimeoutException('目录权限查询超时，请重试'),
          );
      return LocalTreePermission(
        persistedRead: res?['persistedRead'] == true,
        persistedWrite: res?['persistedWrite'] == true,
      );
    } catch (_) {
      // 查询失败时没有任何证据证明持久化读取权限存在，不能
      // 默认读为 true：两个字段都按未确认处理，finishLocalReauthorization
      // 会因 persistedRead 为 false 阻止重授权完成与删除重试。
      return const LocalTreePermission(
        persistedRead: false,
        persistedWrite: false,
      );
    }
  }

  /// SAF：重命名文档。返回新 URI 与 provider 确认的实际文件名。
  static Future<({String fileUri, String fileName, String sourceKey})>
  renameLocalDocument(String documentUri, String newFileName) async {
    final res = await channel.invokeMapMethod<String, dynamic>(
      'renameLocalDocument',
      {'docUri': documentUri, 'newFileName': newFileName},
    );
    final fileUri = res?['fileUri'] as String?;
    final fileName = res?['fileName'] as String?;
    if (fileUri == null || fileName == null) throw StateError('重命名文件失败');
    return (fileUri: fileUri, fileName: fileName, sourceKey: fileUri);
  }

  /// SAF：选择字体文件（TTF/OTF），复制到应用私有目录后返回绝对路径；取消返回 null。
  static Future<String?> pickFontFile() =>
      channel.invokeMethod<String>('pickFontFile');

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
