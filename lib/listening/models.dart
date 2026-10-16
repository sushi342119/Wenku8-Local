import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../reader_content.dart';

enum ListeningSource { edge, system }

enum ListeningPhase { stopped, preparing, playing, paused, completed, failed }

class SpeechVoice {
  const SpeechVoice({
    required this.id,
    required this.label,
    required this.source,
    this.locale = 'zh-CN',
    this.engine,
    this.offline = false,
    this.quality = 0,
  });
  final String id, label, locale;
  final ListeningSource source;
  final String? engine;
  final bool offline;
  final int quality;
  bool get supported =>
      source != ListeningSource.system ||
      (offline && supportedSystemSpeechEngine(engine));
  // Offline engine plumbing is retained for development, not offered as a
  // working product feature until device coverage and synthesis are ready.
  bool get availableForListening => source == ListeningSource.edge && supported;
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'source': source.name,
    'locale': locale,
    'engine': engine,
    'offline': offline,
    'quality': quality,
  };
  factory SpeechVoice.fromJson(Map<String, dynamic> json) => SpeechVoice(
    id: json['id'] as String,
    label: json['label'] as String,
    source: json['source'] == 'system'
        ? ListeningSource.system
        : ListeningSource.edge,
    locale: json['locale'] is String ? json['locale'] : 'zh-CN',
    engine: json['engine'] as String?,
    offline: json['offline'] == true,
    quality: json['quality'] is int ? json['quality'] : 0,
  );
}

const defaultEdgeVoice = SpeechVoice(
  id: 'zh-CN-XiaoxiaoNeural',
  label: '晓晓 · 中文女声',
  source: ListeningSource.edge,
);
const alternateEdgeVoice = SpeechVoice(
  id: 'zh-CN-YunxiNeural',
  label: '云希 · 中文男声',
  source: ListeningSource.edge,
);

/// Retire the previous vendor integration, including persisted selections.
/// Other installed engines continue to use the public Android TTS contract.
bool supportedSystemSpeechEngine(String? engine) =>
    engine != null &&
    engine.isNotEmpty &&
    !const ['com.oplus.', 'com.oppo.', 'com.heytap.'].any(engine.startsWith);

/// Normalize ISO Chinese metadata without changing the native voice ID.
String? chineseSpeechLocale(String value) {
  final parts = value.trim().replaceAll('_', '-').split('-');
  if (parts.any((part) => part.isEmpty) ||
      !const {'zh', 'chi', 'zho'}.contains(parts.first.toLowerCase())) {
    return null;
  }
  if (parts.length == 1) return 'zh-CN';
  return [
    'zh',
    for (final part in parts.skip(1))
      if (part.length == 4)
        '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}'
      else if (part.length == 2)
        part.toUpperCase()
      else
        part,
  ].join('-');
}

class SpeechSegment {
  const SpeechSegment(this.paragraph, this.start, this.end, this.text);
  final int paragraph, start, end;
  final String text;
  String key(SpeechVoice voice) => sha256
      .convert(
        utf8.encode(
          'speech-v1|${voice.source.name}|${voice.engine}|${voice.id}|$text',
        ),
      )
      .toString();
}

final _speechLetters = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Keep UTF-16 offsets intact while removing characters that speech engines
/// reject. This changes the synthesis copy, never the reader's original text.
String speechText(String text) {
  final clean = StringBuffer();
  for (final rune in text.runes) {
    final xml =
        rune == 9 ||
        rune == 10 ||
        rune == 13 ||
        (rune >= 0x20 && rune <= 0xD7FF) ||
        (rune >= 0xE000 && rune <= 0xFFFD) ||
        (rune >= 0x10000 && rune <= 0x10FFFF);
    final invisible =
        (rune >= 0x7F && rune <= 0x9F) ||
        (rune >= 0x200B && rune <= 0x200F) ||
        (rune >= 0x202A && rune <= 0x202E) ||
        (rune >= 0x2060 && rune <= 0x2069) ||
        rune == 0xFEFF ||
        rune == 0xFFFD ||
        (rune >= 0xFDD0 && rune <= 0xFDEF) ||
        (rune & 0xFFFF) >= 0xFFFE;
    if (!xml || invisible) {
      clean.write(rune > 0xFFFF ? '  ' : ' ');
    } else {
      clean.writeCharCode(rune);
    }
  }
  return clean.toString();
}

bool hasSpeechText(String text) => _speechLetters.hasMatch(speechText(text));

/// A rejected long input gets one smaller-clause pass before anything is
/// skipped. Parts remain on the original paragraph and selection offsets.
List<SpeechSegment> speechRecoverySegments(SpeechSegment segment) {
  if (segment.text.length <= 100) return [segment];
  return [
    for (final part in speechSegments([segment.text], maximum: 80))
      SpeechSegment(
        segment.paragraph,
        segment.start + part.start,
        segment.start + part.end,
        part.text,
      ),
  ];
}

