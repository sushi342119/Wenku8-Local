import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Wenku8 Flutter',
    ], await rootBundle.loadString('assets/licenses/GPL-3.0.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Source Han Serif CN · Adobe',
    ], await rootBundle.loadString('assets/fonts/OFL-SourceHanSerif.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'edge-tts protocol · rany',
    ], await rootBundle.loadString('assets/licenses/edge-tts.txt'));
  });
}
