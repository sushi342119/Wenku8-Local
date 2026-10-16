import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Speech preferences/cursors are separate from reading anchors and existing backup schema.
class ListeningStore {
  ListeningStore(this.preferences);
  final SharedPreferences preferences;
  Future<void> _writes = Future.value();
  Future<void> _write(Future<bool> Function() action, String message) {
    final next = _writes.then((_) async {
      if (!await action()) throw SpeechFailure(message);
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  SpeechVoice get voice {
    try {
      final raw = preferences.getString('listening.voice.v1');
      if (raw != null) {
        final voice = SpeechVoice.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        return voice.availableForListening ? voice : defaultEdgeVoice;
      }
    } catch (_) {
      /* Keep a damaged speech setting isolated from the reading library. */
    }
    return defaultEdgeVoice;
  }

  double get speed =>
      (preferences.getDouble('listening.speed.v1') ?? 1).clamp(.75, 2);
  bool get follow => preferences.getBool('listening.follow.v1') ?? true;
  Future<void> saveVoice(SpeechVoice voice) {
    if (!voice.availableForListening) {
      return Future.error(const SpeechFailure('系统离线语音待开发，请使用自然在线音色'));
    }
    return _write(
      () => preferences.setString(
        'listening.voice.v1',
        jsonEncode(voice.toJson()),
      ),
      '音色设置保存失败',
    );
  }

  Future<void> saveSpeed(double value) => _write(
    () => preferences.setDouble('listening.speed.v1', value.clamp(.75, 2)),
    '语速设置保存失败',
  );
  Future<void> saveFollow(bool value) => _write(
    () => preferences.setBool('listening.follow.v1', value),
    '跟读设置保存失败',
  );
  ListeningCursor? cursor(int novelId) {
    try {
      final raw = preferences.getString('listening.cursor.v1.$novelId');
      return raw == null
          ? null
          : ListeningCursor.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCursor(ListeningCursor cursor) => _write(
    () => preferences.setString(
      'listening.cursor.v1.${cursor.novelId}',
      jsonEncode(cursor.toJson()),
    ),
    '续听位置保存失败',
  );
}
