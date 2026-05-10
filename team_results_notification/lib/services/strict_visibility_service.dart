import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// Web-only: PWA target. Non-web uses lifecycle only (doc + focus treated as always true).
import 'dart:html' as html show document, window;

/// Attention-based visibility for Quze: visible only when tab/page is visible **and**
/// window focused (web), and app lifecycle resumed.
class StrictVisibilityService extends WidgetsBindingObserver {
  StrictVisibilityService._();
  static final StrictVisibilityService instance = StrictVisibilityService._();

  final ValueNotifier<bool> strictVisible = ValueNotifier<bool>(true);

  bool _docVisible = true;
  bool _windowFocused = true;
  bool _lifecycleResumed = true;

  Timer? _debounceVisible;
  bool _initialized = false;

  /// Fired for audit / immediate echo: [reason] matches backend `visibility_reason` allowlist.
  void Function(String reason, bool appVisible)? onImmediateAuditPing;

  bool get isStrictVisible => strictVisible.value;

  void init({void Function(String reason, bool appVisible)? onImmediateAuditPing}) {
    if (_initialized) {
      if (onImmediateAuditPing != null) this.onImmediateAuditPing = onImmediateAuditPing;
      return;
    }
    _initialized = true;
    this.onImmediateAuditPing = onImmediateAuditPing;

    WidgetsBinding.instance.addObserver(this);

    if (kIsWeb) {
      _docVisible = html.document.visibilityState == 'visible';
      _windowFocused = true;

      html.document.addEventListener('visibilitychange', (Object? _) {
        final visible = html.document.visibilityState == 'visible';
        _docVisible = visible;
        if (!visible) {
          _cancelDebouncedVisible();
          _applyHidden('visibility_hidden');
        } else {
          _debounceTryBecomeVisible('visibility_visible');
        }
      });

      html.window.onBlur.listen((Object? _) {
        _windowFocused = false;
        _cancelDebouncedVisible();
        _applyHidden('blur');
      });

      html.window.onFocus.listen((Object? _) {
        _windowFocused = true;
        _debounceTryBecomeVisible('focus');
      });

      html.window.addEventListener('beforeunload', (Object? _) {
        onImmediateAuditPing?.call('beforeunload', false);
      });

      html.window.addEventListener('pagehide', (Object? _) {
        onImmediateAuditPing?.call('pagehide', false);
      });
    } else {
      _docVisible = true;
      _windowFocused = true;
    }

    _syncInitialStrict();
  }

  void _syncInitialStrict() {
    if (kIsWeb) {
      final v = _lifecycleResumed && _docVisible && _windowFocused;
      strictVisible.value = v;
    } else {
      strictVisible.value = _lifecycleResumed;
    }
  }

  void _cancelDebouncedVisible() {
    _debounceVisible?.cancel();
    _debounceVisible = null;
  }

  /// Not-visible wins immediately; becoming visible is debounced (strict reconciliation).
  void _debounceTryBecomeVisible(String reasonWhenVisible) {
    _cancelDebouncedVisible();
    _debounceVisible = Timer(const Duration(milliseconds: 220), () {
      if (kIsWeb) {
        if (_lifecycleResumed && _docVisible && _windowFocused) {
          if (!strictVisible.value) {
            strictVisible.value = true;
            onImmediateAuditPing?.call(reasonWhenVisible, true);
          }
        }
      } else {
        if (_lifecycleResumed && !strictVisible.value) {
          strictVisible.value = true;
          onImmediateAuditPing?.call(reasonWhenVisible, true);
        }
      }
    });
  }

  void _applyHidden(String reason) {
    strictVisible.value = false;
    onImmediateAuditPing?.call(reason, false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _lifecycleResumed = true;
        _debounceTryBecomeVisible('lifecycle_resumed');
        break;
      case AppLifecycleState.paused:
        _lifecycleResumed = false;
        _cancelDebouncedVisible();
        _applyHidden('lifecycle_paused');
        break;
      case AppLifecycleState.inactive:
        if (!kIsWeb) {
          _cancelDebouncedVisible();
          _applyHidden('lifecycle_inactive');
        }
        break;
      case AppLifecycleState.detached:
        _lifecycleResumed = false;
        _applyHidden('lifecycle_detached');
        break;
      case AppLifecycleState.hidden:
        if (!kIsWeb) {
          _cancelDebouncedVisible();
          _applyHidden('lifecycle_hidden');
        }
        break;
    }
  }
}
