import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pwa_app/services/timer_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TimerStore.clientPrefsIndicateRoundMode', () {
    test('cached_round_timer marks round mode between questions', () async {
      SharedPreferences.setMockInitialValues({
        'cached_round_timer': 60,
        'last_timer_action_data': jsonEncode({
          'timer_action': 'STOP_TIMER',
          'question_id': 0,
          'final_timer': 0,
          'round_name': 'ПОКАЖИ КТО',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      expect(TimerStore.clientPrefsIndicateRoundMode(prefs), isTrue);
    });

    test('stale last_timer_status Running alone is not round mode', () async {
      SharedPreferences.setMockInitialValues({
        'last_timer_status': 'Running',
        'last_timer_action_data': jsonEncode({
          'timer_action': 'STOP_TIMER',
          'question_id': 0,
          'final_timer': 0,
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      expect(TimerStore.storedTimerPayloadIndicatesRoundMode(prefs), isFalse);
      expect(TimerStore.clientPrefsIndicateRoundMode(prefs), isFalse);
    });

    test('round_scope_open false is not a mid-round gap (abort)', () async {
      SharedPreferences.setMockInitialValues({
        'cached_round_timer': 60,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        TimerStore.shouldTreatStopAsMidRoundGapForTest(
          {
            'timer_action': 'STOP_TIMER',
            'question_id': 0,
            'round_scope_open': false,
          },
          prefs,
        ),
        isFalse,
      );
    });

    test('round_scope_open true is a mid-round gap', () async {
      SharedPreferences.setMockInitialValues({
        'cached_round_timer': 60,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        TimerStore.shouldTreatStopAsMidRoundGapForTest(
          {
            'timer_action': 'STOP_TIMER',
            'question_id': 0,
            'round_scope_open': true,
          },
          prefs,
        ),
        isTrue,
      );
    });
  });
}
