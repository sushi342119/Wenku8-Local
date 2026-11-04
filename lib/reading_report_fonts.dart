import 'user_fonts.dart';

/// Reuse an installed face. Reports neither download fonts nor require one.
Future<String?> registeredReadingReportSerif(UserFontStore store) async {
  await store.load();
  for (final id in const ['sourceHanSerif', 'sourceHanSerifTW']) {
    if (!store.available(id)) continue;
    await store.ensureLoaded(id);
    if (store.isLoaded(id)) return store.family(id);
  }
  return null;
}
