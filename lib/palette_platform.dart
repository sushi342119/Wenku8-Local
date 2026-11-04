import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_palette.dart';

class PalettePlatformInfo {
  const PalettePlatformInfo({
    this.colors,
    this.iconSupported = false,
    this.themedIcon = true,
  });
  final SystemTonalColors? colors;
  final bool iconSupported, themedIcon;
}

class PalettePlatform {
  const PalettePlatform();
  static const channel = MethodChannel('org.mewx.wenku8/palette');
  Future<PalettePlatformInfo> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const PalettePlatformInfo();
    }
    try {
      final map = await channel.invokeMapMethod<String, dynamic>('read');
      return PalettePlatformInfo(
        colors: SystemTonalColors.fromMap(map?['palettes']),
        iconSupported: map?['iconSupported'] == true,
        themedIcon: map?['themedIcon'] != false,
      );
    } on MissingPluginException {
      return const PalettePlatformInfo();
    }
  }

  Future<void> setThemedIcon(bool enabled) =>
      channel.invokeMethod<void>('icon', {'enabled': enabled});
}
