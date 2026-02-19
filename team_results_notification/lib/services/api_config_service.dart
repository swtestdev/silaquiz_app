import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for persisting and retrieving API/server configuration.
/// Used for runtime config of the backend API base URL.
class ApiConfigService {
  static const String _apiBaseUrlKey = 'api_base_url';
  static const String _apiConfigVersionKey = 'api_config_version';

  /// True when a new app version was detected on load; UI can show one-time message.
  static bool _configVersionUpgraded = false;
  static bool get wasConfigVersionUpgraded => _configVersionUpgraded;
  static void clearConfigVersionUpgradedFlag() {
    _configVersionUpgraded = false;
  }

  /// Default URL when no saved config exists (local development).
  static const String defaultBaseUrl = 'http://localhost:8000/api';

  /// Load the saved API base URL, or default if none saved.
  /// On web, adds retries with delays (localStorage may not be ready immediately on load).
  /// Sets wasConfigVersionUpgraded if stored config was from an older app version.
  static Future<String> getApiBaseUrl() async {
    // On web, give storage time to hydrate before first read
    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    var url = await _getApiBaseUrlOnce();
    // On web, retry up to 3 times if we get default (storage timing)
    if (kIsWeb && url == defaultBaseUrl) {
      for (var i = 0; i < 3; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        url = await _getApiBaseUrlOnce();
        if (url != defaultBaseUrl) break;
      }
    }
    await _checkConfigVersionUpgrade();
    return url;
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

  /// Save the API base URL and current app version.
  static Future<void> setApiBaseUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_apiBaseUrlKey, url);
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
