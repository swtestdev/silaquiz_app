import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_data_service.dart';
import '../services/strict_visibility_service.dart';
import '../widgets/answer_editor_dialog.dart';
import '../widgets/responsive_layout.dart';
import 'login_page.dart'; // For DatabaseService

// Global callback for timer messages from WebSocket
Function(Map<String, dynamic>)? _globalTimerMessageHandler;

// Global timer status variables
String _startTimerStatus = 'Idle'; // Status for START_TIMER
String _lastTimerStatus = 'Idle';  // Status for LAST_TIMER

DateTime? _startTimerStartTime;
DateTime? _lastTimerStartTime;
Timer? _globalStartTimer;
Timer? _globalLastTimer;

int _parseRoundTimerValue(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? 0;
  return int.tryParse(v.toString()) ?? 0;
}

bool _roundNameKeysMatch(String a, String b) {
  final x = a.trim().toLowerCase();
  final y = b.trim().toLowerCase();
  return x.isNotEmpty && y.isNotEmpty && x == y;
}

Future<void> _persistCachedRoundTimer(SharedPreferences prefs, int rt) async {
  if (rt != 0) {
    await prefs.setInt('cached_round_timer', rt);
  }
}

/// Per-slide START/STOP often omit final_timer — merge from cache or previous payload before storing.
Future<Map<String, dynamic>> _mergeTimerPayloadForStorage(
  SharedPreferences prefs,
  Map<String, dynamic> message,
  String timerAction,
) async {
  final payload = Map<String, dynamic>.from(message);
  var ft = _parseRoundTimerValue(payload['final_timer']);

  if (ft == 0 &&
      (timerAction == 'START_TIMER' ||
          timerAction == 'START_TIME' ||
          timerAction == 'LAST_TIMER')) {
    final lastRunning = (prefs.getString('last_timer_status') ?? '') == 'Running';
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
            final prevFt = _parseRoundTimerValue(prev['final_timer']);
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
          final prevFt = _parseRoundTimerValue(prev['final_timer']);
          if (prevFt != 0 &&
              (timerAction == 'LAST_TIMER' ||
                  _parseRoundTimerValue(message['final_timer']) != 0)) {
            ft = prevFt;
            payload['final_timer'] = prevFt;
          }
        } catch (_) {}
      }
    }
  }

  if (ft != 0) {
    await _persistCachedRoundTimer(prefs, ft);
  }

  if (timerAction == 'LAST_TIMER' && ft != 0) {
    final rn = message['round_name'] as String? ?? '';
    if (rn.isNotEmpty) {
      await _removeRoundFinalTimerExpired(prefs, rn);
    }
  }

  return payload;
}

Future<int> _resolveRoundTimerFromPrefsOnly() async {
  final prefs = await SharedPreferences.getInstance();
  var rt = prefs.getInt('cached_round_timer') ?? 0;
  if (rt != 0) return rt;

  final lastTimerDataStr = prefs.getString('last_timer_action_data');
  if (lastTimerDataStr != null) {
    try {
      final lastTimerData = jsonDecode(lastTimerDataStr) as Map<String, dynamic>;
      rt = _parseRoundTimerValue(lastTimerData['final_timer']);
    } catch (_) {}
  }
  return rt;
}

bool _storedTimerPayloadIndicatesRoundMode(SharedPreferences prefs) {
  try {
    if ((prefs.getString('last_timer_status') ?? '') == 'Running') return true;

    final rawPayload = prefs.getString('last_timer_action_data');
    if (rawPayload == null) return false;
    final lm = jsonDecode(rawPayload) as Map<String, dynamic>;
    return _parseRoundTimerValue(lm['final_timer']) != 0;
  } catch (_) {
    return false;
  }
}

// Function to forward timer messages from main_page

Future<void> forwardTimerMessage(Map<String, dynamic> message) async {

  // Handle timer first - must complete before page handler so status is available
  await _handleGlobalTimer(message);

  // Then forward to page handler if registered
  if (_globalTimerMessageHandler != null) {
    print('QuestionPage: Received timer message, forwarding to handler');
    _globalTimerMessageHandler!(message);
  } else {
    print('QuestionPage: Timer message received but no handler registered');
  }
}

// Global timer handler - runs in background
Future<void> _handleGlobalTimer(Map<String, dynamic> message) async {
  final timerAction = message['timer_action'] as String?;
  if (timerAction == null) return;
  
  try {
    final prefs = await SharedPreferences.getInstance();

    if (timerAction == 'START_TIMER' || timerAction == 'START_TIME') {
      final ftMsg = _parseRoundTimerValue(message['final_timer']);
      final lastRunning = (prefs.getString('last_timer_status') ?? '') == 'Running';
      if (ftMsg == 0 && !lastRunning) {
        await prefs.remove('cached_round_timer');
      }
    }

    // Merge final_timer into payload so per-slide START does not wipe round mode from prefs.
    // Do NOT overwrite with STOP_TIMER when it would clear final_timer (STOP often sends final_timer:0).
    final payloadToStore = await _mergeTimerPayloadForStorage(prefs, message, timerAction);
    final ftVal = _parseRoundTimerValue(payloadToStore['final_timer']);
    final shouldStore = timerAction != 'STOP_TIMER' || ftVal > 0;
    if (shouldStore) {
      await prefs.setString('last_timer_action_data', jsonEncode(payloadToStore));
      print('Global timer: Stored timer action data (final_timer=$ftVal)');
    } else {
      print('Global timer: Skipping store for STOP_TIMER to preserve final_timer for round mode');
    }

    switch (timerAction) {
      case 'START_TIME':
      case 'START_TIMER':
        dynamic finalTimerFromMsgEarly = message['final_timer'];
        int typeGameFromMessageEarly = 0;
        if (finalTimerFromMsgEarly is int) {
          typeGameFromMessageEarly = finalTimerFromMsgEarly;
        } else if (finalTimerFromMsgEarly != null) {
          typeGameFromMessageEarly = int.tryParse(finalTimerFromMsgEarly.toString()) ?? 0;
        }
        final bool roundModeSlideStart = typeGameFromMessageEarly != 0;

        // Classic mode only: LAST must be Idle when the per-slide question window opens.
        // Round mode (final_timer != 0): per-slide START must NOT cancel LAST_TIMER or clear
        // last_timer prefs — that kills the team's round countdown and breaks editability/timer UI.
        if (!roundModeSlideStart) {
          _globalLastTimer?.cancel();
          _lastTimerStatus = 'Idle';
          _lastTimerStartTime = null;
          await prefs.setString('last_timer_status', 'Idle');
        }

        // Get timer value
        dynamic questionTimerValue = message['question_timer'];
        int questionTimer = 0;
        if (questionTimerValue is int) {
          questionTimer = questionTimerValue;
        } else if (questionTimerValue is String) {
          questionTimer = int.tryParse(questionTimerValue) ?? 0;
        }
        
        // Calculate adjusted timer
        final timerStartStr = message['timer_start'] as String?;
        DateTime? timerStart;
        if (timerStartStr != null) {
          try {
            // Parse as UTC - if no timezone indicator, assume UTC
            timerStart = DateTime.parse(timerStartStr);
            // Ensure it's in UTC
            if (!timerStartStr.endsWith('Z') && !timerStartStr.contains('+') && !timerStartStr.contains('-', 10)) {
              // No timezone info, treat as UTC
              timerStart = DateTime.utc(
                timerStart.year, timerStart.month, timerStart.day,
                timerStart.hour, timerStart.minute, timerStart.second,
                timerStart.millisecond, timerStart.microsecond
              );
            } else {
              timerStart = timerStart.toUtc();
            }
          } catch (e) {
            print('Error parsing timer_start: $e, using current time');
            timerStart = DateTime.now().toUtc();
          }
        } else {
          timerStart = DateTime.now().toUtc();
        }
        
        final now = DateTime.now().toUtc();
        final String? timerEndFromServer = message['timer_end'] as String?;
        int adjustedTimer;
        if (timerEndFromServer != null && timerEndFromServer.isNotEmpty) {
          try {
            final end = DateTime.parse(timerEndFromServer).toUtc();
            adjustedTimer = end.difference(now).inSeconds.clamp(0, questionTimer > 0 ? questionTimer : 86400);
            await prefs.setString('start_timer_end_utc', timerEndFromServer);
          } catch (e) {
            print('Error parsing timer_end for START, falling back: $e');
            final elapsed = now.difference(timerStart).inSeconds;
            adjustedTimer = (questionTimer - elapsed).clamp(0, questionTimer);
            await prefs.remove('start_timer_end_utc');
          }
        } else {
          final elapsed = now.difference(timerStart).inSeconds;
          adjustedTimer = (questionTimer - elapsed).clamp(0, questionTimer);
          await prefs.remove('start_timer_end_utc');
        }

        print('Timer calculation: timerStart=$timerStart (UTC), now=$now (UTC), adjustedTimer=$adjustedTimer (timer_end=$timerEndFromServer)');
        
        // Round mode (final_timer != 0): we still run per-slide START here so prefs/UI show the question
        // window and answer fields enable (see _buildAnswersFromGameData). LAST prefs are only cleared on
        // classic slides above (!roundModeSlideStart), so the round countdown is preserved.
        if (adjustedTimer > 0) {
          _startTimerStatus = 'Running';
          _startTimerStartTime = timerStart;
          
          // Save to SharedPreferences (store both remaining and original duration)
          await prefs.setString('start_timer_status', 'Running');
          await prefs.setInt('start_timer_duration', adjustedTimer);
          await prefs.setInt('start_timer_original_duration', questionTimer); // Store original duration
          await prefs.setString('start_timer_start_time', timerStart.toIso8601String());
          
          // Start background countdown
          _globalStartTimer?.cancel();
          final startTimeForTimer = timerStart; // Capture non-null value
          final originalDurationForTimer = questionTimer; // Capture original duration
          _globalStartTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
            final p2 = await SharedPreferences.getInstance();
            final endStr = p2.getString('start_timer_end_utc');
            int remaining;
            if (endStr != null && endStr.isNotEmpty) {
              try {
                final end = DateTime.parse(endStr).toUtc();
                remaining = end.difference(DateTime.now().toUtc()).inSeconds.clamp(0, originalDurationForTimer);
              } catch (e) {
                final now = DateTime.now().toUtc();
                final elapsed = now.difference(startTimeForTimer).inSeconds;
                remaining = (originalDurationForTimer - elapsed).clamp(0, originalDurationForTimer);
              }
            } else {
            final now = DateTime.now().toUtc();
            final elapsed = now.difference(startTimeForTimer).inSeconds;
              remaining = (originalDurationForTimer - elapsed).clamp(0, originalDurationForTimer);
            }
            
            await prefs.setInt('start_timer_duration', remaining);
            
            // Debug log every 5 seconds
            if (remaining % 5 == 0 || remaining < 5) {
              print('Global START_TIMER: Countdown - remaining=$remaining, original=$originalDurationForTimer');
            }
            
            if (remaining <= 0) {
              _startTimerStatus = 'Idle';
              timer.cancel();
              await prefs.setString('start_timer_status', 'Idle');
              await prefs.setInt('start_timer_duration', 0);
              print('Global START_TIMER: Timer expired, status set to Idle');
            }
          });
          
          print('Global START_TIMER: Started with original=$questionTimer seconds, adjusted=$adjustedTimer seconds, status: Running, startTime=$startTimeForTimer');
        } else {
          _startTimerStatus = 'Idle';
          await prefs.setString('start_timer_status', 'Idle');
          await prefs.setInt('start_timer_duration', 0);
          print('Global START_TIMER: Expired, status: Idle');
        }
        break;
        
      case 'LAST_TIMER':
        // If START_TIMER is Running and LAST_TIMER is going to Running, set START_TIMER to Stopped
        if (_startTimerStatus == 'Running') {
          _globalStartTimer?.cancel();
          _startTimerStatus = 'Stopped';
          _startTimerStartTime = null;
          await prefs.setString('start_timer_status', 'Stopped');
          await prefs.setInt('start_timer_duration', 0);
          await prefs.remove('start_timer_end_utc');
          print('Global LAST_TIMER: START_TIMER was Running, set to Stopped');
        }
        
        // Get timer value
        dynamic finalTimerValue = message['final_timer'];
        int finalTimer = 0;
        if (finalTimerValue is int) {
          finalTimer = finalTimerValue;
        } else if (finalTimerValue is String) {
          finalTimer = int.tryParse(finalTimerValue) ?? 0;
        }
        
        // Calculate adjusted timer
        final timerStartStr = message['timer_start'] as String?;
        DateTime? timerStart;
        if (timerStartStr != null) {
          try {
            // Parse as UTC - if no timezone indicator, assume UTC
            timerStart = DateTime.parse(timerStartStr);
            // Ensure it's in UTC
            if (!timerStartStr.endsWith('Z') && !timerStartStr.contains('+') && !timerStartStr.contains('-', 10)) {
              // No timezone info, treat as UTC
              timerStart = DateTime.utc(
                timerStart.year, timerStart.month, timerStart.day,
                timerStart.hour, timerStart.minute, timerStart.second,
                timerStart.millisecond, timerStart.microsecond
              );
            } else {
              timerStart = timerStart.toUtc();
            }
          } catch (e) {
            print('Error parsing timer_start: $e, using current time');
            timerStart = DateTime.now().toUtc();
          }
        } else {
          timerStart = DateTime.now().toUtc();
        }
        
        final now = DateTime.now().toUtc();
        final String? lastEndFromServer = message['timer_end'] as String?;
        int adjustedTimer;
        if (lastEndFromServer != null && lastEndFromServer.isNotEmpty) {
          try {
            final end = DateTime.parse(lastEndFromServer).toUtc();
            adjustedTimer = end.difference(now).inSeconds.clamp(0, finalTimer > 0 ? finalTimer : 86400);
            await prefs.setString('last_timer_end_utc', lastEndFromServer);
          } catch (e) {
            print('Error parsing timer_end for LAST, falling back: $e');
            final elapsed = now.difference(timerStart).inSeconds;
            adjustedTimer = (finalTimer - elapsed).clamp(0, finalTimer);
            await prefs.remove('last_timer_end_utc');
          }
        } else {
        final elapsed = now.difference(timerStart).inSeconds;
        adjustedTimer = (finalTimer - elapsed).clamp(0, finalTimer);
        await prefs.remove('last_timer_end_utc');
        }

        print('LAST_TIMER calculation: timerStart=$timerStart (UTC), now=$now (UTC), adjustedTimer=$adjustedTimer (timer_end=$lastEndFromServer)');
        
        if (adjustedTimer > 0) {
          _lastTimerStatus = 'Running';
          _lastTimerStartTime = timerStart;
          final lastTimerRoundName = message['round_name'] as String? ?? '';

          // Save to SharedPreferences (store both remaining and original duration)
          await prefs.setString('last_timer_status', 'Running');
          await prefs.setInt('last_timer_duration', adjustedTimer);
          await prefs.setInt('last_timer_original_duration', finalTimer); // Store original duration
          await prefs.setString('last_timer_start_time', timerStart.toIso8601String());
          
          // Start background countdown
          _globalLastTimer?.cancel();
          final startTimeForTimer = timerStart; // Capture non-null value
          final originalDurationForTimer = finalTimer; // Capture original duration
          _globalLastTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
            final p2 = await SharedPreferences.getInstance();
            final endStr = p2.getString('last_timer_end_utc');
            int remaining;
            if (endStr != null && endStr.isNotEmpty) {
              try {
                final end = DateTime.parse(endStr).toUtc();
                remaining = end.difference(DateTime.now().toUtc()).inSeconds.clamp(0, originalDurationForTimer);
              } catch (e) {
            final now = DateTime.now().toUtc();
            final elapsed = now.difference(startTimeForTimer).inSeconds;
                remaining = (originalDurationForTimer - elapsed).clamp(0, originalDurationForTimer);
              }
            } else {
            final now = DateTime.now().toUtc();
            final elapsed = now.difference(startTimeForTimer).inSeconds;
            remaining = (originalDurationForTimer - elapsed).clamp(0, originalDurationForTimer);
            }
            
            await prefs.setInt('last_timer_duration', remaining);
            
            print('Global LAST_TIMER: Countdown - remaining=$remaining, original=$originalDurationForTimer');
            
            if (remaining <= 0) {
              _lastTimerStatus = 'Stopped';
              timer.cancel();
              await prefs.setString('last_timer_status', 'Stopped');
              await prefs.setInt('last_timer_duration', 0);
              if (lastTimerRoundName.isNotEmpty) {
                await _addRoundFinalTimerExpired(prefs, lastTimerRoundName);
              }
              print('Global LAST_TIMER: Timer expired, status set to Stopped');
            }
          });
          
          print('Global LAST_TIMER: Started with original=$finalTimer seconds, adjusted=$adjustedTimer seconds, status: Running, startTime=$startTimeForTimer');
        } else {
          _lastTimerStatus = 'Stopped';
          await prefs.setString('last_timer_status', 'Stopped');
          await prefs.setInt('last_timer_duration', 0);
          final lastTimerRoundName = message['round_name'] as String? ?? '';
          if (lastTimerRoundName.isNotEmpty) {
            await _addRoundFinalTimerExpired(prefs, lastTimerRoundName);
          }
          print('Global LAST_TIMER: Expired, status: Stopped');
        }
        break;
        
      case 'STOP_TIMER':
        // Per-slide STOP often means "typing window overlay ended", not "round ends".
        // In round mode (final_timer from stored START/LAST payload != 0), keep LAST countdown + prefs intact.
        final isRoundModeStop = _storedTimerPayloadIndicatesRoundMode(prefs) ||
            ftVal > 0;

        _globalStartTimer?.cancel();
        _startTimerStatus = 'Idle';
        await prefs.setString('start_timer_status', 'Idle');
        await prefs.setInt('start_timer_duration', 0);
        await prefs.remove('start_timer_end_utc');

        if (isRoundModeStop) {
          final lastSt = prefs.getString('last_timer_status') ?? _lastTimerStatus;
          _lastTimerStatus = lastSt;
          if (lastSt == 'Running') {
            final stm = prefs.getString('last_timer_start_time');
            if (stm != null) {
              try {
                _lastTimerStartTime = DateTime.parse(stm);
              } catch (_) {}
            }
          } else {
            _lastTimerStartTime = null;
          }
          print(
              'Global STOP_TIMER: round mode — cleared START only, preserved LAST ($_lastTimerStatus)'
              ', server_stop=${message['server_stop']}',
          );
          break;
        }

        _globalLastTimer?.cancel();
        _lastTimerStatus = 'Stopped';
        await prefs.setString('last_timer_status', 'Stopped');
        await prefs.setInt('last_timer_duration', 0);
        await prefs.remove('last_timer_end_utc');

        print(
            'Global STOP_TIMER: start=Idle last=Stopped (server_stop=${message['server_stop']})',
        );
        break;
    }
  } catch (e) {
    print('Error handling global timer: $e');
  }
}

