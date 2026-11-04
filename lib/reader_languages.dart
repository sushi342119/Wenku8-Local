String readerLanguageCode(String value) {
  final tag = value.trim().replaceAll('_', '-');
  if (!RegExp(r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8}){0,4}$').hasMatch(tag)) {
    return '';
  }
  return tag.split('-').first.toLowerCase();
}

String readerLanguageLabel(String code) =>
    const {
      'zh': '中文',
      'ja': '日文',
      'en': '英文',
      'ko': '韩文',
      'fr': '法文',
      'de': '德文',
      'ru': '俄文',
      'es': '西班牙文',
    }[code] ??
    code.toUpperCase();
