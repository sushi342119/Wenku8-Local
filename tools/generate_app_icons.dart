// Compatibility entry point: flutter test tools/generate_app_icons.dart
// Install Pillow, then generate from the checked-in fox PNG.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('generate Shuyu Android icons', () async {
    final result = await Process.run('python3', ['tools/generate_app_icons.py']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
