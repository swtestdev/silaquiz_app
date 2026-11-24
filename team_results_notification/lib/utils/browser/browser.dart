import 'browser_stub.dart';
export 'browser_stub.dart' show StrictVisibilityWebCallbacks;

import 'browser_stub.dart'
    if (dart.library.js_interop) 'browser_web.dart' as impl;

Future<bool> copyTextToClipboard(String text) => impl.copyTextToClipboard(text);

Future<void> deleteAllCachesAndReload() => impl.deleteAllCachesAndReload();

bool initStrictVisibilityWeb(StrictVisibilityWebCallbacks callbacks) =>
    impl.initStrictVisibilityWeb(callbacks);

Future<void> downloadBytesAsFile(List<int> bytes, String filename) =>
    impl.downloadBytesAsFile(bytes, filename);

void replaceWebHistoryRoute(String flutterRoute) =>
    impl.replaceWebHistoryRoute(flutterRoute);
