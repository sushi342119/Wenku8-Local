import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wenku8_flutter/wenku_errors.dart';

void main() {
  test('扫描失败详情只返回固定类别文案，不带路径或 URI', () {
    // 受控 FormatException 原样返回。
    expect(describeLocalScanError(const FormatException('TXT 文件为空')),
        'TXT 文件为空');
    expect(describeLocalScanError(const FormatException('TXT 解码失败')),
        'TXT 解码失败');
    expect(
        describeLocalScanError(
            const FormatException('TXT 文件过大：超过 256 MiB 导入上限')),
        contains('文件过大'));
    // 非受控 FormatException 归为解码失败，不带原文。
    expect(
        describeLocalScanError(
            const FormatException('Unexpected extension byte (at offset 3)')),
        '解码失败');
    // FileSystemException 一律归为文件不可读，不带路径或 osError。
    expect(
        describeLocalScanError(const FileSystemException(
            'denied', '/abs/x/0.txt', OSError('Permission denied', 13))),
        '文件不可读');
    // 其他类型归为扫描失败，不带原文（含路径、URI 的也不带）。
    expect(describeLocalScanError(StateError('/abs/x/0.txt')), '扫描失败');
    expect(
        describeLocalScanError(Exception('content://a/b')), '扫描失败');
  });
}
