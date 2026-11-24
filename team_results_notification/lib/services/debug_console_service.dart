import 'package:flutter/foundation.dart';

/// Global debug console sink (enabled via `?debug=true` on web).
class DebugConsoleService {
  DebugConsoleService._();
  static final DebugConsoleService instance = DebugConsoleService._();

  bool enabled = false;
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  void addLog(String message) {
    if (!enabled) return;
    final next = List<String>.from(logs.value)..add(message);
    const maxLines = 300;
    if (next.length > maxLines) {
      next.removeRange(0, next.length - maxLines);
    }
    logs.value = next;
  }

  void clear() {
    logs.value = [];
  }
}
