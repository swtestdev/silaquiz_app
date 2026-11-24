import 'package:flutter_test/flutter_test.dart';
import 'package:pwa_app/services/api_config_service.dart';

void main() {
  group('ApiConfigService', () {
    test('normalizeApiBaseUrl appends /api when missing', () {
      expect(
        ApiConfigService.normalizeApiBaseUrl('http://192.168.2.1:8000'),
        'http://192.168.2.1:8000/api',
      );
    });

    test('normalizeApiBaseUrl trims trailing slashes', () {
      expect(
        ApiConfigService.normalizeApiBaseUrl('http://192.168.2.1:8000/api/'),
        'http://192.168.2.1:8000/api',
      );
    });
  });
}
