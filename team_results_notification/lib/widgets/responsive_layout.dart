import 'package:flutter/material.dart';

/// Breakpoints for responsive layout (mobile-first).
class ResponsiveBreakpoints {
  static const double phone = 600;
  static const double tablet = 1024;

  /// Screen width < 600px
  static bool isPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < phone;

  /// Screen width >= 600 and < 1024
  static bool isTablet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= phone && w < tablet;
  }

  /// Screen width >= 1024
  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= tablet;

  /// Screen width in px
  static double width(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  /// Screen height in px
  static double height(BuildContext context) =>
      MediaQuery.sizeOf(context).height;
}

/// Minimum touch target size per Material guidelines.
const double kMinTouchTargetSize = 44.0;

/// Widget that builds different layouts based on screen size.
class ResponsiveLayout extends StatelessWidget {
  final Widget phone;
  final Widget? tablet;
  final Widget? desktop;

  const ResponsiveLayout({
    super.key,
    required this.phone,
    this.tablet,
    this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    if (ResponsiveBreakpoints.isDesktop(context) && desktop != null) {
      return desktop!;
    }
    if (ResponsiveBreakpoints.isTablet(context) && tablet != null) {
      return tablet!;
    }
    return phone;
  }
}
