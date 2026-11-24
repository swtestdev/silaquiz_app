import 'package:web_socket_channel/web_socket_channel.dart';

export 'ws_connect_stub.dart'
    if (dart.library.io) 'ws_connect_io.dart'
    if (dart.library.js_interop) 'ws_connect_web.dart'
    if (dart.library.html) 'ws_connect_web.dart';
