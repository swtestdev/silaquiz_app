import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../utils/browser/browser.dart';

/// Attention-based visibility for Quze: visible only when tab/page is visible **and**
/// window focused (web), app lifecycle resumed, and WebSocket connected (players).
class StrictVisibilityService extends WidgetsBindingObserver {
  StrictVisibilityService._();
  static final StrictVisibilityService instance = StrictVisibilityService._();

  final ValueNotifier<bool> strictVisible = ValueNotifier<bool>(true);
  final ValueNotifier<bool> effectiveVisible = ValueNotifier<bool>(true);

  bool _docVisible = true;
  bool _windowFocused = true;
  bool _lifecycleResumed = true;
  bool _webSocketConnected = true;

  Timer? _debounceVisible;
  bool _initialized = false;

  /// Fired for audit / immediate echo: [reason] matches backend `visibility_reason` allowlist.
  void Function(String reason, bool appVisible)? onImmediateAuditPing;

  /// Attention-only (tab/focus/lifecycle). Use for ECHO and admin APP tracking.
  bool get isStrictVisible => strictVisible.value;

  /// Legacy: attention + WebSocket. Not used for admin visibility matrix.
  bool get isEffectivelyVisible => effectiveVisible.value;

  void init({void Function(String reason, bool appVisible)? onImmediateAuditPing}) {
    if (_initialized) {
      if (onImmediateAuditPing != null) this.onImmediateAuditPing = onImmediateAuditPing;
      return;
    }
    _initialized = true;
    this.onImmediateAuditPing = onImmediateAuditPing;

    WidgetsBinding.instance.addObserver(this);
    strictVisible.addListener(_syncEffectiveVisible);

    if (kIsWeb) {
      _docVisible = initStrictVisibilityWeb(
        StrictVisibilityWebCallbacks(
          onDocumentVisibilityChange: (visible) {
            _docVisible = visible;
            if (!visible) {
              _cancelDebouncedVisible();
              _applyHidden('visibility_hidden');
            } else {
              _debounceTryBecomeVisible('visibility_visible');
            }
          },
          onWindowBlur: () {
            _windowFocused = false;
            _cancelDebouncedVisible();
            _applyHidden('blur');
          },
          onWindowFocus: () {
            _windowFocused = true;
            _debounceTryBecomeVisible('focus');
          },
          onBeforeUnload: () {
            onImmediateAuditPing?.call('beforeunload', false);
          },
          onPageHide: () {
            onImmediateAuditPing?.call('pagehide', false);
          },
        ),
      );
      _windowFocused = true;
    } else {
      _docVisible = true;
      _windowFocused = true;
    }

    _syncInitialStrict();
    _syncEffectiveVisible();
  }

  /// WebSocket status is tracked separately; it must not flip admin visibility.
  void setWebSocketConnected(bool connected) {
    if (_webSocketConnected == connected) return;
    _webSocketConnected = connected;
    if (!connected) {
      _cancelDebouncedVisible();
    }
    _syncEffectiveVisible();
  }

  bool get _attentionVisible {
    if (kIsWeb) {
      return _lifecycleResumed && _docVisible && _windowFocused;
    }
    return _lifecycleResumed;
  }

  void _syncInitialStrict() {
    strictVisible.value = _attentionVisible;
  }

  void _syncEffectiveVisible() {
    effectiveVisible.value = strictVisible.value && _webSocketConnected;
  }

  void _cancelDebouncedVisible() {
    _debounceVisible?.cancel();
    _debounceVisible = null;
  }

  /// Not-visible wins immediately; becoming visible is debounced (strict reconciliation).
  void _debounceTryBecomeVisible(String reasonWhenVisible) {
    _cancelDebouncedVisible();
    _debounceVisible = Timer(const Duration(milliseconds: 220), () {
      if (_attentionVisible) {
        if (!strictVisible.value) {
          strictVisible.value = true;
          onImmediateAuditPing?.call(reasonWhenVisible, true);
        } else if (_attentionVisible) {
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
