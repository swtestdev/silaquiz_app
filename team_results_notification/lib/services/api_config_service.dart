import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for resolving and persisting API/server configuration.
/// On web/PWA, the API base URL is derived from the page host (Tier 1).
class ApiConfigService {
  static const String _apiBaseUrlKey = 'api_base_url';
  static const String _apiConfigVersionKey = 'api_config_version';
  static const int apiPort = 8000;

  /// True when a new app version was detected on load; UI can show one-time message.
  static bool _configVersionUpgraded = false;
  static bool get wasConfigVersionUpgraded => _configVersionUpgraded;
  static void clearConfigVersionUpgradedFlag() {
    _configVersionUpgraded = false;
  }

  /// Default URL when no page host is available (local development).
  static const String defaultBaseUrl = 'http://localhost:8000/api';

  /// Optional override via `?api=http://host:8000/api` on the PWA URL.
  static String? apiOverrideFromQuery() {
    if (!kIsWeb) return null;
    final raw = Uri.base.queryParameters['api'];
    if (raw == null || raw.trim().isEmpty) return null;
    return normalizeApiBaseUrl(raw.trim());
  }

  /// Derive API URL from the host used to open the PWA (port 8080 page → port 8000 API).
  static String? deriveApiBaseUrlFromPageHost() {
    if (!kIsWeb) return null;

    final override = apiOverrideFromQuery();
    if (override != null) return override;

    final host = Uri.base.host.trim();
    if (host.isEmpty) return null;

    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '127.0.0.1' || lower == '::1') {
      return defaultBaseUrl;
    }

    return 'http://$host:$apiPort/api';
  }

  static String normalizeApiBaseUrl(String url) {
    var normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (!normalized.endsWith('/api')) {
      if (!normalized.contains('/api')) {
        normalized = '$normalized/api';
      }
    }
    return normalized;
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  static bool _hostsDiffer(String a, String b) {
    final ha = _hostOf(a);
    final hb = _hostOf(b);
    if (ha.isEmpty || hb.isEmpty) return false;
    return ha != hb;
  }

  /// Load the API base URL. Web LAN sessions always follow the page host.
  static Future<String> getApiBaseUrl() async {
    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    final derived = deriveApiBaseUrlFromPageHost();
    if (derived != null) {
      final saved = await _getApiBaseUrlOnce();
      if (saved == null ||
          saved == defaultBaseUrl ||
          _hostsDiffer(saved, derived)) {
        await setApiBaseUrl(derived);
        await _checkConfigVersionUpgrade();
        return derived;
      }
    }

    var url = await _getApiBaseUrlOnce();
    if (kIsWeb && url == defaultBaseUrl) {
      for (var i = 0; i < 3; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        url = await _getApiBaseUrlOnce();
        if (url != defaultBaseUrl) break;
      }
    }

    if (derived == null && url == defaultBaseUrl) {
      // Non-web or localhost page: keep saved/default.
    }

    await _checkConfigVersionUpgrade();
    return derived ?? url;
  }

  static Future<String> _getApiBaseUrlOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString(_apiBaseUrlKey);
      return url ?? defaultBaseUrl;
    } catch (e) {
      return defaultBaseUrl;
    }
  }

  static Future<void> _checkConfigVersionUpgrade() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedVersion = prefs.getString(_apiConfigVersionKey);
      final info = await PackageInfo.fromPlatform();
      final currentVersion = '${info.version}+${info.buildNumber}';
      if (storedVersion != null &&
          storedVersion.isNotEmpty &&
          storedVersion != currentVersion) {
        _configVersionUpgraded = true;
        await prefs.setString(_apiConfigVersionKey, currentVersion);
      }
    } catch (_) {
      // ignore
    }
  }

  /// Persist resolved API URL (used after auto-derive on web).
  static Future<void> setApiBaseUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_apiBaseUrlKey, normalizeApiBaseUrl(url));
      final info = await PackageInfo.fromPlatform();
      await prefs.setString(
        _apiConfigVersionKey,
        '${info.version}+${info.buildNumber}',
      );
    } catch (e) {
      // ignore persistence errors
    }
  }

  /// Check if a custom URL has ever been saved (vs using default).
  static Future<bool> hasSavedConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_apiBaseUrlKey);
    } catch (e) {
      return false;
    }
  }
}
