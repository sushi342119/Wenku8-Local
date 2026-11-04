import '../reader_content.dart';
import '../reader_languages.dart';
import 'models.dart';

final _kana = RegExp(r'[\u3041-\u3096\u30a1-\u30fa\uff66-\uff9f]');
final _han = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');
final _hangul = RegExp(r'[\uac00-\ud7a3\u1100-\u11ff]');

/// Primary language matching tolerates ISO metadata emitted by Android engines.
String speechLanguageCode(String value) => switch (readerLanguageCode(value)) {
  'chi' || 'zho' => 'zh',
  'jpn' => 'ja',
  'eng' => 'en',
  'kor' => 'ko',
  final code => code,
};

/// Explicit publication metadata wins. Without it, a Japanese quotation inside
/// substantial Han prose does not change the language of the entire paragraph.
/// Han-only text keeps the selected voice because Chinese/Japanese share it.
String speechParagraphLanguage(String tag, String text, String fallback) {
  final explicit = speechLanguageCode(tag);
  if (explicit.isNotEmpty && explicit != 'und') return explicit;
  final kana = _kana.allMatches(text).length;
  if (kana > 0) {
    final han = _han.allMatches(text).length;
    if (han < 32 || kana * 10 >= han) return 'ja';
  }
  if (_hangul.hasMatch(text)) return 'ko';
  return speechLanguageCode(fallback);
}

List<SpeechSegment> speechWithLanguages(
  List<SpeechSegment> segments,
  ReaderContent content,
  SpeechVoice preferred,
) {
  final languages = <int, String>{};
  return List.unmodifiable([
    for (final part in segments)
      SpeechSegment(
        part.paragraph,
        part.start,
        part.end,
        part.text,
        language: languages.putIfAbsent(
          part.paragraph,
          () => speechParagraphLanguage(
            content.formats[part.paragraph]?.language ?? '',
            content.paragraphs[part.paragraph],
            preferred.locale,
          ),
        ),
      ),
  ]);
}

/// A language is never routed to another provider/engine or a different language.
/// Regional variants within the same language can use an installed model.
SpeechVoice? speechVoiceForLanguage(
  String language,
  SpeechVoice preferred,
  List<SpeechVoice> available, {
  SpeechVoice? selected,
}) {
  final code = speechLanguageCode(language);
  if (code.isEmpty) return null;
  final matches = available
      .where(
        (voice) =>
            voice.availableForListening &&
            voice.source == preferred.source &&
            voice.engine == preferred.engine &&
            speechLanguageCode(voice.locale) == code &&
            voice.id != '@default',
      )
      .toList();
  if (matches.isEmpty) return null;
  if (selected != null) {
    if (selected.source != preferred.source ||
        selected.engine != preferred.engine ||
        speechLanguageCode(selected.locale) != code) {
      return null;
    }
    for (final voice in matches) {
      if (voice.id == selected.id) return voice;
    }
    // An explicitly selected missing model must not be replaced by another voice.
    return null;
  }
  matches.sort((a, b) {
    final aPreferred = a.id == preferred.id;
    final bPreferred = b.id == preferred.id;
    if (aPreferred != bPreferred) return aPreferred ? -1 : 1;
    if (a.offline != b.offline) return a.offline ? -1 : 1;
    final quality = b.quality.compareTo(a.quality);
    return quality != 0 ? quality : a.id.compareTo(b.id);
  });
  return matches.first;
}
