import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/listening/audio_output.dart';

void main() {
  test('runtime notification icon has a matching release keep rule', () {
    final parts = listeningAndroidNotificationIcon.split('/');
    expect(parts, hasLength(2));
    expect(parts.first, 'drawable');
    final icon = File(
      'android/app/src/main/res/${parts.first}/${parts.last}.xml',
    );
    expect(icon.existsSync(), isTrue);
    expect(icon.readAsStringSync(), contains('<vector'));

    final rules = File(
      'android/app/src/main/res/raw/listening_keep.xml',
    ).readAsStringSync();
    final keep = RegExp(r'tools:keep="([^"]+)"').firstMatch(rules);
    expect(keep, isNotNull);
    expect(
      keep!.group(1)!.split(',').map((value) => value.trim()),
      contains('@$listeningAndroidNotificationIcon'),
    );
  });
}
