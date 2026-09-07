import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart';

import 'browser_stub.dart';

Future<bool> copyTextToClipboard(String text) async {
  try {
    final clipboard = window.navigator.clipboard;
    if (clipboard != null) {
      await clipboard.writeText(text).toDart;
      return true;
    }
  } catch (_) {}
  try {
    final textarea = document.createElement('textarea') as HTMLTextAreaElement;
    textarea.value = text;
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    textarea.style.top = '0';
    document.body?.append(textarea);
    textarea.focus();
    textarea.select();
    textarea.setSelectionRange(0, text.length);
    final ok = document.execCommand('copy');
    textarea.remove();
    return ok;
  } catch (_) {
    return false;
  }
}

Future<void> deleteAllCachesAndReload() async {
  try {
    window.localStorage.clear();
    window.sessionStorage.clear();
  } catch (_) {}

  final cacheStorage = window.caches;
  if (cacheStorage != null) {
    try {
      final cacheNames = (await cacheStorage.keys().toDart).toDart;
      for (final cacheName in cacheNames) {
        final name = (cacheName as JSString).toDart;
        await cacheStorage.delete(name).toDart;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
  }

  final serviceWorker = window.navigator.serviceWorker;
  if (serviceWorker != null) {
    try {
      final registrations =
          (await serviceWorker.getRegistrations().toDart).toDart;
      for (final registration in registrations) {
        final reg = registration as ServiceWorkerRegistration;
        reg.installing?.postMessage({'type': 'SKIP_WAITING'}.jsify());
        reg.waiting?.postMessage({'type': 'SKIP_WAITING'}.jsify());
        reg.active?.postMessage({'type': 'SKIP_WAITING'}.jsify());
        await reg.unregister().toDart;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } catch (_) {}
  }

  final origin = window.location.origin;
  final pathname = window.location.pathname;
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final random = (timestamp % 100000).toString();
  final reloadUrl =
      '$origin$pathname?_update=$timestamp&_cb=$random&_nocache=true';

  window.location.replace(reloadUrl);

  Future<void>.delayed(const Duration(milliseconds: 1000), () {
    try {
      window.location.href = reloadUrl;
    } catch (_) {
      try {
        window.location.reload();
      } catch (_) {}
    }
  });
}

bool initStrictVisibilityWeb(StrictVisibilityWebCallbacks callbacks) {
  final initialVisible = document.visibilityState == 'visible';

  document.addEventListener(
    'visibilitychange',
    ((Event _) {
      callbacks.onDocumentVisibilityChange(
        document.visibilityState == 'visible',
      );
    }).toJS,
  );

  window.addEventListener('blur', ((Event _) {
    callbacks.onWindowBlur();
  }).toJS);

  window.addEventListener('focus', ((Event _) {
    callbacks.onWindowFocus();
  }).toJS);

  window.addEventListener('beforeunload', ((Event _) {
    callbacks.onBeforeUnload();
  }).toJS);

  window.addEventListener('pagehide', ((Event _) {
    callbacks.onPageHide();
  }).toJS);

  return initialVisible;
}

Future<void> downloadBytesAsFile(List<int> bytes, String filename) async {
  final blob = Blob(
    [Uint8List.fromList(bytes).toJS].toJS,
    BlobPropertyBag(
      type:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ),
  );
  final url = URL.createObjectURL(blob);
  final anchor = document.createElement('a') as HTMLAnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';

  document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}