/// When the server sent [question_timer]=0 but the game row has [time_to_get_answer], restart the global countdown.
Future<void> reapplyGlobalStartTimerFromGameData(Map<String, dynamic> message, int questionTimerSeconds) async {
  if (questionTimerSeconds <= 0) return;
  final enriched = Map<String, dynamic>.from(message);
  enriched['question_timer'] = questionTimerSeconds;
  await _handleGlobalTimer(enriched);
}

/// Add round to the set of rounds whose final timer has expired (persisted across slide changes)
Future<void> _addRoundFinalTimerExpired(SharedPreferences prefs, String roundName) async {
  try {
    final key = 'rounds_final_timer_expired';
    final existing = prefs.getStringList(key) ?? [];
    if (existing.any((r) => _roundNameKeysMatch(r, roundName))) return;
    existing.add(roundName.trim());
    await prefs.setStringList(key, existing);
    print('QuestionPage: Marked round "$roundName" as final timer expired');
  } catch (e) {
    print('QuestionPage: Error adding round to expired set: $e');
  }
}

Future<void> _removeRoundFinalTimerExpired(SharedPreferences prefs, String roundName) async {
  try {
    final key = 'rounds_final_timer_expired';
    final existing = prefs.getStringList(key) ?? [];
    final filtered =
        existing.where((r) => !_roundNameKeysMatch(r, roundName)).toList();
    if (filtered.length != existing.length) {
      await prefs.setStringList(key, filtered);
      print('QuestionPage: Cleared expired flag for round "$roundName" (round restarted)');
    }
  } catch (e) {
    print('QuestionPage: Error removing round from expired set: $e');
  }
}

/// When wall-clock time has passed the LAST_TIMER window but prefs still say Running
/// (e.g. global tick missed or UI refreshed during editing), persist Stopped and mark the round expired.
Future<void> _finalizeLastTimerIfExpiredFromPrefs(SharedPreferences prefs) async {
  if (prefs.getString('last_timer_status') != 'Running') return;
  final now = DateTime.now().toUtc();

  // Server-driven absolute end — must be checked; start+duration can disagree with timer_end.
  final endStr = prefs.getString('last_timer_end_utc');
  if (endStr != null && endStr.isNotEmpty) {
    try {
      final end = DateTime.parse(endStr).toUtc();
      if (!end.isAfter(now)) {
        await _persistLastTimerStoppedFromPrefs(prefs);
        return;
      }
    } catch (_) {}
  }

  final startStr = prefs.getString('last_timer_start_time');
  final orig =
      prefs.getInt('last_timer_original_duration') ?? prefs.getInt('last_timer_duration') ?? 0;
  if (startStr == null || orig <= 0) return;
  try {
    final start = DateTime.parse(startStr).toUtc();
    final elapsed = now.difference(start).inSeconds;
    if (elapsed < orig) return;
  } catch (_) {
    return;
  }
  await _persistLastTimerStoppedFromPrefs(prefs);
}

Future<void> _persistLastTimerStoppedFromPrefs(SharedPreferences prefs) async {
  await prefs.setString('last_timer_status', 'Stopped');
  await prefs.setInt('last_timer_duration', 0);
  _lastTimerStatus = 'Stopped';
  _lastTimerStartTime = null;
  _globalLastTimer?.cancel();
  final data = prefs.getString('last_timer_action_data');
  if (data != null) {
    try {
      final m = jsonDecode(data) as Map<String, dynamic>;
      final rn = m['round_name'] as String?;
      if (rn != null && rn.isNotEmpty) {
        await _addRoundFinalTimerExpired(prefs, rn);
      }
    } catch (_) {}
  }
}

/// Check if a round's final timer has expired
Future<bool> _isRoundFinalTimerExpired(String roundName) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList('rounds_final_timer_expired') ?? [];
    return existing.any((r) => _roundNameKeysMatch(r, roundName));
  } catch (e) {
    return false;
  }
}

// Initialize timer status on login
Future<void> initializeTimerStatus() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    _startTimerStatus = 'Idle';
    _lastTimerStatus = 'Idle';
    _startTimerStartTime = null;
    _lastTimerStartTime = null;
    _globalStartTimer?.cancel();
    _globalLastTimer?.cancel();
    
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
    
    print('Timer status initialized to Idle on login, timer action data cleared');
  } catch (e) {
    print('Error initializing timer status: $e');
  }
}

// Get current timer status and remaining time
Future<Map<String, dynamic>> getCurrentTimerStatus() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if timers are running and calculate remaining time
    String activeStatus = 'Idle';
    int? remainingSeconds;
    int? originalDuration;
    DateTime? startTime;
    
    if (_startTimerStatus == 'Running' && _startTimerStartTime != null) {
      // Get original duration from SharedPreferences
      final origDuration = prefs.getInt('start_timer_original_duration') ?? 0;
      if (origDuration > 0) {
        final now = DateTime.now().toUtc();
        final elapsed = now.difference(_startTimerStartTime!).inSeconds;
        // Calculate remaining from original duration, not adjusted duration
        remainingSeconds = (origDuration - elapsed).clamp(0, origDuration);
        originalDuration = origDuration;
        if (remainingSeconds > 0) {
          activeStatus = 'START_TIMER';
          startTime = _startTimerStartTime;
        } else {
          _startTimerStatus = 'Idle';
          remainingSeconds = 0;
        }
      }
    } else if (_lastTimerStatus == 'Running' && _lastTimerStartTime != null) {
      final now = DateTime.now().toUtc();
      final origDuration = prefs.getInt('last_timer_original_duration') ?? 0;
      final endStr = prefs.getString('last_timer_end_utc');
      var rem = 0;
      var computed = false;
      if (endStr != null && endStr.isNotEmpty) {
        try {
          rem = DateTime.parse(endStr).toUtc().difference(now).inSeconds;
          computed = true;
        } catch (_) {}
      }
      if (!computed && origDuration > 0) {
        final elapsed = now.difference(_lastTimerStartTime!.toUtc()).inSeconds;
        rem = (origDuration - elapsed).clamp(0, origDuration);
        computed = true;
      }
      remainingSeconds = rem < 0 ? 0 : rem;
      originalDuration = origDuration > 0 ? origDuration : null;
      if (remainingSeconds > 0) {
        activeStatus = 'LAST_TIMER';
        startTime = _lastTimerStartTime;
      } else {
        remainingSeconds = 0;
        await _finalizeLastTimerIfExpiredFromPrefs(prefs);
      }
    }
    
    // Try to load from SharedPreferences if not in memory
    if (activeStatus == 'Idle') {
      final startStatus = prefs.getString('start_timer_status');
      final lastStatus = prefs.getString('last_timer_status');
      
      if (startStatus == 'Running') {
        final startTimeStr = prefs.getString('start_timer_start_time');
        if (startTimeStr != null) {
          try {
            final savedStartTime = DateTime.parse(startTimeStr).toUtc();
            final now = DateTime.now().toUtc();
            final endUtcStr = prefs.getString('start_timer_end_utc');
            final origDuration = prefs.getInt('start_timer_original_duration') ?? 0;
            int rem;
            if (endUtcStr != null && endUtcStr.isNotEmpty) {
              rem = DateTime.parse(endUtcStr).toUtc().difference(now).inSeconds;
            } else if (origDuration > 0) {
              final elapsed = now.difference(savedStartTime).inSeconds;
              rem = (origDuration - elapsed).clamp(0, origDuration);
            } else {
              final duration = prefs.getInt('start_timer_duration') ?? 0;
              if (duration <= 0) {
                rem = 0;
              } else {
                final elapsed = now.difference(savedStartTime).inSeconds;
                rem = (duration - elapsed).clamp(0, duration);
              }
            }
            remainingSeconds = rem < 0 ? 0 : rem;
            originalDuration = origDuration > 0 ? origDuration : prefs.getInt('start_timer_original_duration');
            if (remainingSeconds > 0) {
              activeStatus = 'START_TIMER';
              startTime = savedStartTime;
              _startTimerStatus = 'Running';
              _startTimerStartTime = savedStartTime;
            } else {
              await prefs.setString('start_timer_status', 'Idle');
              await prefs.setInt('start_timer_duration', 0);
              _startTimerStatus = 'Idle';
              _startTimerStartTime = null;
            }
          } catch (e) {
            print('Error parsing start timer time: $e');
          }
        }
      } else if (lastStatus == 'Running') {
        final startTimeStr = prefs.getString('last_timer_start_time');
        if (startTimeStr != null) {
          try {
            final savedStartTime = DateTime.parse(startTimeStr).toUtc();
            final now = DateTime.now().toUtc();
            final endUtcStr = prefs.getString('last_timer_end_utc');
            final origDuration = prefs.getInt('last_timer_original_duration') ?? 0;
            int rem;
            if (endUtcStr != null && endUtcStr.isNotEmpty) {
              rem = DateTime.parse(endUtcStr).toUtc().difference(now).inSeconds;
            } else if (origDuration > 0) {
              final elapsed = now.difference(savedStartTime).inSeconds;
              rem = (origDuration - elapsed).clamp(0, origDuration);
            } else {
              rem = 0;
            }
            remainingSeconds = rem < 0 ? 0 : rem;
            originalDuration = origDuration > 0 ? origDuration : null;
            if (remainingSeconds > 0) {
              activeStatus = 'LAST_TIMER';
              startTime = savedStartTime;
              _lastTimerStatus = 'Running';
              _lastTimerStartTime = savedStartTime;
            } else {
              await _finalizeLastTimerIfExpiredFromPrefs(prefs);
            }
          } catch (e) {
            print('Error parsing last timer time: $e');
          }
        }
      }
    }
    
    await _finalizeLastTimerIfExpiredFromPrefs(prefs);
    
    final startStatus = prefs.getString('start_timer_status') ?? _startTimerStatus;
    final lastStatus = prefs.getString('last_timer_status') ?? _lastTimerStatus;

    return {
      'active_timer': activeStatus,
      'remaining_seconds': remainingSeconds ?? 0,
      'original_duration': originalDuration,
      'start_time': startTime?.toIso8601String(),
      'start_timer_status': startStatus,
      'last_timer_status': lastStatus,
    };
  } catch (e) {
    print('Error getting timer status: $e');
    return {
      'active_timer': 'Idle',
      'remaining_seconds': 0,
      'start_time': null,
      'start_timer_status': 'Idle',
      'last_timer_status': 'Idle',
    };
  }
}

class QuestionPage extends StatefulWidget {
  const QuestionPage({super.key});

  @override
  State<QuestionPage> createState() => _QuestionPageState();
}

class _QuestionPageState extends State<QuestionPage> with WidgetsBindingObserver {
  // Timer state - countdown timer
  Duration _remainingTime = const Duration(minutes: 45); // Initialize to total time
  Duration _totalTime = const Duration(minutes: 45);
  bool _isTimerRunning = false;
  bool _timerStarted = false; // Track if timer has been started
  
  // Store timer start time and original duration for direct calculation
  DateTime? _uiTimerStartTime;
  int? _uiTimerOriginalDuration;
  Timer? _tick;
  
  // Global timer counter down variable
  int timer_counter_down = 0;
  
  // Timer blinking state for red warning
  bool _isBlinking = false;
  Timer? _blinkTimer;
  
