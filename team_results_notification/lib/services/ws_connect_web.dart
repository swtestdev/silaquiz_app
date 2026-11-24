import 'package:web_socket_channel/web_socket_channel.dart';

/// Browser WebSocket (dart2js and Wasm) — supported in web_socket_channel 3.x.
WebSocketChannel connectTimerWebSocket(Uri uri) => WebSocketChannel.connect(uri);
