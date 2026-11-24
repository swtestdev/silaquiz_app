import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectTimerWebSocket(Uri uri) => WebSocketChannel.connect(uri);
