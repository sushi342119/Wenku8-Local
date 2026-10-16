import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/listening/edge_tts.dart';
import 'package:wenku8_flutter/listening/models.dart';

void main() {
  test(
    'live Edge synthesizes a synthetic Chinese paragraph without a paid key',
    () async {
      HttpOverrides.global = null;
      Object? transportError;
      final client = EdgeSpeechClient(
        onTransportError: (error) {
          transportError = error;
        },
      );
      final voices = await client.voices();
      expect(voices.any((voice) => voice.id == defaultEdgeVoice.id), true);
      final bytes = await client
          .synthesize(
            '夜色渐深，微风翻过书页。这是一段中文朗读测试。',
            defaultEdgeVoice,
            SpeechCancellation(),
          )
          .catchError((Object error) {
            fail('$error; transport=$transportError');
          });
      expect(bytes.length, greaterThan(1000));
      if (const String.fromEnvironment('SPEECH_SAMPLE_PATH').isNotEmpty) {
        await File(
          const String.fromEnvironment('SPEECH_SAMPLE_PATH'),
        ).writeAsBytes(bytes);
      }
    },
    skip: !const bool.fromEnvironment('LIVE_EDGE_TTS'),
  );
}
