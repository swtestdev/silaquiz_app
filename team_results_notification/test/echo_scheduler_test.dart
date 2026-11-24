import 'package:flutter_test/flutter_test.dart';
import 'package:pwa_app/utils/echo_scheduler.dart';

void main() {
  test('echoPollInterval returns 2s when WebSocket is down', () {
    expect(
      echoPollInterval(webSocketLive: false),
      const Duration(seconds: 2),
    );
  });

  test('echoPollInterval returns 5s when WebSocket is live', () {
    expect(
      echoPollInterval(webSocketLive: true),
      const Duration(seconds: 5),
    );
  });
}