  // Game state
  String _gameName = "Current Game";
  String _roundName = ""; // Round name from timer message
  int _roundTimer = 0; // activeGame.round_timer or final_timer from timer message
  bool _roundModeActive = false; // type_game != 0 for this round (from game table)
  num _regScore = 1;
  num _regScoreTotal = 0;
  num _bonusScore = 0;
  num _bonusScoreTotal = 0;
  
  // Answer state
  List<Map<String, dynamic>> _answers = [];
  /// Bumped when [_answers] changes so list dialogs (shared pool) refresh disabled options.
  final ValueNotifier<int> _answerPoolRevision = ValueNotifier<int>(0);
  bool _isWriter = false;
  int? _currentQuestionId;
  final Map<int, GlobalKey> _answerItemKeys = {};
  final ScrollController _pageScrollController = ScrollController();
  
  // Writer status check timer
  Timer? _writerStatusCheckTimer;

  /// Game data cache, keyed by question ID (primary key from game table).
  Map<int, Map<String, dynamic>> _gameData = {};

  bool _questionBelongsToRound(Map<String, dynamic> question, String roundName) {
    return _roundNamesMatch(question['round_name'] as String?, roundName);
  }

  /// Backend LAST_TIMER uses type_game from the last question (by id) in the round.
  int _resolveTypeGameForRound(String roundName) {
    MapEntry<int, Map<String, dynamic>>? lastEntry;
    for (final entry in _gameData.entries) {
      if (!_questionBelongsToRound(entry.value, roundName)) continue;
      if (lastEntry == null || entry.key > lastEntry.key) {
        lastEntry = entry;
      }
    }
    if (lastEntry == null) return 0;
    return _parseRoundTimerField(lastEntry.value['type_game']);
  }

  /// Round mode only when the round's [type_game] (last question by id) is nonzero.
  bool _isRoundModeFor({required String roundName}) {
    return _resolveTypeGameForRound(roundName) != 0;
  }

  /// Round mode (type_game != 0): answers stay editable until the round is marked expired
  /// (LAST / final timer ended). Per-question START/STOP must not lock fields.
  bool _shouldEnableAnswerInRoundMode({
    required bool roundFinalTimerExpired,
    required String? questionRoundName,
    required String roundName,
  }) {
    if (roundFinalTimerExpired) return false;
    if (!_roundNamesMatch(questionRoundName, roundName)) return false;
    return true;
  }

  String _answersForSelectionKind(String? afs) {
    if (afs == null) return '';
    final t = afs.trim();
    if (t.isEmpty || t == '=') return '';
    final lower = t.toLowerCase();
    if (lower.startsWith('radio:')) return 'radio';
    if (lower.startsWith('list:')) return 'list';
    return '';
  }

