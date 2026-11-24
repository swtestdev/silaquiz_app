/// Non-web stub — no browser APIs available.

class StrictVisibilityWebCallbacks {
  final void Function(bool visible) onDocumentVisibilityChange;
  final void Function() onWindowBlur;
  final void Function() onWindowFocus;
  final void Function() onBeforeUnload;
  final void Function() onPageHide;

  const StrictVisibilityWebCallbacks({
    required this.onDocumentVisibilityChange,
    required this.onWindowBlur,
    required this.onWindowFocus,
    required this.onBeforeUnload,
    required this.onPageHide,
  });
}

Future<bool> copyTextToClipboard(String text) async => false;

Future<void> deleteAllCachesAndReload() async {}

bool initStrictVisibilityWeb(StrictVisibilityWebCallbacks callbacks) => true;

Future<void> downloadBytesAsFile(List<int> bytes, String filename) async {}

/// Sync browser URL hash with [flutterRoute] (e.g. `/main`) without adding history.
void replaceWebHistoryRoute(String flutterRoute) {}
