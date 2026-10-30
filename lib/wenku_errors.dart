import 'dart:io';

import 'package:flutter/foundation.dart';

/// 匿名接口的错误类型。
///
/// 账号体系（登录、云书架、签到、书评）已移除，这里仅保留匿名请求
/// 仍可能用到的错误表达：接口返回码与通用错误描述。
class WenkuApiError implements Exception {
  const WenkuApiError(this.code);
  final int code;
  String get message => '服务器未完成本次操作，请稍后重试';
  @override
  String toString() => message;
}

int? wenkuResponseCode(String source) => int.tryParse(source.trim());

String describeWenkuError(Object error) => error is WenkuApiError
    ? error.message
    : describeSafeError(error, fallback: '网络或本地存储暂时异常，请重试');

/// Returns a short diagnostic without embedding exception text, paths or URIs.
String describeSafeError(Object error, {String fallback = '操作失败，请重试'}) =>
    kDebugMode ? '${error.runtimeType}: $fallback' : fallback;

const _scanDetailEmpty = '文件为空';
const _scanDetailDecodeFailed = '解码失败';
const _scanDetailTooLarge = '文件过大';
const _scanDetailUnreadable = '文件不可读';
const _scanDetailFailed = '扫描失败';

/// 扫描失败详情只返回固定类别文案，不带异常原文、路径或 URI。
String describeLocalScanError(Object error) {
  if (error is FormatException) {
    final message = error.message;
    if (message.startsWith('TXT ') ||
        message == _scanDetailEmpty ||
        message == _scanDetailDecodeFailed ||
        message == _scanDetailTooLarge) {
      return message;
    }
    return _scanDetailDecodeFailed;
  }
  if (error is FileSystemException) return _scanDetailUnreadable;
  return _scanDetailFailed;
}
