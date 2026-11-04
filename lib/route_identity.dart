import 'package:flutter/widgets.dart';

/// An event can read its existing route without subscribing the triggering page
/// to every later route-focus change. The route itself remains the authority.
class RouteIdentity extends InheritedWidget {
  const RouteIdentity({super.key, required this.route, required super.child});

  final ModalRoute<dynamic>? route;

  static ModalRoute<dynamic>? read(BuildContext context) {
    final route = context.getInheritedWidgetOfExactType<RouteIdentity>()?.route;
    // An embedded Navigator has its own routes; it must not borrow the outer
    // page's origin, slot ownership, or focus state.
    if (route != null && route.navigator == Navigator.maybeOf(context)) {
      return route;
    }
    return ModalRoute.of(context);
  }

  @override
  bool updateShouldNotify(RouteIdentity oldWidget) => route != oldWidget.route;
}
