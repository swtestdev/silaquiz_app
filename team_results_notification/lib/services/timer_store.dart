import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kind of active countdown window.
enum TimerSessionKind {
  question,
  roundFinal,
}

/// Server-authoritative timer window anchored on [endsAtUtc].
class TimerSession {
  const TimerSession({
    required this.eventId,
    required this.kind,
    required this.roundName,
    required this.startedAtUtc,
    required this.endsAtUtc,
    required this.totalSeconds,
  });

  final String eventId;
  final TimerSessionKind kind;
  final String roundName;
  final DateTime startedAtUtc;
  final DateTime endsAtUtc;
  final int totalSeconds;

  bool isActiveAt(DateTime nowUtc) => endsAtUtc.isAfter(nowUtc);

  int remainingSecondsAt(DateTime nowUtc) {
    final sec = endsAtUtc.difference(nowUtc).inSeconds;
    return sec < 0 ? 0 : sec;
  }

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'kind': kind.name,
        'round_name': roundName,
        'started_at_utc': startedAtUtc.toIso8601String(),
        'ends_at_utc': endsAtUtc.toIso8601String(),
        'total_seconds': totalSeconds,
      };

  static TimerSession? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final kindName = json['kind'] as String? ?? '';
      final kind = TimerSessionKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => TimerSessionKind.question,
      );
      final started = TimerStore.parseUtc(json['started_at_utc'] as String?);
      final ends = TimerStore.parseUtc(json['ends_at_utc'] as String?);
      if (started == null || ends == null) return null;
      return TimerSession(
        eventId: json['event_id']?.toString() ?? '',
        kind: kind,
        roundName: json['round_name']?.toString() ?? '',
        startedAtUtc: started,
        endsAtUtc: ends,
        totalSeconds: TimerStore.parseInt(json['total_seconds']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Snapshot for progress bar / numeric display.
class TimerDisplayState {
  const TimerDisplayState({
    required this.activeTimer,
    required this.remainingSeconds,
    required this.totalSeconds,
    required this.isRunning,
    required this.startTimerStatus,
    required this.lastTimerStatus,
  });

  final String activeTimer;
  final int remainingSeconds;
  final int totalSeconds;
  final bool isRunning;
  final String startTimerStatus;
  final String lastTimerStatus;

  static const idle = TimerDisplayState(
    activeTimer: 'Idle',
    remainingSeconds: 0,
    totalSeconds: 0,
    isRunning: false,
    startTimerStatus: 'Idle',
    lastTimerStatus: 'Idle',
  );
}

/// Single source of truth for question + round-final countdowns (Option A).
class TimerStore {
  TimerStore._();

  static final TimerStore instance = TimerStore._();

  static const _prefsQuestionKey = 'timer_store_question_session';
  static const _prefsRoundFinalKey = 'timer_store_round_final_session';

  TimerSession? _questionSession;
  TimerSession? _roundFinalSession;
  Timer? _ticker;
  final List<VoidCallback> _listeners = [];

  TimerSession? get questionSession => _questionSession;
  TimerSession? get roundFinalSession => _roundFinalSession;

  static int parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v.toString()) ?? 0;
  }

  static DateTime? parseUtc(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      var dt = DateTime.parse(raw);
      if (!raw.endsWith('Z') &&
          !raw.contains('+') &&
          !raw.contains('-', 10)) {
        dt = DateTime.utc(
          dt.year,
          dt.month,
          dt.day,
          dt.hour,
          dt.minute,
          dt.second,
          dt.millisecond,
          dt.microsecond,
        );
      } else {
        dt = dt.toUtc();
      }
      return dt;
    } catch (_) {
      return null;
    }
  }

  static bool roundNameKeysMatch(String a, String b) {
    final x = a.trim().toLowerCase();
    final y = b.trim().toLowerCase();
    return x.isNotEmpty && y.isNotEmpty && x == y;
  }

  void addListener(VoidCallback listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final l in List<VoidCallback>.from(_listeners)) {
      l();
    }
  }

  void _ensureTicker() {
    if (_ticker != null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_onTick());
    });
  }

  void _stopTickerIfIdle() {
    final now = DateTime.now().toUtc();
    final qActive = _questionSession?.isActiveAt(now) ?? false;
    final rActive = _roundFinalSession?.isActiveAt(now) ?? false;
    if (!qActive && !rActive) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> _onTick() async {
    final changed = await _expireSessionsIfNeeded();
    if (changed) {
      await _persistSessions();
      await _syncLegacyPrefs();
      _notify();
    } else {
      _notify();
    }
    _stopTickerIfIdle();
  }

  Future<bool> _expireSessionsIfNeeded() async {
    final now = DateTime.now().toUtc();
    var changed = false;
    if (_questionSession != null && !_questionSession!.isActiveAt(now)) {
      _questionSession = null;
      changed = true;
    }
    if (_roundFinalSession != null && !_roundFinalSession!.isActiveAt(now)) {
      final rn = _roundFinalSession!.roundName;
      _roundFinalSession = null;
      changed = true;
      if (rn.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await _addRoundFinalTimerExpired(prefs, rn);
      }
    }
    return changed;
  }

  /// Progress bar: round final wins over per-question START.
  TimerDisplayState get displayState {
    final now = DateTime.now().toUtc();
    final q = _questionSession;
    final r = _roundFinalSession;
    final qActive = q != null && q.isActiveAt(now);
    final rActive = r != null && r.isActiveAt(now);

    final startStatus = qActive ? 'Running' : 'Idle';
    final lastStatus = rActive ? 'Running' : 'Stopped';

    if (rActive) {
      final rem = r!.remainingSecondsAt(now);
      return TimerDisplayState(
        activeTimer: 'LAST_TIMER',
        remainingSeconds: rem,
        totalSeconds: r.totalSeconds,
        isRunning: rem > 0,
        startTimerStatus: startStatus,
        lastTimerStatus: lastStatus,
      );
    }
    if (qActive) {
      final rem = q!.remainingSecondsAt(now);
      return TimerDisplayState(
        activeTimer: 'START_TIMER',
        remainingSeconds: rem,
        totalSeconds: q.totalSeconds,
        isRunning: rem > 0,
        startTimerStatus: startStatus,
        lastTimerStatus: lastStatus,
      );
    }
    return TimerDisplayState(
      activeTimer: 'Idle',
      remainingSeconds: 0,
      totalSeconds: 0,
      isRunning: false,
      startTimerStatus: startStatus,
      lastTimerStatus: lastStatus,
    );
  }

  Future<Map<String, dynamic>> getCurrentTimerStatus() async {
    await _expireSessionsIfNeeded();
    final d = displayState;
    DateTime? startTime;
    if (d.activeTimer == 'LAST_TIMER' && _roundFinalSession != null) {
      startTime = _roundFinalSession!.startedAtUtc;
    } else if (d.activeTimer == 'START_TIMER' && _questionSession != null) {
      startTime = _questionSession!.startedAtUtc;
    }
    return {
      'active_timer': d.activeTimer,
      'remaining_seconds': d.remainingSeconds,
      'original_duration': d.totalSeconds > 0 ? d.totalSeconds : null,
      'start_time': startTime?.toIso8601String(),
      'start_timer_status': d.startTimerStatus,
      'last_timer_status': d.lastTimerStatus,
    };
  }

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _questionSession =
        TimerSession.fromJson(_decodeJson(prefs.getString(_prefsQuestionKey)));
    _roundFinalSession =
        TimerSession.fromJson(_decodeJson(prefs.getString(_prefsRoundFinalKey)));
    await _expireSessionsIfNeeded();
    await _syncLegacyPrefs();
    if ((_questionSession?.isActiveAt(DateTime.now().toUtc()) ?? false) ||
        (_roundFinalSession?.isActiveAt(DateTime.now().toUtc()) ?? false)) {
      _ensureTicker();
    }
  }

  Map<String, dynamic>? _decodeJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistSessions() async {
    final prefs = await SharedPreferences.getInstance();
    if (_questionSession != null) {
      await prefs.setString(
        _prefsQuestionKey,
        jsonEncode(_questionSession!.toJson()),
      );
    } else {
      await prefs.remove(_prefsQuestionKey);
    }
    if (_roundFinalSession != null) {
      await prefs.setString(
        _prefsRoundFinalKey,
        jsonEncode(_roundFinalSession!.toJson()),
      );
    } else {
      await prefs.remove(_prefsRoundFinalKey);
    }
  }

  /// Keep legacy prefs keys for editability helpers and stored payload merge.
  Future<void> _syncLegacyPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();
    final q = _questionSession;
    final r = _roundFinalSession;
    final qActive = q != null && q.isActiveAt(now);
    final rActive = r != null && r.isActiveAt(now);

    if (qActive) {
      await prefs.setString('start_timer_status', 'Running');
      await prefs.setString('start_timer_start_time', q.startedAtUtc.toIso8601String());
      await prefs.setString('start_timer_end_utc', q.endsAtUtc.toIso8601String());
      await prefs.setInt('start_timer_original_duration', q.totalSeconds);
      await prefs.setInt('start_timer_duration', q.remainingSecondsAt(now));
    } else {
      await prefs.setString('start_timer_status', 'Idle');
      await prefs.setInt('start_timer_duration', 0);
      await prefs.remove('start_timer_end_utc');
    }

    if (rActive) {
      await prefs.setString('last_timer_status', 'Running');
      await prefs.setString('last_timer_start_time', r.startedAtUtc.toIso8601String());
      await prefs.setString('last_timer_end_utc', r.endsAtUtc.toIso8601String());
      await prefs.setInt('last_timer_original_duration', r.totalSeconds);
      await prefs.setInt('last_timer_duration', r.remainingSecondsAt(now));
    } else {
      await prefs.setString('last_timer_status', 'Stopped');
      await prefs.setInt('last_timer_duration', 0);
      await prefs.remove('last_timer_end_utc');
    }
  }

  Future<void> reset() async {
    _ticker?.cancel();
    _ticker = null;
    _questionSession = null;
    _roundFinalSession = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsQuestionKey);
    await prefs.remove(_prefsRoundFinalKey);
    await prefs.setString('start_timer_status', 'Idle');
    await prefs.setString('last_timer_status', 'Idle');
    await prefs.remove('start_timer_duration');
    await prefs.remove('last_timer_duration');
    await prefs.remove('start_timer_original_duration');
    await prefs.remove('last_timer_original_duration');
    await prefs.remove('start_timer_start_time');
    await prefs.remove('last_timer_start_time');
    await prefs.remove('last_timer_action_data');
    await prefs.remove('rounds_final_timer_expired');
    await prefs.remove('cached_round_timer');
    await prefs.remove('start_timer_end_utc');
    await prefs.remove('last_timer_end_utc');
    _notify();
  }

  static TimerSession? _sessionFromTrigger({
    required Map<String, dynamic> message,
    required TimerSessionKind kind,
    required int totalSecondsFallback,
  }) {
    if (totalSecondsFallback <= 0) return null;

    final endsAt = parseUtc(message['timer_end'] as String?);
    final startedAt =
        parseUtc(message['timer_start'] as String?) ?? DateTime.now().toUtc();
    final durationFromMsg = parseInt(message['duration_seconds']);
    final total = durationFromMsg > 0 ? durationFromMsg : totalSecondsFallback;

    DateTime ends;
    if (endsAt != null) {
      ends = endsAt;
    } else {
      ends = startedAt.add(Duration(seconds: total));
    }

    final now = DateTime.now().toUtc();
    if (!ends.isAfter(now)) return null;

    return TimerSession(
      eventId: message['event_id']?.toString() ?? '',
      kind: kind,
      roundName: message['round_name']?.toString() ?? '',
      startedAtUtc: startedAt,
      endsAtUtc: ends,
      totalSeconds: total,
    );
  }

  Future<void> applyTrigger(Map<String, dynamic> message) async {
    final timerAction = message['timer_action'] as String?;
    if (timerAction == null) return;

    final prefs = await SharedPreferences.getInstance();

    if (timerAction == 'START_TIMER' || timerAction == 'START_TIME') {
      final ftMsg = parseInt(message['final_timer']);
      final lastRunning =
          (_roundFinalSession?.isActiveAt(DateTime.now().toUtc()) ?? false) ||
              (prefs.getString('last_timer_status') ?? '') == 'Running';
      if (ftMsg == 0 && !lastRunning) {
        await prefs.remove('cached_round_timer');
      }
    }

    final payloadToStore =
        await mergeTimerPayloadForStorage(prefs, message, timerAction);
    final ftVal = parseInt(payloadToStore['final_timer']);
    final shouldStore = timerAction != 'STOP_TIMER' || ftVal > 0;
    if (shouldStore) {
      await prefs.setString('last_timer_action_data', jsonEncode(payloadToStore));
    }

    switch (timerAction) {
      case 'START_TIME':
      case 'START_TIMER':
        await _applyStart(message, prefs);
        break;
      case 'LAST_TIMER':
        await _applyLast(message, prefs);
        break;
      case 'STOP_TIMER':
      case 'PAUSE_TIMER':
        await _applyStop(message, prefs, ftVal);
        break;
    }

    await _persistSessions();
    await _syncLegacyPrefs();
    _ensureTicker();
    _notify();
  }

  Future<void> _applyStart(
    Map<String, dynamic> message,
    SharedPreferences prefs,
  ) async {
    final typeGame = parseInt(message['final_timer']);
    final roundModeSlideStart = typeGame != 0;

    if (!roundModeSlideStart) {
      _roundFinalSession = null;
      await prefs.setString('last_timer_status', 'Idle');
    }

    final questionTimer = parseInt(message['question_timer']);
    final session = _sessionFromTrigger(
      message: message,
      kind: TimerSessionKind.question,
      totalSecondsFallback: questionTimer,
    );
    _questionSession = session;
  }

  Future<void> _applyLast(
    Map<String, dynamic> message,
    SharedPreferences prefs,
  ) async {
    _questionSession = null;
    await prefs.setString('start_timer_status', 'Stopped');
    await prefs.remove('start_timer_end_utc');

    final finalTimer = parseInt(message['final_timer']);
    final absTotal = finalTimer != 0 ? finalTimer.abs() : 0;
    final rn = message['round_name']?.toString() ?? '';
    if (rn.isNotEmpty) {
      await _removeRoundFinalTimerExpired(prefs, rn);
    }

    final session = _sessionFromTrigger(
      message: message,
      kind: TimerSessionKind.roundFinal,
      totalSecondsFallback: absTotal,
    );
    _roundFinalSession = session;

    if (session == null && rn.isNotEmpty) {
      await _addRoundFinalTimerExpired(prefs, rn);
    }
  }

  Future<void> _applyStop(
    Map<String, dynamic> message,
    SharedPreferences prefs,
    int ftVal,
  ) async {
    _questionSession = null;
    await prefs.remove('start_timer_end_utc');

    final isRoundModeStop =
        storedTimerPayloadIndicatesRoundMode(prefs) || ftVal > 0;

    if (isRoundModeStop) {
      final rActive =
          _roundFinalSession?.isActiveAt(DateTime.now().toUtc()) ?? false;
      if (rActive && _roundFinalSession != null) {
        final stopRoundName = (message['round_name'] as String?)?.trim() ?? '';
        final lastRoundName = _roundFinalSession!.roundName.trim();
        final roundMatches = stopRoundName.isEmpty ||
            lastRoundName.isEmpty ||
            roundNameKeysMatch(stopRoundName, lastRoundName);

        if (roundMatches) {
          final rn = _roundFinalSession!.roundName;
          _roundFinalSession = null;
          await prefs.remove('last_timer_end_utc');
          if (rn.isNotEmpty) {
            await _addRoundFinalTimerExpired(prefs, rn);
          }
        }
      }
      return;
    }

    _roundFinalSession = null;
    await prefs.remove('last_timer_end_utc');
  }

  static bool storedTimerPayloadIndicatesRoundMode(SharedPreferences prefs) {
    try {
      if ((prefs.getString('last_timer_status') ?? '') == 'Running') {
        return true;
      }
      final rawPayload = prefs.getString('last_timer_action_data');
      if (rawPayload == null) return false;
      final lm = jsonDecode(rawPayload) as Map<String, dynamic>;
      return parseInt(lm['final_timer']) != 0;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> mergeTimerPayloadForStorage(
    SharedPreferences prefs,
    Map<String, dynamic> message,
    String timerAction,
  ) async {
    final payload = Map<String, dynamic>.from(message);
    var ft = parseInt(payload['final_timer']);

    if (ft == 0 &&
        (timerAction == 'START_TIMER' ||
            timerAction == 'START_TIME' ||
            timerAction == 'LAST_TIMER')) {
      final lastRunning =
          (prefs.getString('last_timer_status') ?? '') == 'Running';
      if (lastRunning) {
        final cached = prefs.getInt('cached_round_timer') ?? 0;
        if (cached != 0) {
          ft = cached;
          payload['final_timer'] = cached;
        } else {
          final prevStr = prefs.getString('last_timer_action_data');
          if (prevStr != null) {
            try {
              final prev = jsonDecode(prevStr) as Map<String, dynamic>;
              final prevFt = parseInt(prev['final_timer']);
              if (prevFt != 0) {
                ft = prevFt;
                payload['final_timer'] = prevFt;
              }
            } catch (_) {}
          }
        }
      } else {
        final prevStr = prefs.getString('last_timer_action_data');
        if (prevStr != null) {
          try {
            final prev = jsonDecode(prevStr) as Map<String, dynamic>;
            final prevFt = parseInt(prev['final_timer']);
            if (prevFt != 0 &&
                (timerAction == 'LAST_TIMER' ||
                    parseInt(message['final_timer']) != 0)) {
              ft = prevFt;
              payload['final_timer'] = prevFt;
            }
          } catch (_) {}
        }
      }
    }

    if (ft != 0) {
      await prefs.setInt('cached_round_timer', ft);
    }

    if (timerAction == 'LAST_TIMER' && ft != 0) {
      final rn = message['round_name'] as String? ?? '';
      if (rn.isNotEmpty) {
        await _removeRoundFinalTimerExpired(prefs, rn);
      }
    }

    return payload;
  }

  static Future<void> _addRoundFinalTimerExpired(
    SharedPreferences prefs,
    String roundName,
  ) async {
    final key = 'rounds_final_timer_expired';
    final existing = prefs.getStringList(key) ?? [];
    if (existing.any((r) => roundNameKeysMatch(r, roundName))) return;
    existing.add(roundName.trim());
    await prefs.setStringList(key, existing);
  }

  static Future<void> _removeRoundFinalTimerExpired(
    SharedPreferences prefs,
    String roundName,
  ) async {
    final key = 'rounds_final_timer_expired';
    final existing = prefs.getStringList(key) ?? [];
    final filtered =
        existing.where((r) => !roundNameKeysMatch(r, roundName)).toList();
    if (filtered.length != existing.length) {
      await prefs.setStringList(key, filtered);
    }
  }

  static Future<bool> isRoundFinalTimerExpired(String roundName) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList('rounds_final_timer_expired') ?? [];
    return existing.any((r) => roundNameKeysMatch(r, roundName));
  }
}
