import 'package:flutter/material.dart';

/// Compatibility scope for existing navigation wrappers. Controls keep their
/// established glass material in both scopes.
class ControlMaterialScope extends InheritedTheme {
  const ControlMaterialScope.chrome({super.key, required super.child})
    : chrome = true;
  const ControlMaterialScope.page({super.key, required super.child})
    : chrome = false;

  final bool chrome;

  static bool isChromeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ControlMaterialScope>()
          ?.chrome ??
      false;

  @override
  Widget wrap(BuildContext context, Widget child) => chrome
      ? ControlMaterialScope.chrome(child: child)
      : ControlMaterialScope.page(child: child);

  @override
  bool updateShouldNotify(ControlMaterialScope oldWidget) =>
      chrome != oldWidget.chrome;
}

/// Only the three main-page bodies opt into smaller control faces. This is not
/// an InheritedTheme, so menus and sheets retain their normal control sizing.
class CompactMainPageControls extends InheritedWidget {
  const CompactMainPageControls({
    super.key,
    required super.child,
    this.enabled = false,
  });

  final bool enabled;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CompactMainPageControls>()
          ?.enabled ??
      false;

  @override
  bool updateShouldNotify(CompactMainPageControls oldWidget) =>
      enabled != oldWidget.enabled;
}
