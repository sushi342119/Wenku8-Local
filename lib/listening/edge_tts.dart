import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'edge_protocol.dart';
import 'models.dart';

/// Wire interoperability follows rany2/edge-tts; no account, subscription or private API key.
class EdgeSpeechClient {
  EdgeSpeechClient({this.onTransportError});
  final void Function(Object error)? onTransportError;
  static const host = 'speech.platform.bing.com';
  static const route = '/consumer/speech/synthesize/readaloud';
  static const publicClientIdentifier = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const clientVersion = '143.0.3650.75';
  Duration _clockSkew = Duration.zero;
  List<SpeechVoice>? _voices;
  DateTime? _voicesLoaded;

  static String connectionId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String timeProof(DateTime now) => EdgeProtocol.timeProof(now);

  static String escapeXml(String source) => source
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static String timestamp(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = date.toUtc();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${months[d.month - 1]} ${pad(d.day)} ${d.year} '
        '${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static Map<String, String> get headers => {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
    'Accept-Language': 'en-US,en;q=0.9',
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    'Cookie': 'muid=${connectionId().toUpperCase()};',
  };

  Future<List<SpeechVoice>> voices({bool refresh = false}) async {
    if (!refresh &&
        _voices != null &&
        DateTime.now().difference(_voicesLoaded!) < const Duration(hours: 24)) {
      return _voices!;
    }
    final client = HttpClient()
      ..userAgent = null
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.https(host, '$route/voices/list', {
          'trustedclienttoken': publicClientIdentifier,
        }),
      );
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final date = response.headers.value(HttpHeaders.dateHeader);
      if (date != null) {
        try {
          _clockSkew = HttpDate.parse(date).difference(DateTime.now().toUtc());
        } catch (_) {}
      }
      if (response.statusCode != 200) {
        throw const SpeechFailure('在线音色列表暂未连接，可使用已有在线音色或稍后重试');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        bytes.add(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const SpeechFailure('在线音色列表过大');
        }
      }
      final json = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (json is! List) throw const SpeechFailure('在线音色列表格式发生变化');
      final voices = <SpeechVoice>[];
      for (final item in json) {
        if (item is! Map ||
            item['ShortName'] is! String ||
            item['Locale'] is! String) {
          continue;
        }
        final id = item['ShortName'] as String,
            locale = item['Locale'] as String;
        if (!locale.startsWith('zh-') ||
            !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
          continue;
        }
        final known = id == defaultEdgeVoice.id
            ? defaultEdgeVoice.label
            : id == alternateEdgeVoice.id
            ? alternateEdgeVoice.label
            : null;
        final gender = item['Gender'] == 'Female' ? '女声' : '男声';
        voices.add(
          SpeechVoice(
            id: id,
            label: known ?? '${item['FriendlyName'] ?? id} · $gender',
            source: ListeningSource.edge,
            locale: locale,
          ),
        );
      }
      _voices = List.unmodifiable(voices);
      _voicesLoaded = DateTime.now();
      return _voices!;
    } on SpeechFailure {
      rethrow;
    } catch (_) {
      throw const SpeechFailure('在线音色列表连接失败，可继续使用已有音色');
    } finally {
      client.close(force: true);
    }
  }

  static ({String path, Uint8List audio}) binaryAudio(List<int> data) {
    if (data.length < 2) throw const SpeechFailure('在线语音返回了不完整的数据');
    final length = (data[0] << 8) | data[1];
    if (length <= 0 || length + 2 > data.length) {
      throw const SpeechFailure('在线语音数据头无效');
    }
    final header = utf8.decode(
      data.sublist(2, length + 2),
      allowMalformed: false,
    );
    final path =
        RegExp(r'(?:^|\r\n)Path:([^\r\n]+)').firstMatch(header)?.group(1) ?? '';
    return (path: path, audio: Uint8List.fromList(data.sublist(length + 2)));
  }

  Future<Uint8List> synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation,
  ) => _synthesize(text, voice, cancellation, retryClock: true);

  Future<Uint8List> _synthesize(
    String text,
    SpeechVoice voice,
    SpeechCancellation cancellation, {
    required bool retryClock,
  }) async {
    text = speechText(text);
    if (!RegExp(
          r'^zh-(?:[A-Za-z0-9]+-)+[A-Za-z0-9]+Neural$',
        ).hasMatch(voice.id) ||
        voice.id.length > 120 ||
        voice.locale.length > 40 ||
        !RegExp(r'^zh-[A-Za-z-]+$').hasMatch(voice.locale)) {
      throw const SpeechFailure('在线朗读音色无效，请重新选择音色');
    }
    if (!hasSpeechText(text) || utf8.encode(escapeXml(text)).length > 3500) {
      throw const SpeechFailure('这一段没有可朗读的文本', kind: SpeechFailureKind.content);
    }
    cancellation.check();
    final client = HttpClient()
      // WebSocket.connect adds rather than replaces headers. Without clearing
      // the default UA, Dart's UA is prepended and the Edge upgrade gets 403.
      ..userAgent = null
      ..connectionTimeout = const Duration(seconds: 10);
    WebSocket? socket;
    final removeCancellation = cancellation.onCancel(() {
      unawaited(socket?.close() ?? Future.value());
      client.close(force: true);
    });
    try {
      final now = DateTime.now().toUtc().add(_clockSkew);
      final uri = Uri(
        scheme: 'wss',
        host: host,
        port: 443,
        path: '$route/edge/v1',
        queryParameters: {
          'TrustedClientToken': publicClientIdentifier,
          'ConnectionId': connectionId(),
          'Sec-MS-GEC': timeProof(now),
          'Sec-MS-GEC-Version': EdgeProtocol.version,
        },
      );
      socket = await WebSocket.connect(
        uri.toString(),
        headers: headers,
        customClient: client,
      ).timeout(const Duration(seconds: 12));
      cancellation.check();
      socket.add(
        'X-Timestamp:${timestamp(now)}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      final ssml =
          '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${voice.locale}">'
          '<voice name="${voice.id}"><prosody pitch="+0Hz" rate="+0%" volume="+0%">${escapeXml(text)}</prosody></voice></speak>';
      socket.add(
        'X-RequestId:${connectionId()}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${timestamp(now)}Z\r\nPath:ssml\r\n\r\n$ssml',
      );
      final audio = BytesBuilder(copy: false);
      var ended = false;
      await for (final event in socket.timeout(const Duration(seconds: 25))) {
        cancellation.check();
        if (event is List<int>) {
          final frame = binaryAudio(event);
          if (frame.path != 'audio') {
            throw const SpeechFailure('在线语音返回了未知的数据类型');
          }
          audio.add(frame.audio);
          if (audio.length > 8 * 1024 * 1024) {
            throw const SpeechFailure('单段语音超过缓存上限');
          }
        } else if (event is String &&
            RegExp(r'(?:^|\r\n)Path:turn.end(?:\r\n|$)').hasMatch(event)) {
          ended = true;
          break;
        }
      }
      cancellation.check();
      if (!ended) {
        throw const SpeechFailure('在线音源未完成这一段，请检查网络后重试，或换一个在线音色');
      }
      if (audio.length < 100) {
        throw const SpeechFailure(
          '在线音源未生成这一段的语音',
          kind: SpeechFailureKind.content,
        );
      }
      return audio.takeBytes();
    } on SpeechCancelled {
      rethrow;
    } on SpeechFailure {
      rethrow;
    } on WebSocketException catch (error) {
      cancellation.check();
      onTransportError?.call(error);
      if (retryClock && error.message.contains('403')) {
        try {
          await voices(refresh: true);
        } catch (_) {
          cancellation.check();
        }
        cancellation.check();
        return _synthesize(text, voice, cancellation, retryClock: false);
      }
      throw const SpeechFailure('在线音源连接失败，请检查网络后重试，或换一个在线音色');
    } catch (error) {
      cancellation.check();
      onTransportError?.call(error);
      throw const SpeechFailure('在线音源连接失败，请检查网络后重试，或换一个在线音色');
    } finally {
      removeCancellation();
      client.close(force: true);
      try {
        await socket?.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        /* The completed turn must not wait indefinitely for a close handshake. */
      }
    }
  }
}