  List<String> _optionsAfterAnswersForSelectionPrefix(String? afs) {
    if (afs == null) return [];
    final t = afs.trim();
    final lower = t.toLowerCase();
    String optionsString = '';
    if (lower.startsWith('radio:')) {
      optionsString = t.substring(6);
    } else if (lower.startsWith('list:')) {
      optionsString = t.substring(5);
    } else {
      return [];
    }
    return optionsString.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  bool _roundNamesMatch(String? questionRoundName, String roundName) {
    final a = (questionRoundName ?? '').trim();
    final b = roundName.trim();
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    return a.toLowerCase() == b.toLowerCase();
  }

  /// Count of nonempty cells in game.answer1…answer4; 0 nonempty → treat as single free-text slot.
  int _expectedAnswerSlotCount(Map<String, dynamic> question) {
    var c = 0;
    for (final key in ['answer1', 'answer2', 'answer3', 'answer4']) {
      final v = question[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        c++;
      }
    }
    return c == 0 ? 1 : c;
  }

  /// Comma-merged list tokens for shared-pool conflict checks (multislot list).
  String _listRawForConflictCheck(Map<String, dynamic> answer) {
    final sc = answer['slotCount'] as int? ?? 1;
    if (sc <= 1) {
      return (answer['value'] as String? ?? '').trim();
    }
    final sv = answer['slotValues'];
    if (sv is List) {
      final parts = sv.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      return parts.join(',');
    }
    return '';
  }

  List<String> _fourSlotValuesFromAnswerMap(Map<String, dynamic> answer) {
    final raw = answer['slotValues'];
    final out = List<String>.filled(4, '');
    if (raw is List) {
      for (var i = 0; i < raw.length && i < 4; i++) {
        out[i] = raw[i]?.toString() ?? '';
      }
    }
    return out;
  }

  String _compositeValueFromSlots(List<String> four, int slotCount) {
    final k = slotCount.clamp(1, 4);
    final parts = <String>[];
    for (var i = 0; i < k; i++) {
      parts.add(four[i].trim());
    }
    return parts.join('\n');
  }

  List<String> _slotValuesForPersist(Map<String, dynamic> answer) {
    final sc = answer['slotCount'] as int? ?? 1;
    final k = sc.clamp(1, 4);
    final four = _fourSlotValuesFromAnswerMap(answer);
    final v = answer['value'] as String?;
    if (four.every((e) => e.trim().isEmpty) && v != null && v.trim().isNotEmpty) {
      if (k <= 1) {
        four[0] = v;
      } else {
        final lines = v.split('\n');
        for (var i = 0; i < k && i < lines.length; i++) {
          four[i] = lines[i];
        }
      }
    }
    return four.take(k).map((e) => e.toString()).toList();
  }

  
  /// Reg/bonus scores may be fractional (e.g. 0.5) from DB or game table strings.
  static String _formatScoreDisplay(num v) {
    final d = v.toDouble();
    if ((d - d.round()).abs() < 1e-9) {
      return d.round().toString();
    }
    return d.toString();
  }

  // Current game name for persistent storage
  String _currentGameNameForStorage = '';
  
  // Auto-save timer (debounced)
  Timer? _autoSaveTimer;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    StrictVisibilityService.instance.init();

    // Check if page was refreshed
    // If so, navigate to main page (same as back button behavior)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !Navigator.canPop(context)) {
        print('QuestionPage: Page refreshed (no navigation history), redirecting to main page');
        Navigator.pushReplacementNamed(context, '/main');
        return;
      }
    });
    
    // Load current timer status from global state (will set timer_counter_down based on actual remaining time)
    _loadTimerStatus();
    _loadUserData();
    _initializeAnswers(1); // Default to 1 answer
    _startWriterStatusCheck();
    
    // Register this page to receive timer messages
    _globalTimerMessageHandler = _handleTimerTrigger;
    print('QuestionPage: Registered for timer messages');
    
    // Start periodic update to sync with global timer
    _startTimerSync();
    
    // Try to load question board from last_timer_setting if available
    _loadQuestionBoardFromLastTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncTimersAndEditabilityAfterResume());
    }
  }

  /// Mobile: JS timers / backgrounding can stall global ticks; LAST may end while away.
  /// Re-run prefs sync + finalize + editability when returning foreground.
  Future<void> _syncTimersAndEditabilityAfterResume() async {
    try {
      if (!mounted) {
        return;
      }
      await _loadTimerStatus();
      await _updateAnswerEditability();
    } catch (e) {
      print('QuestionPage: _syncTimersAndEditabilityAfterResume failed: $e');
    }
  }
  
  /// Load question board from last_timer_setting if available
  Future<void> _loadQuestionBoardFromLastTimer() async {
    try {
      print('QuestionPage: _loadQuestionBoardFromLastTimer called');
      final prefs = await SharedPreferences.getInstance();
      final lastTimerDataStr = prefs.getString('last_timer_action_data');
      print('QuestionPage: last_timer_action_data from SharedPreferences: ${lastTimerDataStr != null ? "exists (${lastTimerDataStr.length} chars)" : "null"}');
      
      if (lastTimerDataStr != null) {
        try {
          final lastTimerData = jsonDecode(lastTimerDataStr) as Map<String, dynamic>;
          print('QuestionPage: Parsed last_timer_action_data: $lastTimerData');
          final questionId = lastTimerData['question_id'];
          final roundName = lastTimerData['round_name'] as String?;
          
          print('QuestionPage: Extracted question_id=$questionId, round_name=$roundName');
          
          if (roundName != null && roundName.isNotEmpty) {
            print('QuestionPage: Loading question board from last_timer_setting: question_id=$questionId, round_name=$roundName');
            // Wait a bit for the page to be fully initialized
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) {
              print('QuestionPage: Calling build_question_board with last_timer_data');
              await build_question_board(lastTimerData);
            } else {
              print('QuestionPage: Widget not mounted, skipping build_question_board');
            }
          } else {
            print('QuestionPage: Invalid round_name - roundName=$roundName');
          }
        } catch (e) {
          print('QuestionPage: Error loading question board from last_timer_setting: $e');
          print('QuestionPage: Stack trace: ${StackTrace.current}');
        }
      } else {
        print('QuestionPage: No last_timer_action_data found in SharedPreferences');
      }
    } catch (e) {
      print('QuestionPage: Error in _loadQuestionBoardFromLastTimer: $e');
      print('QuestionPage: Stack trace: ${StackTrace.current}');
    }
  }
  
  // Load timer status from global state
  Future<void> _loadTimerStatus() async {
    try {
      final status = await getCurrentTimerStatus();
      final activeTimer = status['active_timer'] as String;
      final remainingSeconds = status['remaining_seconds'] as int;
      final originalDuration = status['original_duration'] as int?;
      
      print('_loadTimerStatus: activeTimer=$activeTimer, remainingSeconds=$remainingSeconds, originalDuration=$originalDuration');
      
      if (mounted) {
        setState(() {
          if (activeTimer == 'START_TIMER' || activeTimer == 'LAST_TIMER') {
            timer_counter_down = remainingSeconds;
            _remainingTime = Duration(seconds: remainingSeconds);
            
            // Always use original duration for total time when available
            // This ensures progress bar shows correct countdown
            if (originalDuration != null && originalDuration > 0) {
              _totalTime = Duration(seconds: originalDuration);
              print('_loadTimerStatus: Set _totalTime to originalDuration=$originalDuration (from timer status)');
            } else {
              // Fallback: use remaining if no original duration available
              _totalTime = Duration(seconds: remainingSeconds);
              print('_loadTimerStatus: Set _totalTime to remainingSeconds=$remainingSeconds (fallback, no original duration)');
            }
            
            _timerStarted = true;
            _isTimerRunning = remainingSeconds > 0;
            
            print('_loadTimerStatus: Final values - _totalTime=${_totalTime.inSeconds}s, _remainingTime=${_remainingTime.inSeconds}s, progress=${_totalTime.inSeconds > 0 ? (_remainingTime.inSeconds / _totalTime.inSeconds) : 0}');
            
            // Start local timer to update UI
            if (remainingSeconds > 0) {
              _startLocalTimer(remainingSeconds, _totalTime.inSeconds);
            }
          } else {
            timer_counter_down = 0;
            _remainingTime = Duration.zero;
            _totalTime = Duration.zero;
            _timerStarted = false;
            _isTimerRunning = false;
          }
        });
      }
    } catch (e) {
      print('Error loading timer status: $e');
    }
  }
  
  // Start local timer for UI updates (calculates based on real time difference)
  void _startLocalTimer(int remainingSeconds, int originalDuration) async {
    _tick?.cancel();
    _blinkTimer?.cancel();
    
    // Get the most current status from global timer to get timer_start time
    final currentStatus = await getCurrentTimerStatus();
    final currentOriginal = currentStatus['original_duration'] as int? ?? originalDuration;
    final startTimeStr = currentStatus['start_time'] as String?;
    DateTime? startTime;
    if (startTimeStr != null) {
      try {
        startTime = DateTime.parse(startTimeStr).toUtc();
      } catch (e) {
        print('Error parsing start_time: $e');
      }
    }
    
    if (startTime == null || currentOriginal <= 0) {
      setState(() {
        timer_counter_down = 0;
        _remainingTime = Duration.zero;
        _isTimerRunning = false;
        _uiTimerStartTime = null;
        _uiTimerOriginalDuration = null;
      });
      return;
    }
    
    // Store timer start time and original duration for direct calculation
    _uiTimerStartTime = startTime;
    _uiTimerOriginalDuration = currentOriginal;
    
    // Calculate remaining time directly from timer_start (accounts for any delay)
    // This ensures the first display immediately accounts for the 2-3 second delay
    final now = DateTime.now().toUtc();
    final elapsed = now.difference(_uiTimerStartTime!).inSeconds;
    final calculatedRemaining = (currentOriginal - elapsed).clamp(0, currentOriginal);
    
    // Set initial values immediately based on real time calculation
    // This accounts for the delay by showing the correct remaining time right away
    if (mounted) {
      setState(() {
        timer_counter_down = calculatedRemaining;
        _totalTime = Duration(seconds: currentOriginal); // Use original duration for progress bar
        _remainingTime = Duration(seconds: calculatedRemaining);
        _isTimerRunning = calculatedRemaining > 0;
        _isBlinking = false;
      });
    }
    
    print('_startLocalTimer: Starting UI timer with startTime=$startTime, original=$currentOriginal, elapsed=$elapsed, calculated remaining=$calculatedRemaining (accounts for delay)');
    
    // Start independent countdown timer that calculates based on real time difference
    // Update immediately, then every second
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _uiTimerStartTime == null || _uiTimerOriginalDuration == null) {
        timer.cancel();
        return;
      }
      
      // Calculate remaining time directly from timer_start and current time
      // This ensures accuracy and accounts for any delays
      final now = DateTime.now().toUtc();
      final elapsed = now.difference(_uiTimerStartTime!).inSeconds;
      final remaining = (_uiTimerOriginalDuration! - elapsed).clamp(0, _uiTimerOriginalDuration!);
      
      if (remaining <= 0) {
        setState(() {
          timer_counter_down = 0;
          _remainingTime = Duration.zero;
          _isTimerRunning = false;
          _stopBlinking();
          _uiTimerStartTime = null;
          _uiTimerOriginalDuration = null;
        });
        timer.cancel();
      } else {
        setState(() {
          timer_counter_down = remaining;
          _remainingTime = Duration(seconds: remaining);
          _totalTime = Duration(seconds: _uiTimerOriginalDuration!);
          
          // Start blinking when timer reaches 5 seconds
          if (remaining == 5 && _uiTimerOriginalDuration! > 2) {
            _startBlinking();
          }
          
          // Stop blinking when timer reaches 0
          if (remaining == 0) {
            _stopBlinking();
            _isTimerRunning = false;
          }
        });
      }
    });
  }
  
  // Start periodic sync with global timer
  void _startTimerSync() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      getCurrentTimerStatus().then((status) {
        final activeTimer = status['active_timer'] as String;
        final remainingSeconds = status['remaining_seconds'] as int;
        final originalDuration = status['original_duration'] as int?;
        
        if (mounted) {
          setState(() {
            if (activeTimer == 'START_TIMER' || activeTimer == 'LAST_TIMER') {
              // Always update if values changed
              if (remainingSeconds != timer_counter_down || 
                  (originalDuration != null && _totalTime.inSeconds != originalDuration)) {
                timer_counter_down = remainingSeconds;
                _remainingTime = Duration(seconds: remainingSeconds);
                // Always use original duration for total time when available
                if (originalDuration != null && originalDuration > 0) {
                  _totalTime = Duration(seconds: originalDuration);
                }
                _isTimerRunning = remainingSeconds > 0;
                _timerStarted = true;
                
                // Debug log occasionally
                if (remainingSeconds % 5 == 0 || remainingSeconds < 5) {
                  print('_startTimerSync: Updated - remaining=$remainingSeconds, total=${_totalTime.inSeconds}, progress=${_totalTime.inSeconds > 0 ? (remainingSeconds / _totalTime.inSeconds) : 0}');
                }
              }
            } else {
              if (_isTimerRunning || _timerStarted) {
                timer_counter_down = 0;
                _remainingTime = Duration.zero;
                _totalTime = Duration.zero;
                _isTimerRunning = false;
                _timerStarted = false;
                _tick?.cancel();
              }
            }
          });
          
          // Update answer editability when timer status changes
          _updateAnswerEditability();
        }
      });
    });
  }
  
  /// Update answer editability based on current timer status
  Future<void> _updateAnswerEditability() async {
    try {
      final timerSnapshot = await getCurrentTimerStatus();
      final startTimerStatus =
          timerSnapshot['start_timer_status'] as String? ?? 'Idle';

      // Get question_id from last_timer_setting or current message
      final prefs = await SharedPreferences.getInstance();
      final lastTimerDataStr = prefs.getString('last_timer_action_data');
      dynamic questionId;
      String? roundName;
      
      if (lastTimerDataStr != null) {
        try {
          final lastTimerData = jsonDecode(lastTimerDataStr) as Map<String, dynamic>;
          questionId = lastTimerData['question_id'];
          roundName = lastTimerData['round_name'] as String?;
        } catch (e) {
          print('Error parsing last_timer_action_data: $e');
        }
      }
      if ((roundName == null || roundName.isEmpty) && _roundName.isNotEmpty) {
        roundName = _roundName;
      }
      if (roundName == null) {
        return;
      }

      final roundMode = _isRoundModeFor(roundName: roundName);
      _roundModeActive = roundMode;
      var roundTimer = 0;
      if (roundMode) {
        roundTimer = _roundTimer;
        if (roundTimer == 0) {
          roundTimer = await _resolveRoundTimerFromPrefsOnly();
          if (roundTimer != 0) {
            _roundTimer = roundTimer;
          }
        }
      } else {
        _roundTimer = 0;
      }

      final intQuestionId = questionId is int
          ? questionId
          : (questionId is String ? int.tryParse(questionId) : int.tryParse('$questionId'));
      if (!roundMode && intQuestionId == null) {
        return;
      }
      
      // If this round's final timer has expired (persisted), keep all fields disabled
      final roundFinalTimerExpired = await _isRoundFinalTimerExpired(roundName);

      // Update editability for each answer
      bool needsUpdate = false;
      for (var i = 0; i < _answers.length; i++) {
        final answer = _answers[i];
        final qId = answer['id'] as int;
        final question = _gameData[qId];
        if (question == null) continue;
        
        final questionRoundName = question['round_name'] as String?;
        
        bool shouldBeEnabled = false;
        if (roundMode) {
          if (_shouldEnableAnswerInRoundMode(
                roundFinalTimerExpired: roundFinalTimerExpired,
                questionRoundName: questionRoundName,
                roundName: roundName,
              )) {
            shouldBeEnabled = true;
          }
        } else {
          if (startTimerStatus == 'Running' && intQuestionId != null && qId == intQuestionId) {
            shouldBeEnabled = true;
          }
        }
        
        if (answer['enabled'] != shouldBeEnabled) {
          _answers[i]['enabled'] = shouldBeEnabled;
          needsUpdate = true;
        }
      }
      
      if (needsUpdate && mounted) {
        print(
          'QuestionPage: _updateAnswerEditability roundMode=$roundMode roundTimer=$_roundTimer '
          'start=$startTimerStatus qId=$intQuestionId '
          'roundExpired=$roundFinalTimerExpired enabled='
          '${_answers.where((a) => a['enabled'] == true).length}/${_answers.length}',
        );
        setState(() {
          // Trigger rebuild
        });
      }
    } catch (e) {
      print('Error updating answer editability: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Cancel local UI timers (but NOT global timers - they continue in background)
    _tick?.cancel();
    _writerStatusCheckTimer?.cancel();
    _blinkTimer?.cancel();
    _autoSaveTimer?.cancel();

    _pageScrollController.dispose();
    _answerPoolRevision.dispose();
    // Save answers before disposing
    _saveAnswers();
    
    // Unregister timer message handler
    if (_globalTimerMessageHandler == _handleTimerTrigger) {
      _globalTimerMessageHandler = null;
      print('QuestionPage: Unregistered from timer messages');
    }
    
    // Note: Global timers continue running in background even after page disposal
    print('QuestionPage: Disposed, but global timers continue running');
    
    super.dispose();
  }
  
  /// Trigger auto-save with debounce (saves after 2 seconds of no changes)
  void _triggerAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      _saveAnswers();
    });
  }

  Future<void> _loadUserData() async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData != null) {
        setState(() {
          _isWriter = userData['writer'] == true;
        });
      }
    } catch (e) {
      print('Error loading user data: $e');
    }
  }

  void _startWriterStatusCheck() {
    // Check writer status every 5 seconds
    _writerStatusCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkWriterStatus();
    });
  }

  Future<void> _checkWriterStatus() async {
    try {
      final echoResult = await DatabaseService.sendEchoCall(
        StrictVisibilityService.instance.isStrictVisible,
        source: 'periodic',
      );
      
      if (echoResult['success'] == true) {
        // Handle writer status changes
        final writerStatus = echoResult['writer_status'];
        if (writerStatus != null) {
          final isWriter = writerStatus['is_writer'] ?? false;
          
          // Update writer status if it changed
          if (mounted && _isWriter != isWriter) {
            setState(() {
              _isWriter = isWriter;
            });
            print('QuestionPage: Writer status updated to: $_isWriter');
            
            // Show notification if writer status changed
            if (isWriter) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('You are now the writer for your team'),
                  duration: Duration(seconds: 3),
                  backgroundColor: Colors.green,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Writer privilege has been turned OFF'),
                  duration: Duration(seconds: 3),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      print('Error checking writer status: $e');
    }
  }

  void _initializeAnswers(int count) {
    setState(() {
      _answers = List.generate(count, (index) => {
        'id': index + 1,
        'num': 1, // Default number
        'inputType': 'text', // 'radio', 'list', or 'text'
        'options': <String>[], // For radio/list types
        'value': '', // For text type or selected value
        'selected': false, // Checkbox state
      });
    });
  }

  // Placeholder methods for future implementation
  Future<void> get_question_results() async {
    // TODO: Implement get_question_results
  }

  Future<void> get_game_for_round() async {
    // TODO: Implement get_game_for_round
  }

  Future<void> build_question_board(Map<String, dynamic> message) async {
    try {
      print('QuestionPage: build_question_board called with message: $message');
      
      // Get question_id from message or from last_timer_setting
      dynamic questionId = message['question_id'];
      String? roundName = message['round_name'] as String?;
      
      print('QuestionPage: Initial question_id=$questionId, roundName=$roundName');
      
      // If question_id or round_name is missing, try to get from last_timer_setting
      if (questionId == null || roundName == null) {
        print('QuestionPage: question_id or roundName is null, checking SharedPreferences');
        final prefs = await SharedPreferences.getInstance();
        final lastTimerDataStr = prefs.getString('last_timer_action_data');
        if (lastTimerDataStr != null) {
          try {
          final lastTimerData = jsonDecode(lastTimerDataStr) as Map<String, dynamic>;
          questionId = questionId ?? lastTimerData['question_id'];
          roundName = roundName ?? lastTimerData['round_name'] as String?;
          print('QuestionPage: Retrieved question_id=$questionId, round_name=$roundName from last_timer_setting');
          } catch (e) {
            print('QuestionPage: Error parsing last_timer_action_data: $e');
          }
        } else {
          print('QuestionPage: No last_timer_action_data in SharedPreferences');
        }
      }
      
      if (roundName == null || roundName.isEmpty) {
        print('QuestionPage: round_name is null or empty in message and last_timer_setting, returning');
        return;
      }
      
      print('QuestionPage: Building question board for round: $roundName, question_id: $questionId');
      
      // Get active game to get game name
      print('QuestionPage: Getting active game...');
      final activeGame = await _getActiveGame();
      if (activeGame == null) {
        print('QuestionPage: No active game found');
        return;
      }
      
      print('QuestionPage: Active game found: ${activeGame['game_name']}');
      
      final gameName = activeGame['game_name'] as String?;
      if (gameName == null) {
        print('QuestionPage: Game name is null');
        return;
      }
      
      // If question_id is 0, get the last question_id from action_game_control for this round_name
      if (questionId == null || questionId == 0) {
        print('QuestionPage: question_id is 0, retrieving from action_game_control for round_name: $roundName');
        final gameNameSafe = gameName.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
        final controlData = await DatabaseService.getActionGameControlByRound(gameNameSafe, roundName);
        
        if (controlData == null) {
          print('QuestionPage: No action_game_control data found for round_name: $roundName, not showing widgets');
          return;
        }
        
        final controlQuestionId = controlData['question_id'];
        print('QuestionPage: Retrieved question_id=$controlQuestionId from action_game_control for round_name: $roundName');
        
        // Use the question_id from control table, but we'll still show all questions in the round
        questionId = controlQuestionId;
      }
      
      print('QuestionPage: Game name: $gameName');

      final int? resolvedQuestionId = questionId is int
          ? questionId
          : int.tryParse(questionId?.toString() ?? '');
      
      // Update current game name for storage
      _currentGameNameForStorage = gameName;
      
      // Load game data into cache if not already loaded or if round changed
      final currentRound = _gameData.isNotEmpty 
          ? _gameData.values.first['round_name'] as String?
          : null;
      print('QuestionPage: Current round in cache: $currentRound, requested round: $roundName');
      
      if (_gameData.isEmpty || currentRound != roundName) {
        print('QuestionPage: Loading game data into cache for round: $roundName');
        await _loadGameDataIntoCache(gameName, roundName);
        print('QuestionPage: Loaded ${_gameData.length} questions into cache');
      } else {
        print('QuestionPage: Using cached game data (${_gameData.length} questions)');
      }

      // Round-scoped API can return nothing (e.g. round_name mismatch) while timer already has question_id
      if (resolvedQuestionId != null &&
          resolvedQuestionId > 0 &&
          !_gameData.containsKey(resolvedQuestionId)) {
        print(
          'QuestionPage: question id=$resolvedQuestionId missing from cache '
          '(keys=${_gameData.keys.toList()}); fetching by id',
        );
        final row = await DatabaseService.getGameQuestionById(gameName, resolvedQuestionId);
        if (row != null) {
          _gameData[resolvedQuestionId] = row;
          print(
            'QuestionPage: Cached question $resolvedQuestionId '
            '(round_name=${row['round_name']}, type_game=${row['type_game']})',
          );
        }
      }

      if (_gameData.isEmpty && resolvedQuestionId != null && resolvedQuestionId > 0) {
        print('QuestionPage: Round query empty; fetching question id=$resolvedQuestionId via question-by-id API');
        final row = await DatabaseService.getGameQuestionById(gameName, resolvedQuestionId);
        if (row != null) {
          _gameData[resolvedQuestionId] = row;
          print('QuestionPage: Cached question $resolvedQuestionId (round_name=${row['round_name']})');
        }
      }

      int msgQTimer = 0;
      final msgQTimerRaw = message['question_timer'];
      if (msgQTimerRaw is int) {
        msgQTimer = msgQTimerRaw;
      } else if (msgQTimerRaw != null) {
        msgQTimer = int.tryParse(msgQTimerRaw.toString()) ?? 0;
      }
      if (msgQTimer <= 0 &&
          resolvedQuestionId != null &&
          resolvedQuestionId > 0 &&
          _gameData.containsKey(resolvedQuestionId)) {
        final ttaRaw = _gameData[resolvedQuestionId]!['time_to_get_answer'];
        var tta = 0;
        if (ttaRaw is int) {
          tta = ttaRaw;
        } else if (ttaRaw != null) {
          tta = int.tryParse(ttaRaw.toString()) ?? 0;
        }
        if (tta > 0) {
          print('QuestionPage: Re-applying global START timer with time_to_get_answer=$tta from game data');
          await reapplyGlobalStartTimerFromGameData(message, tta);
          if (mounted) await _loadTimerStatus();
        }
      }
      
      // Get user's team ID
      final userData = await UserDataService.getUserData();
      final teamIdRaw = userData?['playing_in_team_id'];
      if (teamIdRaw == null) {
        print('QuestionPage: User has no team ID');
        return;
      }
      
      // Convert team ID to string for storage key (handles both int and string)
      final teamId = teamIdRaw.toString();
      print('QuestionPage: Team ID: $teamId');
      
      // Load saved answers from persistent storage
      print('QuestionPage: Loading saved answers...');
      final savedAnswers = await _loadSavedAnswers(gameName, teamId);
      print('QuestionPage: Loaded ${savedAnswers.length} saved answers');
      
      // Store round name for display; clear stale round-timer cache when the round changes
      print('QuestionPage: Setting round name to: $roundName');
      final prefsForRound = await SharedPreferences.getInstance();
      if (roundName.isNotEmpty && _roundName.isNotEmpty && !_roundNamesMatch(_roundName, roundName)) {
        await prefsForRound.remove('cached_round_timer');
        _roundModeActive = false;
        _roundTimer = 0;
        print(
          'QuestionPage: Round switched "$_roundName" -> "$roundName", cleared cached_round_timer',
        );
      }
      setState(() {
        _roundName = roundName ?? "";
      });
      
      // Load team answers from database (active_teams_answers table)
      print('QuestionPage: Loading team answers from database...');
      final gameNameSafe = gameName.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
      final teamIdInt = int.tryParse(teamId);
      List<Map<String, dynamic>> teamAnswersFromDb = [];
      if (teamIdInt != null) {
        teamAnswersFromDb = await DatabaseService.getTeamAnswersForGame(gameNameSafe, teamIdInt);
        print('QuestionPage: Loaded ${teamAnswersFromDb.length} team answers from database');
      }
      
      // Merge final_timer from timer message into activeGame (API may not return round_timer).
      // Per-slide START_TIME often omits final_timer — do not overwrite a nonzero cache with 0.
      final prevCachedRt = prefsForRound.getInt('cached_round_timer') ?? 0;
      final effectiveActiveGame = Map<String, dynamic>.from(activeGame);
      final msgFinalTimer = message['final_timer'];
      if (msgFinalTimer != null) {
        final v = msgFinalTimer is int ? msgFinalTimer : int.tryParse(msgFinalTimer.toString());
        if (v != null && v != 0) {
          effectiveActiveGame['round_timer'] = v;
          print('QuestionPage: Using final_timer=$v from message as round_timer');
        }
      }
      final tgFromGame = _resolveTypeGameForRound(roundName);
      final classicRound = tgFromGame == 0;
      if (classicRound) {
        await prefsForRound.remove('cached_round_timer');
        effectiveActiveGame['round_timer'] = 0;
        print('QuestionPage: type_game=0 (classic) — cleared cached_round_timer');
      } else {
        if (_parseRoundTimerField(effectiveActiveGame['round_timer']) == 0 && prevCachedRt != 0) {
          effectiveActiveGame['round_timer'] = prevCachedRt;
          print(
            'QuestionPage: Preserved round_timer=$prevCachedRt (slide had no nonzero final_timer)',
          );
        }
        if (_parseRoundTimerField(effectiveActiveGame['round_timer']) == 0) {
          effectiveActiveGame['round_timer'] = tgFromGame.abs();
          print(
            'QuestionPage: Using type_game=$tgFromGame from game data as round_timer',
          );
        }
        var rtc = _parseRoundTimerField(effectiveActiveGame['round_timer']);
        if (rtc != 0) {
          await prefsForRound.setInt('cached_round_timer', rtc);
        }
      }

      // Build answers list from game data and saved answers
      print('QuestionPage: Building answers from game data...');
      await _buildAnswersFromGameData(roundName, questionId, savedAnswers, effectiveActiveGame, teamAnswersFromDb);
      print('QuestionPage: Built ${_answers.length} answers');
      
      // Update game info with specific question data
      print('QuestionPage: Updating game info for question_id: $questionId');
      await _updateGameInfo(activeGame, questionId);
      print('QuestionPage: Game info updated - _gameName=$_gameName, _roundName=$_roundName, _regScore=$_regScore/$_regScoreTotal, _bonusScore=$_bonusScore/$_bonusScoreTotal');
      
    } catch (e, stackTrace) {
      print('QuestionPage: Error in build_question_board: $e');
      print('QuestionPage: Stack trace: $stackTrace');
    }
  }
  
  /// Load all game data for a round into the cache dictionary
  /// Key: question ID (primary key), Value: all row data as Map
  Future<void> _loadGameDataIntoCache(String gameName, String roundName) async {
    try {
      print('QuestionPage: Loading game data into cache for game: $gameName, round: $roundName');
      
      final gameDataList = await DatabaseService.getGameQuestionsByRound(gameName, roundName);
      print('QuestionPage: Received ${gameDataList.length} questions from API');
      
      if (gameDataList.isEmpty) {
        print('QuestionPage: WARNING - No questions returned from API for game: $gameName, round: $roundName');
      }
      
      // Clear existing cache
      _gameData.clear();
      
      // Populate cache with question ID as key
      for (var question in gameDataList) {
        // Handle question ID as both int and string
        dynamic questionIdValue = question['id'];
        int? questionId;
        if (questionIdValue is int) {
          questionId = questionIdValue;
        } else if (questionIdValue is String) {
          questionId = int.tryParse(questionIdValue);
        } else if (questionIdValue != null) {
          questionId = int.tryParse(questionIdValue.toString());
        }
        
        if (questionId != null) {
          _gameData[questionId] = Map<String, dynamic>.from(question);
          print('QuestionPage: Cached question ID: $questionId, question_num: ${question['question_num']}, round_name: ${question['round_name']}');
        } else {
          print('QuestionPage: WARNING - Question missing ID: $question');
        }
      }
      
      print('QuestionPage: Loaded ${_gameData.length} questions into cache');
    } catch (e, stackTrace) {
      print('QuestionPage: Error loading game data into cache: $e');
      print('QuestionPage: Stack trace: $stackTrace');
    }
  }
  
  /// Convert savedAnswers map to _answers list format
  List<Map<String, dynamic>> _savedAnswersToAnswersList(Map<int, Map<String, dynamic>> savedAnswers) {
    final result = <Map<String, dynamic>>[];
    for (final entry in savedAnswers.entries) {
      final qId = entry.key;
      final answerData = entry.value;
      Map<String, dynamic>? questionData;
      if (_gameData.containsKey(qId)) {
        questionData = _gameData[qId];
      }
      final kSlots = questionData != null ? _expectedAnswerSlotCount(questionData) : 1;
      List<String> four = ['', '', '', ''];
      final sv = answerData['slotValues'];
      if (sv is List) {
        for (var i = 0; i < sv.length && i < 4; i++) {
          four[i] = sv[i]?.toString() ?? '';
        }
      } else if (answerData['answer'] is String &&
          ((answerData['answer'] as String).trim()).isNotEmpty) {
        final s = answerData['answer'] as String;
        if (kSlots <= 1) {
          four[0] = s;
        } else {
          final ls = s.split('\n');
          for (var i = 0; i < kSlots && i < ls.length; i++) {
            four[i] = ls[i];
          }
        }
      }
      final composite = _compositeValueFromSlots(four, kSlots);

      result.add({
        'id': qId,
        'num': questionData?['question_num'] ?? qId,
        'inputType': 'text',
        'options': [],
        'slotCount': kSlots,
        'slotValues': four,
        'value': composite,
        'selected': answerData['selected'] as bool? ?? false,
        'enabled': false,
        'checkboxEnabled': false,
      });
    }
    return result;
  }

  int _parseRoundTimerField(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return int.tryParse(v.toString()) ?? 0;
  }

  /// API often omits [round_timer]. Resolve from prefs/type_game only when [type_game] != 0.
  Future<int> _resolveRoundTimer(
    Map<String, dynamic> activeGame, {
    String? roundName,
  }) async {
    if (roundName != null &&
        roundName.isNotEmpty &&
        _resolveTypeGameForRound(roundName) == 0) {
      return 0;
    }
    var rt = _parseRoundTimerField(activeGame['round_timer']);
    if (rt != 0) return rt.abs();
    rt = await _resolveRoundTimerFromPrefsOnly();
    if (rt != 0) {
      print('QuestionPage: _resolveRoundTimer using prefs (cached/final_timer)=$rt');
      return rt.abs();
    }
    if (roundName != null && roundName.isNotEmpty) {
      final tg = _resolveTypeGameForRound(roundName);
      if (tg != 0) {
        print('QuestionPage: _resolveRoundTimer using type_game=$tg from game data (round=$roundName)');
        return tg.abs();
      }
    }
    return 0;
  }

  /// Build answers list from cached game data and saved answers
  Future<void> _buildAnswersFromGameData(
    String roundName,
    dynamic questionId,
    Map<int, Map<String, dynamic>> savedAnswers,
    Map<String, dynamic> activeGame,
    List<Map<String, dynamic>> teamAnswersFromDb,
  ) async {
    // Get game name for saving answers
    final gameName = activeGame['game_name'] as String? ?? 'Current Game';
    try {
      print('QuestionPage: _buildAnswersFromGameData called - roundName=$roundName, questionId=$questionId, savedAnswers count=${savedAnswers.length}, gameData count=${_gameData.length}');
      final mergedAnswers = <Map<String, dynamic>>[];
      
      // Get timer status to determine editability
      final timerStatus = await getCurrentTimerStatus();
      var startTimerStatus = timerStatus['start_timer_status'] as String? ?? 'Idle';
      var lastTimerStatus = timerStatus['last_timer_status'] as String? ?? 'Idle';
      final activeTimer = timerStatus['active_timer'] as String? ?? 'Idle';
      
      // Round mode only when type_game != 0 on the round (classic: one question per START timer).
      final typeGame = _resolveTypeGameForRound(roundName);
      final roundMode = _isRoundModeFor(roundName: roundName);
      var roundTimer = 0;
      if (roundMode) {
        roundTimer = await _resolveRoundTimer(activeGame, roundName: roundName);
        if (roundTimer == 0 && typeGame != 0) {
          roundTimer = typeGame.abs();
        }
        if (roundTimer != 0) {
          final prefsRt = await SharedPreferences.getInstance();
          await prefsRt.setInt('cached_round_timer', roundTimer);
        }
      } else {
        final prefsRt = await SharedPreferences.getInstance();
        await prefsRt.remove('cached_round_timer');
        roundTimer = 0;
      }
      _roundModeActive = roundMode;
      _roundTimer = roundTimer;

      // If this round's final timer has expired (persisted), treat as Stopped so fields stay disabled
      final roundFinalTimerExpired = await _isRoundFinalTimerExpired(roundName);
      if (roundFinalTimerExpired && roundMode) {
        lastTimerStatus = 'Stopped';
        print('QuestionPage: Round "$roundName" final timer expired (persisted), keeping fields disabled');
      }

      print(
        'QuestionPage: roundTimer=$roundTimer typeGame=$typeGame roundMode=$roundMode '
        'start=$startTimerStatus last=$lastTimerStatus active=$activeTimer '
        'roundExpired=$roundFinalTimerExpired (round-mode editability)',
      );
      
      // Convert questionId to int for comparison
      final intQuestionId = questionId is int ? questionId : (questionId is String ? int.tryParse(questionId) : null);
      print('QuestionPage: intQuestionId=$intQuestionId (from questionId: $questionId, type: ${questionId.runtimeType})');
      
      // Filter questions based on round_timer and question_id:
      // - If round_timer != 0: ADD the current question to existing (incremental); all stay enabled until last_timer stops
      // - If round_timer == 0 AND question_id == 0: don't publish questions (save existing answers instead)
      // - If round_timer == 0 AND question_id != 0: publish only the current question based on question_id
      final questionsToProcess = <MapEntry<int, Map<String, dynamic>>>[];
      
      // Get all questions in the round
      final roundQuestions = _gameData.entries
          .where((entry) => _questionBelongsToRound(entry.value, roundName))
          .toList();
      
      if (roundMode) {
        // Show every question in this round — answers remain editable until final timer ends
        questionsToProcess.addAll(roundQuestions);
        questionsToProcess.sort((a, b) {
          final numA = a.value['question_num'];
          final numB = b.value['question_num'];
          final nA = numA is int ? numA : int.tryParse(numA.toString()) ?? 0;
          final nB = numB is int ? numB : int.tryParse(numB.toString()) ?? 0;
          return nA.compareTo(nB);
        });
        print('QuestionPage: round mode, publishing all ${questionsToProcess.length} questions in round');
      } else {
        // Classic mode (type_game == 0)
        if (intQuestionId != null && intQuestionId != 0) {
          if (_gameData.containsKey(intQuestionId)) {
            questionsToProcess.add(MapEntry(intQuestionId, _gameData[intQuestionId]!));
            print('QuestionPage: classic mode, publishing only question_id=$intQuestionId');
          } else {
            print(
              'QuestionPage: WARNING - classic mode, question_id=$intQuestionId not found in gameData '
              '(keys=${_gameData.keys.toList()})',
            );
          }
        } else {
          // If question_id == 0: don't publish questions, but save existing answers
          print('QuestionPage: round_timer == 0 AND question_id == 0, not publishing questions - saving existing answers instead');
          
          // Save existing answers locally - prefer _answers (current edits) over savedAnswers
          final toSave = _answers.isNotEmpty ? _answers : _savedAnswersToAnswersList(savedAnswers);
          if (toSave.isNotEmpty) {
            print('QuestionPage: Saving ${toSave.length} answers...');
            
            final answersToSave = toSave.map((a) {
              final qId = a['id'];
              final qIdInt = qId is int ? qId : int.tryParse(qId?.toString() ?? '');
              Map<String, dynamic>? questionData;
              if (qIdInt != null && _gameData.containsKey(qIdInt)) {
                questionData = _gameData[qIdInt];
              }
              final ks = questionData != null ? _expectedAnswerSlotCount(questionData) : (a['slotCount'] as int? ?? 1);
              List<String> four = _fourSlotValuesFromAnswerMap(a);
              final vSingle = a['value'] as String? ?? '';
              if (four.every((e) => e.trim().isEmpty) && vSingle.trim().isNotEmpty) {
                final lines = vSingle.split('\n');
                for (var i = 0; i < ks && i < lines.length && i < 4; i++) {
                  four[i] = lines[i];
                }
              }

              return <String, dynamic>{
                'id': qId,
                'num': questionData?['question_num'] ?? qId,
                'inputType': a['inputType'] ?? 'text',
                'options': a['options'] ?? [],
                'slotCount': ks,
                'slotValues': four,
                'value': _compositeValueFromSlots(four, ks),
                'selected': a['selected'] as bool? ?? false,
                'enabled': false,
                'checkboxEnabled': false,
              };
            }).toList();
            
            // Temporarily set _answers and game name for saving
            final previousGameName = _currentGameNameForStorage;
            setState(() {
              _answers = answersToSave;
              _currentGameNameForStorage = gameName;
            });
            
            // Save to local storage
            await _saveAnswers();
            
            // Restore previous state (empty since we're not publishing)
            setState(() {
              _answers = [];
              _currentGameNameForStorage = previousGameName;
            });
            
            print('QuestionPage: Saved ${answersToSave.length} existing answers locally');
            
            // TODO: Update answers in active_teams_answers_<game> table in backend
            // This requires a backend API endpoint to update team answers
            print('QuestionPage: NOTE - Backend update for active_teams_answers table not yet implemented');
          } else {
            print('QuestionPage: No existing answers to save');
          }
          
          // Don't add any questions to process - empty list means no questions published
          // Set empty answers list
          setState(() {
            _answers = [];
          });
          return; // Exit early, no questions to process
        }
      }
      
      // First List: question in round (by question_num) supplies canonical options when round has final round timer
      var canonicalListForRound = <String>[];
      if (roundMode) {
        final rq = _gameData.entries
            .where((e) => _questionBelongsToRound(e.value, roundName))
            .toList();
        rq.sort((a, b) {
          final aNum = a.value['question_num'];
          final bNum = b.value['question_num'];
          final nA = aNum is int ? aNum : int.tryParse(aNum.toString()) ?? 0;
          final nB = bNum is int ? bNum : int.tryParse(bNum.toString()) ?? 0;
          return nA.compareTo(nB);
        });
        for (final e in rq) {
          final afs = e.value['answers_for_selection'] as String?;
          if (_answersForSelectionKind(afs) == 'list') {
            canonicalListForRound = _optionsAfterAnswersForSelectionPrefix(afs);
            break;
          }
        }
      }

      // Process each question from filtered list
      for (var entry in questionsToProcess) {
        final qId = entry.key;
        final question = entry.value;
        print('QuestionPage: Processing question ID: $qId (type: ${qId.runtimeType})');

        _answerItemKeys.putIfAbsent(qId, () => GlobalKey());
        
        // Round mode: only LAST / round expiry gates editing — question START expiry does not.
        bool isEnabled = false;
        final questionRoundName = question['round_name'] as String?;
        if (roundMode) {
          if (_shouldEnableAnswerInRoundMode(
                roundFinalTimerExpired: roundFinalTimerExpired,
                questionRoundName: questionRoundName,
                roundName: roundName,
              )) {
            isEnabled = true;
          }
        } else {
          if (startTimerStatus == 'Running' && intQuestionId != null && qId == intQuestionId) {
            isEnabled = true;
          }
        }
        
        Map<String, dynamic>? savedAnswer;
        try {
          savedAnswer = savedAnswers[qId];
        } catch (e) {
          print('QuestionPage: Error accessing savedAnswers[$qId]: $e');
          savedAnswer = null;
        }
        Map<String, dynamic>? existingAnswer;
        for (final a in _answers) {
          final aId = a['id'];
          final aid = aId is int ? aId : int.tryParse(aId?.toString() ?? '');
          if (aid == qId) {
            existingAnswer = a;
            break;
          }
        }

        final kSlots = _expectedAnswerSlotCount(question);

        Map<String, dynamic> teamAnswerRow = {};
        for (final ta in teamAnswersFromDb) {
          final tid = ta['question_id'];
          final int? tidInt = tid is int
              ? tid
              : tid is String
                  ? int.tryParse(tid)
                  : tid != null
                      ? int.tryParse(tid.toString())
                      : null;
          if (tidInt == qId) {
            teamAnswerRow = Map<String, dynamic>.from(ta);
            break;
          }
        }

        final slotVals = ['', '', '', ''];

        if (teamAnswerRow.isNotEmpty) {
          for (var i = 0; i < 4; i++) {
            final pk = 'player_answer${i + 1}';
            slotVals[i] = teamAnswerRow[pk]?.toString() ?? '';
          }
        }

        void applySerializedToSlots(String s) {
          if (kSlots <= 1) {
            slotVals[0] = s;
          } else {
            final lines = s.split('\n');
            for (var i = 0; i < kSlots && i < lines.length; i++) {
              slotVals[i] = lines[i];
            }
          }
        }

        bool isSelected = savedAnswer?['selected'] as bool? ?? false;

        final svSav = savedAnswer?['slotValues'];
        if (svSav is List) {
          for (var i = 0; i < svSav.length && i < 4; i++) {
            slotVals[i] = svSav[i]?.toString() ?? '';
          }
        } else {
          final ansStr = savedAnswer?['answer'] as String?;
          if (ansStr != null && ansStr.trim().isNotEmpty) {
            applySerializedToSlots(ansStr);
          }
        }

        if (existingAnswer != null) {
          isSelected = existingAnswer['selected'] as bool? ?? isSelected;
          final svEx = existingAnswer['slotValues'];
          if (svEx is List) {
            for (var i = 0; i < svEx.length && i < 4; i++) {
              slotVals[i] = svEx[i]?.toString() ?? '';
            }
          } else {
            final vx = existingAnswer['value'] as String? ?? '';
            if (vx.trim().isNotEmpty) {
              applySerializedToSlots(vx);
            }
          }
        }

        final String answerText = _compositeValueFromSlots(slotVals, kSlots);

        // Get question data
        final answersForSelection = question['answers_for_selection'] as String?;
        // Handle question_num as both int and string
        dynamic questionNumValue = question['question_num'];
        int questionNumer = qId;
        if (questionNumValue is int) {
          questionNumer = questionNumValue;
        } else if (questionNumValue is String) {
          questionNumer = int.tryParse(questionNumValue) ?? qId;
        } else if (questionNumValue != null) {
          questionNumer = int.tryParse(questionNumValue.toString()) ?? qId;
        }
        final bonusScore = question['bonus_score'] as String? ?? '0;0';
        
        // Format: "Radio:Option A;Option B" or "List:Option A;Option B" or null/""/"=" for text
        String inputType = 'text';
        List<String> options = [];

        final afsKind = _answersForSelectionKind(answersForSelection);
        if (afsKind == 'radio') {
          inputType = 'radio';
          options = _optionsAfterAnswersForSelectionPrefix(answersForSelection);
        } else if (afsKind == 'list') {
          inputType = 'list';
          options = _optionsAfterAnswersForSelectionPrefix(answersForSelection);
        }
        
        if (inputType == 'list' && roundMode && canonicalListForRound.isNotEmpty) {
          options = List<String>.from(canonicalListForRound);
        } else if (inputType == 'list' && options.isEmpty) {
          print(
            'QuestionPage: list question qId=$qId has no options '
            '(afs=$answersForSelection, canonical=${canonicalListForRound.length})',
          );
        }
        
        // Determine checkbox state
        bool checkboxEnabled = true;
        final bonusParts = bonusScore.split(';');
        final bonusCorrect = double.tryParse(bonusParts[0].trim()) ?? 0;
        final bonusWrong =
            double.tryParse(bonusParts.length > 1 ? bonusParts[1].trim() : '0') ?? 0;
        
        if (bonusCorrect == 0 && bonusWrong == 0) {
          checkboxEnabled = false;
        }
        
        // Get reg_score for checkbox state logic
        final regScoreStr = question['reg_score'] as String? ?? '1;0';
        final regParts = regScoreStr.split(';');
        final regScoreCorrect = double.tryParse(regParts[0].trim()) ?? 1;
        final regScoreWrong =
            double.tryParse(regParts.length > 1 ? regParts[1].trim() : '0') ?? 0;
        
        // Update checkbox state from team answers in database
        bool finalCheckboxState = isSelected;
        if (checkboxEnabled && teamAnswerRow.isNotEmpty) {
          final correctScore = teamAnswerRow['correct_score'];
          final wrongScore = teamAnswerRow['wrong_score'];

          double? correctScoreNum;
          double? wrongScoreNum;
          if (correctScore is num) {
            correctScoreNum = correctScore.toDouble();
          } else if (correctScore is String) {
            correctScoreNum = double.tryParse(correctScore);
          }
          if (wrongScore is num) {
            wrongScoreNum = wrongScore.toDouble();
          } else if (wrongScore is String) {
            wrongScoreNum = double.tryParse(wrongScore);
          }

          if (correctScoreNum != null && wrongScoreNum != null) {
            if (correctScoreNum == bonusCorrect && wrongScoreNum == bonusWrong) {
              finalCheckboxState = true;
            } else if (correctScoreNum == regScoreCorrect && wrongScoreNum == regScoreWrong) {
              finalCheckboxState = false;
            }
          }
        }

        mergedAnswers.add({
          'id': qId,
          'num': questionNumer,
          'inputType': inputType,
          'options': options,
          'slotCount': kSlots,
          'slotValues': List<String>.from(slotVals),
          'value': answerText,
          'selected': finalCheckboxState,
          'enabled': isEnabled,
          'checkboxEnabled': checkboxEnabled,
        });
      }
      
      setState(() {
        _answers = mergedAnswers;
        _currentQuestionId = intQuestionId;
        _roundTimer = roundTimer;
      });
      _bumpAnswerPoolRevision();
      
      print('QuestionPage: Built ${mergedAnswers.length} answers from game data (enabled: ${mergedAnswers.where((a) => a['enabled'] == true).length})');

      // Defer scroll to next frame; use double callback to ensure layout is complete
      // (avoids "RenderBox was not laid out" when ensureVisible runs too early)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToCurrentAnswer();
        });
      });
    } catch (e) {
      print('QuestionPage: Error building answers from game data: $e');
    }
  }

  void _scrollToCurrentAnswer() {
    if (_currentQuestionId == null) {
      return;
    }

    final key = _answerItemKeys[_currentQuestionId!];
    final ctx = key?.currentContext;
    if (ctx == null) {
      return;
    }

    try {
      // Only call ensureVisible when the widget has been laid out
      final renderObject = ctx.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );
      }
    } catch (_) {
      // Ignore layout errors (e.g. "RenderBox was not laid out")
    }

  }
  
  /// Update game info from active game and specific question
  Future<void> _updateGameInfo(Map<String, dynamic> activeGame, dynamic questionId) async {
    try {
      final gameName = activeGame['game_name'] as String? ?? 'Current Game';
      
      // Convert questionId to int for lookup
      int? intQuestionId = questionId is int ? questionId : (questionId is String ? int.tryParse(questionId) : null);
      
      // If question_id is 0, get it from action_game_control using round_name
      if (intQuestionId == null || intQuestionId == 0) {
        print('QuestionPage: question_id is 0, getting question_id from action_game_control');
        if (_roundName.isNotEmpty) {
          final gameNameSafe = gameName.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
          final controlData = await DatabaseService.getActionGameControlByRound(gameNameSafe, _roundName);
          if (controlData != null && controlData['question_id'] != null) {
            final controlQuestionId = controlData['question_id'];
            intQuestionId = controlQuestionId is int ? controlQuestionId : (controlQuestionId is String ? int.tryParse(controlQuestionId) : null);
            print('QuestionPage: Retrieved question_id=$intQuestionId from action_game_control for round_name=$_roundName');
          }
        }
      }
      
      // Get reg_score and bonus_score from game table using round_name
      // If question_id is 0, get it for the last question in the list for that round
      num regScore = 1;
      num regScoreTotal = 0;
      num bonusScore = 0;
      num bonusScoreTotal = 0;
      
      if (_gameData.isNotEmpty && _roundName.isNotEmpty) {
        // Filter questions by round_name
        final roundQuestions = _gameData.entries
            .where((entry) => _questionBelongsToRound(entry.value, _roundName))
            .toList();
        
        if (roundQuestions.isNotEmpty) {
          late final Map<String, dynamic> selectedQuestion;
          
          if (intQuestionId == null || intQuestionId == 0) {
            // Get the last question in the list for this round
            // Sort by question_num or id to get the last one
            roundQuestions.sort((a, b) {
              final aNum = a.value['question_num'];
              final bNum = b.value['question_num'];
              final aNumInt = aNum is int ? aNum : (aNum is String ? int.tryParse(aNum) : 0) ?? 0;
              final bNumInt = bNum is int ? bNum : (bNum is String ? int.tryParse(bNum) : 0) ?? 0;
              return aNumInt.compareTo(bNumInt);
            });
            selectedQuestion = roundQuestions.last.value;
            print('QuestionPage: question_id is 0, using last question in round: question_num=${selectedQuestion['question_num']}');
          } else if (_gameData.containsKey(intQuestionId)) {
            // Get from specific question_id
            selectedQuestion = _gameData[intQuestionId]!;
            print('QuestionPage: Using specific question_id=$intQuestionId');
          } else {
            // Fallback to last question in round if specific question_id not found
            roundQuestions.sort((a, b) {
              final aNum = a.value['question_num'];
              final bNum = b.value['question_num'];
              final aNumInt = aNum is int ? aNum : (aNum is String ? int.tryParse(aNum) : 0) ?? 0;
              final bNumInt = bNum is int ? bNum : (bNum is String ? int.tryParse(bNum) : 0) ?? 0;
              return aNumInt.compareTo(bNumInt);
            });
            selectedQuestion = roundQuestions.last.value;
            print('QuestionPage: question_id=$intQuestionId not found, using last question in round: question_num=${selectedQuestion['question_num']}');
          }
          
          final regScoreStr = selectedQuestion['reg_score'] as String? ?? '1;0';
          final regParts = regScoreStr.split(';');
          regScore = double.tryParse(regParts[0].trim()) ?? 1;
          regScoreTotal =
              double.tryParse(regParts.length > 1 ? regParts[1].trim() : '0') ?? 0;
          
          final bonusScoreStr = selectedQuestion['bonus_score'] as String? ?? '0;0';
          final bonusParts = bonusScoreStr.split(';');
          bonusScore = double.tryParse(bonusParts[0].trim()) ?? 0;
          bonusScoreTotal =
              double.tryParse(bonusParts.length > 1 ? bonusParts[1].trim() : '0') ?? 0;
          
          print('QuestionPage: Got reg_score and bonus_score from game table (round_name=$_roundName): reg_score=$regScore/$regScoreTotal, bonus_score=$bonusScore/$bonusScoreTotal');
        } else {
          print('QuestionPage: WARNING - No questions found for round_name=$_roundName');
        }
      } else if (_gameData.isNotEmpty) {
        // Fallback to first question if round_name is empty or gameData doesn't have round info
        final firstQuestion = _gameData.values.first;
        final regScoreStr = firstQuestion['reg_score'] as String? ?? '1;0';
        final regParts = regScoreStr.split(';');
        regScore = double.tryParse(regParts[0].trim()) ?? 1;
        regScoreTotal =
            double.tryParse(regParts.length > 1 ? regParts[1].trim() : '0') ?? 0;
        
        final bonusScoreStr = firstQuestion['bonus_score'] as String? ?? '0;0';
        final bonusParts = bonusScoreStr.split(';');
        bonusScore = double.tryParse(bonusParts[0].trim()) ?? 0;
        bonusScoreTotal =
            double.tryParse(bonusParts.length > 1 ? bonusParts[1].trim() : '0') ?? 0;
        
        print('QuestionPage: Got reg_score and bonus_score from first question in game table (fallback): reg_score=$regScore/$regScoreTotal, bonus_score=$bonusScore/$bonusScoreTotal');
      }
      
      // If question_id != 0, overwrite reg_score from active_teams_answers table (correct_score;wrong_score)
      if (intQuestionId != null && intQuestionId != 0) {
        print('QuestionPage: question_id != 0, getting reg_score from active_teams_answers for question_id=$intQuestionId');
        final userData = await UserDataService.getUserData();
        final teamIdRaw = userData?['playing_in_team_id'];
        if (teamIdRaw != null) {
          final teamIdInt = teamIdRaw is int ? teamIdRaw : int.tryParse(teamIdRaw.toString());
          if (teamIdInt != null) {
            final gameNameSafe = gameName.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
            final teamAnswers = await DatabaseService.getTeamAnswersForGame(gameNameSafe, teamIdInt);
            
            // Find the answer for this question_id
            final teamAnswer = teamAnswers.firstWhere(
              (ta) {
                final taQuestionId = ta['question_id'];
                final taQuestionIdInt = taQuestionId is int ? taQuestionId : (taQuestionId is String ? int.tryParse(taQuestionId) : null);
                return taQuestionIdInt == intQuestionId;
              },
              orElse: () => <String, dynamic>{},
            );
            
            if (teamAnswer.isNotEmpty) {
              final correctScore = teamAnswer['correct_score'];
              final wrongScore = teamAnswer['wrong_score'];
              
              // Convert to numbers
              double? correctScoreNum;
              double? wrongScoreNum;
              if (correctScore is num) {
                correctScoreNum = correctScore.toDouble();
              } else if (correctScore is String) {
                correctScoreNum = double.tryParse(correctScore);
              }
              if (wrongScore is num) {
                wrongScoreNum = wrongScore.toDouble();
              } else if (wrongScore is String) {
                wrongScoreNum = double.tryParse(wrongScore);
              }
              
              // Overwrite display with stored pair (may be fractional)
              if (correctScoreNum != null && wrongScoreNum != null) {
                regScore = correctScoreNum;
                regScoreTotal = wrongScoreNum;
                print('QuestionPage: Overwritten reg_score from active_teams_answers: reg_score=$regScore/$regScoreTotal');
              }
            } else {
              print('QuestionPage: No team answer found for question_id=$intQuestionId, keeping reg_score from game table');
            }
          }
        }
      }
      
      // Set the final values
      setState(() {
        _gameName = gameName;
        _regScore = regScore;
        _regScoreTotal = regScoreTotal;
        _bonusScore = bonusScore;
        _bonusScoreTotal = bonusScoreTotal;
      });
      
      print('QuestionPage: Final game info - reg_score=$regScore/$regScoreTotal, bonus_score=$bonusScore/$bonusScoreTotal');
    } catch (e) {
      print('QuestionPage: Error updating game info: $e');
    }
  }
  
  /// Get active game from backend
  Future<Map<String, dynamic>?> _getActiveGame() async {
    try {
      print('QuestionPage: _getActiveGame called');
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        print('QuestionPage: No user data or access token');
        return null;
      }
      
      print('QuestionPage: Fetching active games from ${DatabaseService.baseUrl}/active-games');
      final response = await http.get(
        Uri.parse('${DatabaseService.baseUrl}/active-games'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );
      
      print('QuestionPage: Active games API response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as List;
        print('QuestionPage: Received ${data.length} active games');
        
        if (data.isNotEmpty) {
          // Log all games to see their structure
          for (var i = 0; i < data.length; i++) {
            final game = data[i] as Map<String, dynamic>;
            print('QuestionPage: Game $i full structure: $game');
            print('QuestionPage: Game $i: game_name=${game['game_name']}, is_started=${game['is_started']} (type: ${game['is_started'].runtimeType})');
          }
          
          // Get the first active game that is 'running' or 'active' (not 'idle')
          for (var game in data) {
            final gameMap = game as Map<String, dynamic>;
            final isStarted = gameMap['is_started'];
            final gameName = gameMap['game_name'];
            print('QuestionPage: Checking game ${gameName ?? 'null'}: is_started=$isStarted (type: ${isStarted.runtimeType})');
            
            // Check for 'running' or 'active' status (both indicate an active game)
            if (isStarted == 'running' || isStarted == 'active') {
              print('QuestionPage: Found active/running game: ${gameName ?? 'null'}');
              // If game_name is null, fetch it using game_id
              if (gameName == null) {
                print('QuestionPage: WARNING - game_name is null, fetching from game_id...');
                final gameId = gameMap['game_id'];
                if (gameId != null) {
                  try {
                    // Fetch game name from admin games endpoint
                    final gameResponse = await http.get(
                      Uri.parse('${DatabaseService.baseUrl}/admin/games'),
                      headers: {
                        'Authorization': 'Bearer ${userData['access_token']}',
                        'Content-Type': 'application/json',
                      },
                    );
                    
                    if (gameResponse.statusCode == 200) {
                      final gamesData = json.decode(gameResponse.body);
                      if (gamesData['success'] == true) {
                        final games = gamesData['games'] as List;
                        final matchingGame = games.firstWhere(
                          (g) => g['id'] == gameId,
                          orElse: () => null,
                        );
                        if (matchingGame != null) {
                          final fetchedGameName = matchingGame['game_name'] as String?;
                          if (fetchedGameName != null) {
                            print('QuestionPage: Fetched game name from game_id: $fetchedGameName');
                            gameMap['game_name'] = fetchedGameName;
                          }
                        }
                      }
                    }
                  } catch (e) {
                    print('QuestionPage: Error fetching game name: $e');
                  }
                }
                
                // If still null, use fallback
                if (gameMap['game_name'] == null) {
                  print('QuestionPage: No game name found, using fallback');
                  gameMap['game_name'] = 'Current Game';
                }
              }
              return gameMap;
            }
          }
          // If no running/active game, return the first one anyway (might be 'idle' but still the current game)
          final firstGame = data[0] as Map<String, dynamic>;
          final firstGameName = firstGame['game_name'];
          print('QuestionPage: No running/active game found, returning first game: ${firstGameName ?? 'null'}');
          
          // Handle null game_name for first game too
          if (firstGameName == null) {
            final gameId = firstGame['game_id'];
            if (gameId != null) {
              try {
                // Fetch game name from admin games endpoint
                final gameResponse = await http.get(
                  Uri.parse('${DatabaseService.baseUrl}/admin/games'),
                  headers: {
                    'Authorization': 'Bearer ${userData['access_token']}',
                    'Content-Type': 'application/json',
                  },
                );
                
                if (gameResponse.statusCode == 200) {
                  final gamesData = json.decode(gameResponse.body);
                  if (gamesData['success'] == true) {
                    final games = gamesData['games'] as List;
                    final matchingGame = games.firstWhere(
                      (g) => g['id'] == gameId,
                      orElse: () => null,
                    );
                    if (matchingGame != null) {
                      final fetchedGameName = matchingGame['game_name'] as String?;
                      if (fetchedGameName != null) {
                        print('QuestionPage: Fetched game name for first game from game_id: $fetchedGameName');
                        firstGame['game_name'] = fetchedGameName;
                      }
                    }
                  }
                }
              } catch (e) {
                print('QuestionPage: Error fetching game name for first game: $e');
              }
            }
            
            // If still null, use fallback
            if (firstGame['game_name'] == null) {
              firstGame['game_name'] = 'Current Game';
            }
          }
          
          return firstGame;
        } else {
          print('QuestionPage: Active games list is empty');
        }
      } else {
        print('QuestionPage: Active games API returned status ${response.statusCode}: ${response.body}');
      }
      return null;
    } catch (e, stackTrace) {
      print('QuestionPage: Error fetching active game: $e');
      print('QuestionPage: Stack trace: $stackTrace');
      return null;
    }
  }
  
  /// Load saved answers from persistent storage
  /// Returns: Map<question_id, answer_data>
  Future<Map<int, Map<String, dynamic>>> _loadSavedAnswers(String gameName, String teamId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Normalize game name for storage (remove spaces, special chars)
      final gameNameSafe = gameName.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
      final storageKey = 'game_answers_${gameNameSafe}_team_$teamId';
      final savedDataJson = prefs.getString(storageKey);
      
      if (savedDataJson == null || savedDataJson.isEmpty) {
        print('QuestionPage: No saved answers found for game: $gameName, team: $teamId');
        return {};
      }
      
      final savedData = json.decode(savedDataJson) as Map<String, dynamic>;
      
      // Convert string keys to int keys
      final result = <int, Map<String, dynamic>>{};
      for (var entry in savedData.entries) {
        final questionId = int.tryParse(entry.key);
        if (questionId != null) {
          result[questionId] = Map<String, dynamic>.from(entry.value);
        }
      }
      
      print('QuestionPage: Loaded ${result.length} saved answers for game: $gameName, team: $teamId');
      return result;
    } catch (e) {
      print('QuestionPage: Error loading saved answers: $e');
      return {};
    }
  }
  
  /// Save answers to persistent storage
  Future<void> _saveAnswers() async {
    try {
      if (_currentGameNameForStorage.isEmpty) {
        print('QuestionPage: Cannot save answers - no game name set');
        return;
      }
      
      final userData = await UserDataService.getUserData();
      final teamIdRaw = userData?['playing_in_team_id'];
      if (teamIdRaw == null) {
        print('QuestionPage: Cannot save answers - no team ID');
        return;
      }
      
      // Convert team ID to string for storage key
      final teamId = teamIdRaw.toString();
      
      final prefs = await SharedPreferences.getInstance();
      // Normalize game name for storage (remove spaces, special chars)
      final gameNameSafe = _currentGameNameForStorage.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
      final storageKey = 'game_answers_${gameNameSafe}_team_$teamId';
      
      // Merge with existing saved answers so classic mode (one question in _answers) keeps prior rows.
      final answersMap = <String, Map<String, dynamic>>{};
      final existingJson = prefs.getString(storageKey);
      if (existingJson != null && existingJson.isNotEmpty) {
        try {
          final existing = json.decode(existingJson) as Map<String, dynamic>;
          for (final entry in existing.entries) {
            if (entry.value is Map) {
              answersMap[entry.key] = Map<String, dynamic>.from(entry.value as Map);
            }
          }
        } catch (_) {}
      }
      for (var answer in _answers) {
        final questionId = answer['id'] as int?;
        if (questionId != null) {
          final ks = answer['slotCount'] as int? ?? 1;
          final four = List<String>.from(_fourSlotValuesFromAnswerMap(answer));
          answersMap[questionId.toString()] = {
            'answer': answer['value'] as String? ?? '',
            'slotValues': four,
            'slotCount': ks,
            'selected': answer['selected'] as bool? ?? false,
          };
        }
      }
      
      // Save to persistent storage
      await prefs.setString(storageKey, json.encode(answersMap));
      
      // Print storage location info for debugging
      _printStorageLocation(storageKey);
      
      print('QuestionPage: Saved ${answersMap.length} answers for game: $_currentGameNameForStorage, team: $teamId');
      print('QuestionPage: Storage key: $storageKey');
    } catch (e) {
      print('QuestionPage: Error saving answers: $e');
    }
  }
  
  /// Print storage location information for debugging
  void _printStorageLocation(String storageKey) {
    try {
      print('=== PERSISTENT STORAGE LOCATION ===');
      print('Storage Key: $storageKey');
      
      if (kIsWeb) {
        print('Platform: Web (Browser)');
        print('Location: Browser localStorage');
        print('Access: Open DevTools (F12) → Application/Storage → Local Storage → Your Domain');
        print('Storage Key Format: game_answers_{gameName}_team_{teamId}');
        print('Example: $storageKey');
      } else if (!kIsWeb && Platform.isAndroid) {
        print('Platform: Android');
        print('Location: /data/data/{package_name}/shared_prefs/FlutterSharedPreferences.xml');
        print('Package: Check android/app/build.gradle for applicationId');
        print('Access: Requires root or ADB: adb shell run-as {package} cat /data/data/{package}/shared_prefs/FlutterSharedPreferences.xml');
      } else if (!kIsWeb && Platform.isIOS) {
        print('Platform: iOS');
        print('Location: Library/Preferences/{bundle_id}.plist');
        print('Bundle ID: Check ios/Runner/Info.plist');
        print('Access: Requires device access or Xcode');
      }
      print('===================================');
    } catch (e) {
      // If platform detection fails, just print basic info
      print('Storage Key: $storageKey');
      print('Platform detection failed: $e');
    }
  }

  void _startBlinking() {
    _isBlinking = true;
    _blinkTimer?.cancel();
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || !_isBlinking) {
        timer.cancel();
        return;
      }
      setState(() {
        _isBlinking = !_isBlinking;
      });
    });
  }
  
  void _stopBlinking() {
    _isBlinking = false;
    _blinkTimer?.cancel();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _handleTimerTrigger(Map<String, dynamic> message) {
    print('QuestionPage: _handleTimerTrigger called with message: $message');
    // Timer is already handled globally, just sync UI and handle question board
    final timerAction = message['timer_action'] as String?;
    
    if (timerAction == null) {
      print('QuestionPage: timer_action is null, returning');
      return;
    }
    
    print('QuestionPage: Processing timer_action: $timerAction');
    
    switch (timerAction) {
      case 'START_TIME':
      case 'START_TIMER':
        // Extract original timer duration from message
        dynamic questionTimerValue = message['question_timer'];
        int originalDuration = 0;
        if (questionTimerValue is int) {
          originalDuration = questionTimerValue;
        } else if (questionTimerValue is String) {
          originalDuration = int.tryParse(questionTimerValue) ?? 0;
        }
        
        print('QuestionPage: START_TIMER received, originalDuration=$originalDuration');
        
        // Set total time immediately from message (before loading status)
        if (mounted && originalDuration > 0) {
          setState(() {
            _totalTime = Duration(seconds: originalDuration);
            print('QuestionPage: Set _totalTime to $originalDuration seconds immediately');
          });
        }
        
        // Sync with global timer status (this will get remaining time)
        _loadTimerStatus().then((_) {
          // Ensure total time is set correctly after loading
          if (mounted && originalDuration > 0) {
            setState(() {
              if (_totalTime.inSeconds != originalDuration) {
                _totalTime = Duration(seconds: originalDuration);
                print('QuestionPage: Corrected _totalTime to $originalDuration seconds after loading');
              }
              print('QuestionPage: Final - _totalTime=${_totalTime.inSeconds}s, _remainingTime=${_remainingTime.inSeconds}s, progress=${_remainingTime.inSeconds / _totalTime.inSeconds}');
            });
          }
        });
        
        // Timer already started globally, just build question board
        print('QuestionPage: About to call build_question_board for START_TIMER');
        print('QuestionPage: Message content: $message');
        build_question_board(message).then((_) async {
          print('QuestionPage: build_question_board completed for START_TIMER');
          _updateAnswerEditability();
        }).catchError((e) {
          print('QuestionPage: Error in build_question_board for START_TIMER: $e');
        });
        break;
        
      case 'STOP_TIMER':
        print('QuestionPage: STOP_TIMER received');
        _tick?.cancel();
        // Reload UI from prefs + globals (round mode: LAST may still run; blind zero hides it)
        _loadTimerStatus().then((_) async {
          if (!mounted) return;
          await _updateAnswerEditability();
        });
        break;
        
      case 'LAST_TIMER':
        // Extract original timer duration from message
        dynamic finalTimerValue = message['final_timer'];
        int originalDuration = 0;
        if (finalTimerValue is int) {
          originalDuration = finalTimerValue;
        } else if (finalTimerValue is String) {
          originalDuration = int.tryParse(finalTimerValue) ?? 0;
        }
        
        print('QuestionPage: LAST_TIMER received, originalDuration=$originalDuration');
        
        // Set total time immediately from message (before loading status)
        if (mounted && originalDuration > 0) {
          setState(() {
            _totalTime = Duration(seconds: originalDuration);
            print('QuestionPage: Set _totalTime to $originalDuration seconds immediately (LAST_TIMER)');
          });
        }
        
        // Sync with global timer status (this will get remaining time)
        _loadTimerStatus().then((_) {
          // Ensure total time is set correctly after loading
          if (mounted && originalDuration > 0) {
            setState(() {
              if (_totalTime.inSeconds != originalDuration) {
                _totalTime = Duration(seconds: originalDuration);
                print('QuestionPage: Corrected _totalTime to $originalDuration seconds after loading (LAST_TIMER)');
              }
              print('QuestionPage: Final - _totalTime=${_totalTime.inSeconds}s, _remainingTime=${_remainingTime.inSeconds}s, progress=${_remainingTime.inSeconds / _totalTime.inSeconds}');
            });
          }
        });
        
        // Build question board for LAST_TIMER as well
        print('QuestionPage: About to call build_question_board for LAST_TIMER');
        print('QuestionPage: Message content: $message');
        build_question_board(message).then((_) async {
          print('QuestionPage: build_question_board completed for LAST_TIMER');
          _updateAnswerEditability();
        }).catchError((e) {
          print('QuestionPage: Error in build_question_board for LAST_TIMER: $e');
        });
        break;
        
      default:
        print('Unknown timer action: $timerAction');
    }
  }

  Widget _buildTimer() {
    // Progress calculation: show remaining/total, default (not started) shows full bar
    final progress = _totalTime.inSeconds > 0 
        ? (_remainingTime.inSeconds / _totalTime.inSeconds).clamp(0.0, 1.0)
        : 1.0;
    
    // Debug logging (only log occasionally to avoid spam)
    if (_timerStarted && _totalTime.inSeconds > 0 && timer_counter_down % 5 == 0) {
      print('_buildTimer: _totalTime=${_totalTime.inSeconds}s, _remainingTime=${_remainingTime.inSeconds}s, progress=$progress, timer_counter_down=$timer_counter_down');
    }
    
    // Display "0" when timer hasn't started, otherwise show remaining time
    final displayTime = !_timerStarted ? '0' : _formatDuration(_remainingTime);
    
    // Determine color based on timer state
    Color timerColor;
    if (timer_counter_down <= 5 && timer_counter_down > 0) {
      // Blinking red when <= 5 seconds (color toggles via _isBlinking state)
      timerColor = _isBlinking ? Colors.red : Colors.red.shade300;
    } else if (_isTimerRunning) {
      timerColor = Colors.green.shade700;
    } else {
      timerColor = Colors.orange.shade700;
    }
    
    // Show progress bar only if total time > 2 seconds
    final showProgressBar = _totalTime.inSeconds > 2;
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isTimerRunning ? Icons.play_arrow : Icons.pause,
                  color: timerColor,
                ),
                const SizedBox(width: 8),
                Text(
                  'Quiz Timer',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: timerColor,
                  ),
                ),
              ],
            ),
            if (showProgressBar) ...[
              const SizedBox(height: 12),
              Container(
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    timer_counter_down <= 5 && timer_counter_down > 0
                        ? (_isBlinking ? Colors.red : Colors.red.shade300)
                        : (_isTimerRunning ? Colors.green.shade600 : Colors.orange.shade600),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: Text(
                displayTime,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: timerColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameInfo() {
    // Display round_name instead of game name if available
    final displayName = _roundName.isNotEmpty ? _roundName : _gameName;
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              displayName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Reg Score:',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade700,
                  ),
                ),
                Text(
                  '${_formatScoreDisplay(_regScore)}/${_formatScoreDisplay(_regScoreTotal)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Bonus Score:',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade700,
                  ),
                ),
                Text(
                  '${_formatScoreDisplay(_bonusScore)}/${_formatScoreDisplay(_bonusScoreTotal)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Format comma-stored list picks for the answer row (list option order, "A + B + C").
  String _formatListSelectionsForDisplay(String raw, List<String> options) {
    final parts =
        raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) {
      return '';
    }
    if (options.isNotEmpty) {
      final ordered = options.where((o) => parts.contains(o)).toList();
      if (ordered.isNotEmpty) {
        return ordered.join(' + ');
      }
    }
    return parts.join(' + ');
  }

  String _summaryLabelForAnswer(Map<String, dynamic> answer) {
    final inputType = answer['inputType'] as String? ?? 'text';
    final sc = answer['slotCount'] as int? ?? 1;
    final options = (answer['options'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];
    if (sc > 1) {
      final four = _fourSlotValuesFromAnswerMap(answer);
      final parts =
          four.take(sc).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (parts.isEmpty) {
        return 'No answer yet';
      }
      if (inputType == 'list') {
        final slotLabels = parts
            .map((slot) => _formatListSelectionsForDisplay(slot, options))
            .where((e) => e.isNotEmpty)
            .toList();
        if (slotLabels.isEmpty) {
          return 'No answer yet';
        }
        return slotLabels.join(' · ');
      }
      return parts.join(' · ');
    }
    final value = (answer['value'] as String? ?? '').trim();
    if (value.isEmpty) {
      return 'No answer yet';
    }
    switch (inputType) {
      case 'list':
        final formatted = _formatListSelectionsForDisplay(value, options);
        if (formatted.isEmpty) {
          return 'No answer yet';
        }
        return formatted;
      case 'radio':
      case 'text':
      default:
        return value;
    }
  }

  void _bumpAnswerPoolRevision() {
    _answerPoolRevision.value = _answerPoolRevision.value + 1;
  }

  /// When round uses shared list pool, which question id currently "owns" this option (if not [forQuestionId]).
  int? _listOptionOwnerQuestionId(String option, int forQuestionId) {
    if (!_roundModeActive) {
      return null;
    }
    for (final a in _answers) {
      if (a['inputType'] != 'list') {
        continue;
      }
      final int? qid = a['id'] is int ? a['id'] as int : int.tryParse('${a['id']}');
      if (qid == null || qid == forQuestionId) {
        continue;
      }
      final v = _listRawForConflictCheck(a);
      final set = v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
      if (set.contains(option)) {
        return qid;
      }
    }
    return null;
  }

  ({double c, double w}) _regWrongPairForQuestion(int questionId) {
    final q = _gameData[questionId];
    if (q == null) {
      return (c: 1.0, w: 0.0);
    }
    final r = (q['reg_score'] as String? ?? '1;0').split(';');
    final c = double.tryParse(r[0].trim()) ?? 1.0;
    final w = double.tryParse(r.length > 1 ? r[1].trim() : '0') ?? 0.0;
    return (c: c, w: w);
  }

  ({double c, double w}) _bonusWrongPairForQuestion(int questionId) {
    final q = _gameData[questionId];
    if (q == null) {
      return (c: 0.0, w: 0.0);
    }
    final b = (q['bonus_score'] as String? ?? '0;0').split(';');
    final c = double.tryParse(b[0].trim()) ?? 0.0;
    final w = double.tryParse(b.length > 1 ? b[1].trim() : '0') ?? 0.0;
    return (c: c, w: w);
  }

  /// Checkbox: persist reg_score pair (unchecked) or bonus pair (checked) to active_teams_answers.
  Future<AnswerPersistStatus> _persistAnswerWithCheckboxScores(
    int questionId,
    List<String> slots,
    bool selected,
  ) async {
    final reg = _regWrongPairForQuestion(questionId);
    final bon = _bonusWrongPairForQuestion(questionId);
    final c = selected ? bon.c : reg.c;
    final w = selected ? bon.w : reg.w;
    return _persistAnswerSlots(
      questionId,
      slots,
      correctScore: c,
      wrongScore: w,
    );
  }

  Future<AnswerPersistStatus> _persistAnswerSlots(
    int questionId,
    List<String> slots, {
    double? correctScore,
    double? wrongScore,
  }) async {
    if (!_isWriter || _currentGameNameForStorage.isEmpty) {
      return AnswerPersistStatus.failed;
    }
    final gameNameSafe = _currentGameNameForStorage.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
    final userData = await UserDataService.getUserData();
    final teamIdRaw = userData?['playing_in_team_id'];
    if (teamIdRaw == null) {
      return AnswerPersistStatus.failed;
    }
    final teamIdInt = teamIdRaw is int ? teamIdRaw : int.tryParse(teamIdRaw.toString());
    if (teamIdInt == null) {
      return AnswerPersistStatus.failed;
    }
    final roundName = _roundName.isNotEmpty ? _roundName : null;
    final rt = _roundModeActive ? (_roundTimer != 0 ? _roundTimer : null) : null;
    final pad = List<String>.from(slots.map((e) => e.trim()));
    while (pad.length < 4) {
      pad.add('');
    }
    final item = <String, dynamic>{
      'question_id': questionId,
      'player_answer1': pad[0],
      'player_answer2': pad[1],
      'player_answer3': pad[2],
      'player_answer4': pad[3],
    };
    if (correctScore != null && wrongScore != null) {
      item['correct_score'] = correctScore;
      item['wrong_score'] = wrongScore;
    }
    final res = await DatabaseService.putTeamAnswersBatch(
      gameNameSafe,
      teamIdInt,
      <Map<String, dynamic>>[item],
      roundName: roundName,
      roundTimer: rt,
    );
    if (res['success'] == true) {
      if (mounted) {
        setState(() {
          final idx = _answers.indexWhere((a) => a['id'] == questionId);
          if (idx >= 0) {
            final sc = _answers[idx]['slotCount'] as int? ?? 1;
            _answers[idx]['slotValues'] = List<String>.from(pad);
            _answers[idx]['value'] = _compositeValueFromSlots(pad, sc);
          }
        });
        _bumpAnswerPoolRevision();
        await _saveAnswers();
      }
      return AnswerPersistStatus.success;
    }
    if (res['statusCode'] == 409) {
      if (mounted) {
        unawaited(_handleRefresh(quiet: true).then((_) {
          if (!mounted) return;
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }));
      }
      return AnswerPersistStatus.conflict;
    }
    if (res['error'] == 'network') {
      if (mounted) {
        setState(() {
          final idx = _answers.indexWhere((a) => a['id'] == questionId);
          if (idx >= 0) {
            final sc = _answers[idx]['slotCount'] as int? ?? 1;
            _answers[idx]['slotValues'] = List<String>.from(pad);
            _answers[idx]['value'] = _compositeValueFromSlots(pad, sc);
          }
        });
        _bumpAnswerPoolRevision();
        await _saveAnswers();
      }
      return AnswerPersistStatus.offline;
    }
    return AnswerPersistStatus.failed;
  }

  void _openAnswerEditor(int index) {
    if (index < 0 || index >= _answers.length) {
      return;
    }
    final answer = _answers[index];
    final answerEnabled = answer['enabled'] as bool? ?? false;
    if (!_isWriter || !answerEnabled) {
      return;
    }
    final qId = answer['id'] as int? ?? 0;
    if (qId == 0) {
      return;
    }
    final numLabel = answer['num'];
    final sub = _roundName.isNotEmpty ? _roundName : _gameName;
    final useSharedList =
        (answer['inputType'] as String? ?? '') == 'list' && _roundModeActive;

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final slotCount = answer['slotCount'] as int? ?? 1;
        final k = slotCount.clamp(1, 4);
        final initFour = _fourSlotValuesFromAnswerMap(answer);
        final initSlots = List<String>.generate(k, (i) => initFour[i]);

        return AnswerEditorDialog(
          questionId: qId,
          questionNum: numLabel is int ? numLabel : int.tryParse(numLabel.toString()) ?? index + 1,
          subtitle: sub,
          inputType: answer['inputType'] as String? ?? 'text',
          options: List<String>.from(
            (answer['options'] as List?)?.map((e) => e.toString()) ?? <String>[],
          ),
          slotCount: k,
          initialSlotValues: initSlots,
          roundUsesSharedListPool: useSharedList,
          ownerQuestionIdForOption: useSharedList
              ? (opt) => _listOptionOwnerQuestionId(opt, qId)
              : null,
          answerPoolRevision: useSharedList ? _answerPoolRevision : null,
          isEditable: () {
            if (!mounted) {
              return false;
            }
            final i = _answers.indexWhere((a) => a['id'] == qId);
            if (i < 0) {
              return false;
            }
            final en = _answers[i]['enabled'] as bool? ?? false;
            return _isWriter && en;
          },
          onPersistSlots: (slots) => _persistAnswerSlots(qId, slots),
        );
      },
    );
  }

  Widget _buildAnswerSelection() {
    return Card(
      elevation: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: const Text(
              'Answer/s',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _answers.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, index) {
              final answer = _answers[index];
              final qId = answer['id'] as int?;
              final itemKey = qId == null ? null : _answerItemKeys[qId];
              final answerEnabled = answer['enabled'] as bool? ?? false;
              final answerCheckboxEnabled = answer['checkboxEnabled'] as bool? ?? false;
              final canOpen = _isWriter && answerEnabled;
              final labelStyle = (!answerEnabled || !_isWriter)
                  ? TextStyle(
                      color: Colors.grey.shade500,
                    )
                  : null;
              final summary = _summaryLabelForAnswer(answer);

              return Container(
                key: itemKey,
                child: Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: canOpen ? () => _openAnswerEditor(index) : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Num',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    answer['num'].toString(),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: canOpen ? null : Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: canOpen ? () => _openAnswerEditor(index) : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                                child: Text(
                                  summary,
                                  style: labelStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: kMinTouchTargetSize,
                          height: kMinTouchTargetSize,
                          child: Checkbox(
                            value: answer['selected'] as bool,
                            onChanged: (!answerCheckboxEnabled || !answerEnabled || !_isWriter)
                                ? null
                                : (value) async {
                                    final v = value ?? false;
                                    final id = _answers[index]['id'] as int? ?? 0;
                                    if (id == 0) {
                                      return;
                                    }
                                    setState(() {
                                      _answers[index]['selected'] = v;
                                    });
                                    final slots =
                                        _slotValuesForPersist(_answers[index]);
                                    await _persistAnswerWithCheckboxScores(id, slots, v);
                                    _triggerAutoSave();
                                  },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _handleRefresh({bool quiet = false}) async {
    try {
      // Reload game data and saved answers
      if (_currentGameNameForStorage.isNotEmpty) {
        final userData = await UserDataService.getUserData();
        final teamIdRaw = userData?['playing_in_team_id'];
        
        if (teamIdRaw != null) {
          // Convert team ID to string
          final teamId = teamIdRaw.toString();
          
          // Reload saved answers
          final savedAnswers = await _loadSavedAnswers(_currentGameNameForStorage, teamId);
          
          // Load team answers from database
          final gameNameSafe = _currentGameNameForStorage.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();
          final teamIdInt = int.tryParse(teamId);
          List<Map<String, dynamic>> teamAnswersFromDb = [];
          if (teamIdInt != null) {
            teamAnswersFromDb = await DatabaseService.getTeamAnswersForGame(gameNameSafe, teamIdInt);
          }
          
          // Rebuild answers from cached game data and saved answers
          // Get round name from current message or from first answer
          String? roundName;
          if (_answers.isNotEmpty && _gameData.isNotEmpty) {
            // Try to get round name from game data
            final firstQuestion = _gameData.values.first;
            roundName = firstQuestion['round_name'] as String?;
          }
          
          if (roundName != null) {
            // Get active game to pass to _buildAnswersFromGameData
            final activeGame = await _getActiveGame();
            if (activeGame != null) {
              // Get question_id from last_timer_setting
              final prefs = await SharedPreferences.getInstance();
              final lastTimerDataStr = prefs.getString('last_timer_action_data');
              dynamic questionId;
              if (lastTimerDataStr != null) {
                try {
                  final lastTimerData = jsonDecode(lastTimerDataStr) as Map<String, dynamic>;
                  questionId = lastTimerData['question_id'];
                } catch (e) {
                  print('Error parsing last_timer_action_data in _handleRefresh: $e');
                }
              }
              await _buildAnswersFromGameData(roundName, questionId, savedAnswers, activeGame, teamAnswersFromDb);
            }
          }
          
          if (mounted && !quiet) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Answers refreshed from saved data'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      print('Error refreshing answers: $e');
      if (mounted && !quiet) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error refreshing answers: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // Handle back button press
  Future<bool> _onWillPop() async {
    // Check if we can pop (i.e., there's a previous route in the stack)
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
      return false; // Don't allow default back behavior
    } else {
      // No previous route (e.g., after page refresh), navigate to main page
      Navigator.pushReplacementNamed(context, '/main');
      return false; // Don't allow default back behavior
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent default back button behavior
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          await _onWillPop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Question Page'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              _onWillPop();
            },
          ),
        ),
      body: SingleChildScrollView(
        controller: _pageScrollController,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Timer
              _buildTimer(),
              const SizedBox(height: 16),
              // Game Info
              _buildGameInfo(),
              const SizedBox(height: 16),
              // Answer Selection
              _buildAnswerSelection(),
            ],
          ),
        ),
      ),
    ),
    );
  }
}
