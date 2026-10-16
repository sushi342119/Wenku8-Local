import 'dart:async';

import 'package:flutter/material.dart';

import 'app_ui.dart';

final _routeSlots = Expando<Set<Object>>('novel-route-slots');

/// The slot belongs to one Navigator, not the app. Different destinations can
/// nest normally; repeated activation of the same destination opens one route.
Future<T?> pushNovelPage<T>(
  BuildContext context,
  Widget page, {
  required bool reduceMotion,
  Object? slot,
  bool paperFlight = false,
}) async {
  if (!context.mounted) return null;
  final navigator = Navigator.of(context);
  final slots = _routeSlots[navigator] ??= <Object>{};
  final key = slot ?? page.runtimeType;
  if (!slots.add(key)) return null;
  final route = softRoute<T>(
    page,
    reduceMotion: reduceMotion || MediaQuery.disableAnimationsOf(context),
    paperFlight: paperFlight,
  );
  try {
    final result = await navigator.push(route);
    await route.completed;
    return result;
  } finally {
    slots.remove(key);
  }
}

/// Latest feedback replaces stale queued messages. Async undo errors have one
/// consistent recovery path, and actions stay usable with accessibility text.
void showNovelFeedback(
  BuildContext context,
  String message, {
  String? actionLabel,
  FutureOr<void> Function()? action,
  String actionFailure = '操作保存失败，请重试',
}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: actionLabel == null || action == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                onPressed: () async {
                  try {
                    await action();
                  } catch (_) {
                    if (context.mounted) {
                      showNovelFeedback(context, actionFailure);
                    }
                  }
                },
              ),
      ),
    );
}
