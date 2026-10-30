import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _recoveryFailures = <String, String>{};

Map<String, String> get recoveryFailures => Map.unmodifiable(_recoveryFailures);

void recordRecoveryFailure(String operation, Object error) {
  final message = '${error.runtimeType}: 恢复未完成，原记录已保留待重试';
  _recoveryFailures[operation] = message;
  debugPrint('$operation: $message');
}

Future<void> archiveRecoveryRecord(
  SharedPreferences prefs,
  String key,
  Object raw, {
  required String reason,
  Map<String, Object?>? details,
}) async {
  try {
    final previous = prefs.get(key);
    final records = previous is List<String>
        ? List<String>.of(previous)
        : <String>[
            if (previous != null)
              jsonEncode({'raw': previous, 'reason': 'invalid_archive'}),
          ];
    records.add(
      jsonEncode({
        'raw': raw,
        'reason': reason,
        'details': ?details,
        'archivedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    if (!await prefs.setStringList(key, records)) {
      throw StateError('恢复记录隔离失败：$key');
    }
    _recoveryFailures.remove(key);
  } catch (error) {
    recordRecoveryFailure(key, error);
    rethrow;
  }
}
