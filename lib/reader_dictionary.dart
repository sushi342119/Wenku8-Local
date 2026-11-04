import 'package:url_launcher/url_launcher.dart';

export 'dictionary_sheet.dart';
export 'dictionary_store.dart';
export 'reader_text_picker.dart';

Uri? readerDictionaryUri(String selectedText) {
  final query = selectedText.trim();
  return query.isEmpty
      ? null
      : Uri.https('dict.youdao.com', '/search', {'q': query});
}

/// Uses the installed browser capability; a rejected launch stays a failure.
Future<bool> launchReaderDictionary(
  String selectedText, {
  Future<bool> Function(LaunchMode mode)? supports,
  Future<bool> Function(Uri uri, LaunchMode mode)? launch,
}) async {
  final uri = readerDictionaryUri(selectedText);
  if (uri == null) return false;
  final embedded = await (supports ?? supportsLaunchMode)(
    LaunchMode.inAppBrowserView,
  );
  final mode = embedded
      ? LaunchMode.inAppBrowserView
      : LaunchMode.externalApplication;
  final open =
      launch ??
      ((Uri target, LaunchMode selectedMode) =>
          launchUrl(target, mode: selectedMode));
  return open(uri, mode);
}