/// Original UTF-16 offsets remain valid for selection; paired illustration markers are never spoken.
List<SpeechSegment> speechSegments(
  List<String> paragraphs, {
  int maximum = 240,
}) {
  if (maximum < 20 || maximum > 1000) {
    throw ArgumentError.value(maximum, 'maximum');
  }
  final result = <SpeechSegment>[];
  for (var index = 0; index < paragraphs.length; index++) {
    final text = paragraphs[index];
    final trimmed = text.trim();
    if (readerIllustrationUrl(text) != null ||
        trimmed.isEmpty ||
        trimmed == '[插图]' ||
        (trimmed.startsWith('<!--image-->') &&
            trimmed.endsWith('<!--image-->'))) {
      continue;
    }
    var offset = 0;
    while (offset < text.length) {
      while (offset < text.length && text[offset].trim().isEmpty) {
        offset++;
      }
      if (offset >= text.length) break;
      var end = (offset + maximum).clamp(0, text.length);
      if (end < text.length) {
        // Keep surrogate pairs intact and prefer a complete clause over a chopped phrase.
        if (end > offset &&
            text.codeUnitAt(end - 1) >= 0xD800 &&
            text.codeUnitAt(end - 1) <= 0xDBFF) {
          end--;
        }
        final window = text.substring(offset, end);
        final breaks = RegExp(r'[。！？!?；;\n]').allMatches(window).toList();
        if (breaks.isNotEmpty && breaks.last.end >= maximum ~/ 3) {
          end = offset + breaks.last.end;
        } else {
          // A long sentence should pause at a clause or word boundary instead
          // of restarting the voice in the middle of a phrase, number or name.
          final clauses = RegExp(r'[，,：:、\s]').allMatches(window).where((m) {
            if (m.end < maximum ~/ 2) return false;
            final at = offset + m.start;
            final comma = text[at] == ',' || text[at] == '，';
            bool digit(int index) =>
                index >= 0 &&
                index < text.length &&
                text.codeUnitAt(index) >= 48 &&
                text.codeUnitAt(index) <= 57;
            return !comma || !(digit(at - 1) && digit(at + 1));
          }).toList();
          if (clauses.isNotEmpty) end = offset + clauses.last.end;
        }
        while (end < text.length &&
            end < offset + maximum + 4 &&
            '」』”’'.contains(text[end])) {
          end++;
        }
      }
      final fragment = speechText(text.substring(offset, end));
      if (_speechLetters.hasMatch(fragment)) {
        result.add(SpeechSegment(index, offset, end, fragment));
      }
      offset = end;
    }
  }
  return List.unmodifiable(result);
}

class SpeechCancelled implements Exception {
  const SpeechCancelled();
}

enum SpeechFailureKind { unavailable, content, timeout }

class SpeechFailure implements Exception {
  const SpeechFailure(
    this.message, {
    this.kind = SpeechFailureKind.unavailable,
  });
  final String message;
  final SpeechFailureKind kind;
  bool get recoverable => kind != SpeechFailureKind.unavailable;
  @override
  String toString() => message;
}

class SpeechCancellation {
  bool _cancelled = false;
  final List<void Function()> _handlers = [];
  bool get cancelled => _cancelled;
  void check() {
    if (_cancelled) throw const SpeechCancelled();
  }

  void Function() onCancel(void Function() handler) {
    if (_cancelled) {
      handler();
    } else {
      _handlers.add(handler);
    }
    return () => _handlers.remove(handler);
  }

  /// A cancelled seek must not wait for a stuck vendor/network Future. The
  /// original Future retains an error handler even if it finishes much later.
  Future<T> wait<T>(Future<T> future) {
    final result = Completer<T>();
    final remove = onCancel(() {
      if (!result.isCompleted) result.completeError(const SpeechCancelled());
    });
    future.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future.whenComplete(remove);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final handler in List.of(_handlers)) {
      handler();
    }
    _handlers.clear();
  }
}

class ListeningCursor {
  const ListeningCursor({
    required this.novelId,
    required this.chapterId,
    required this.chapter,
    required this.paragraph,
    required this.start,
    required this.positionMs,
    required this.segmentHash,
  });
  final int novelId, chapterId, chapter, paragraph, start, positionMs;
  final String segmentHash;
  Map<String, Object> toJson() => {
    'novelId': novelId,
    'chapterId': chapterId,
    'chapter': chapter,
    'paragraph': paragraph,
    'start': start,
    'positionMs': positionMs,
    'segmentHash': segmentHash,
  };
  factory ListeningCursor.fromJson(Map<String, dynamic> json) {
    int number(String key) =>
        json[key] is int ? (json[key] as int).clamp(0, 1 << 30) : 0;
    return ListeningCursor(
      novelId: number('novelId'),
      chapterId: number('chapterId'),
      chapter: number('chapter'),
      paragraph: number('paragraph'),
      start: number('start'),
      positionMs: number('positionMs'),
      segmentHash: json['segmentHash'] is String ? json['segmentHash'] : '',
    );
  }
}
