/// User-facing copy when the app signs the player out automatically.
enum LogoutReason {
  sessionTakenElsewhere,
  sessionExpired,
  signedOut,
}

class LogoutNotice {
  LogoutNotice._();

  static LogoutReason? reasonFromBackendMessage(String? message, {String? logoutReason}) {
    if (logoutReason == 'session_superseded') {
      return LogoutReason.sessionTakenElsewhere;
    }
    if (message == null || message.isEmpty) return null;
    final lower = message.toLowerCase();
    if (lower.contains('session token mismatch') ||
        lower.contains('another device') ||
        lower.contains('logged in elsewhere') ||
        lower.contains('signed in elsewhere')) {
      return LogoutReason.sessionTakenElsewhere;
    }
    if (lower.contains('expired') ||
        lower.contains('invalid session') ||
        lower.contains('not logged in')) {
      return LogoutReason.sessionExpired;
    }
    return null;
  }

  static String titleFor(LogoutReason reason) {
    switch (reason) {
      case LogoutReason.sessionTakenElsewhere:
        return 'Signed in elsewhere';
      case LogoutReason.sessionExpired:
        return 'Session expired';
      case LogoutReason.signedOut:
        return 'Signed out';
    }
  }

  static String userMessage({
    required LogoutReason reason,
    String? backendMessage,
  }) {
    switch (reason) {
      case LogoutReason.sessionTakenElsewhere:
        return 'This account was signed in on another phone, tablet, or browser. '
            'Quze allows only one active player session at a time.\n\n'
            'Sign in again here to continue on this device.';
      case LogoutReason.sessionExpired:
        return 'Your session is no longer valid. Please sign in again to continue.';
      case LogoutReason.signedOut:
        if (backendMessage != null &&
            backendMessage.isNotEmpty &&
            backendMessage != 'No active session found') {
          return backendMessage;
        }
        return 'You have been signed out. Please sign in again to continue.';
    }
  }
}
