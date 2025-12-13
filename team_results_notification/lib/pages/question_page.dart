import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_data_service.dart';
import 'login_page.dart'; // For DatabaseService

// Global callback for timer messages from WebSocket
Function(Map<String, dynamic>)? _globalTimerMessageHandler;

// Function to forward timer messages from main_page
void forwardTimerMessage(Map<String, dynamic> message) {
  if (_globalTimerMessageHandler != null) {
    print('QuestionPage: Received timer message, forwarding to handler');
    _globalTimerMessageHandler!(message);
  } else {
    print('QuestionPage: Timer message received but no handler registered');
  }
}

class QuestionPage extends StatefulWidget {
  const QuestionPage({super.key});

  @override
  State<QuestionPage> createState() => _QuestionPageState();
}

class _QuestionPageState extends State<QuestionPage> {
  // Timer state - countdown timer
  Duration _remainingTime = const Duration(minutes: 45); // Initialize to total time
  Duration _totalTime = const Duration(minutes: 45);
  bool _isTimerRunning = false;
  bool _timerStarted = false; // Track if timer has been started
  Timer? _tick;
  
  // Global timer counter down variable
  int timer_counter_down = 0;
  
  // Timer blinking state for red warning
  bool _isBlinking = false;
  Timer? _blinkTimer;
  
  // Stop timer countdown state
  int _stopCountdown = 0;
  Timer? _stopCountdownTimer;
  
  // Game state
  String _gameName = "Current Game";
  int _regScore = 1;
  int _regScoreTotal = 0;
  int _bonusScore = 0;
  int _bonusScoreTotal = 0;
  
  // Answer state
  List<Map<String, dynamic>> _answers = [];
  bool _isWriter = false;
  
  // Writer status check timer
  Timer? _writerStatusCheckTimer;
  bool _isAppVisible = true;
  
  // Game data cache - keyed by question ID (primary key from game table)
  Map<int, Map<String, dynamic>> _gameData = {};
  
  // Current game name for persistent storage
  String _currentGameNameForStorage = '';
  
  // Auto-save timer (debounced)
  Timer? _autoSaveTimer;
  
  @override
  void initState() {
    super.initState();
    
    // Check if page was refreshed (no navigation history)
    // If so, navigate to main page (same as back button behavior)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !Navigator.canPop(context)) {
        print('QuestionPage: Page refreshed (no navigation history), redirecting to main page');
        Navigator.pushReplacementNamed(context, '/main');
        return;
      }
    });
    
    // Initialize timer_counter_down to 0 when player enters question_page
    timer_counter_down = 0;
    _loadUserData();
    _initializeAnswers(1); // Default to 1 answer
    _startWriterStatusCheck();
    
    // Register this page to receive timer messages
    _globalTimerMessageHandler = _handleTimerTrigger;
    print('QuestionPage: Registered for timer messages');
  }

  @override
  void dispose() {
    _tick?.cancel();
    _writerStatusCheckTimer?.cancel();
    _blinkTimer?.cancel();
    _stopCountdownTimer?.cancel();
    _autoSaveTimer?.cancel();
    
    // Save answers before disposing
    _saveAnswers();
    
    // Unregister timer message handler
    if (_globalTimerMessageHandler == _handleTimerTrigger) {
      _globalTimerMessageHandler = null;
      print('QuestionPage: Unregistered from timer messages');
    }
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
      final echoResult = await DatabaseService.sendEchoCall(_isAppVisible);
      
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
      final roundName = message['round_name'] as String?;
      final questionId = message['question_id'];
      
      if (roundName == null) {
        print('QuestionPage: round_name is null in message');
        return;
      }
      
      print('QuestionPage: Building question board for round: $roundName, question_id: $questionId');
      
      // Get active game to get game name
      final activeGame = await _getActiveGame();
      if (activeGame == null) {
        print('QuestionPage: No active game found');
        return;
      }
      
      final gameName = activeGame['game_name'] as String?;
      if (gameName == null) {
        print('QuestionPage: Game name is null');
        return;
      }
      
      // Update current game name for storage
      _currentGameNameForStorage = gameName;
      
      // Load game data into cache if not already loaded
      if (_gameData.isEmpty) {
        await _loadGameDataIntoCache(gameName, roundName);
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
      
      // Load saved answers from persistent storage
      final savedAnswers = await _loadSavedAnswers(gameName, teamId);
      
      // Build answers list from game data and saved answers
      await _buildAnswersFromGameData(roundName, questionId, savedAnswers);
      
      // Update game info
      _updateGameInfo(activeGame);
      
    } catch (e) {
      print('QuestionPage: Error in build_question_board: $e');
    }
  }
  
  /// Load all game data for a round into the cache dictionary
  /// Key: question ID (primary key), Value: all row data as Map
  Future<void> _loadGameDataIntoCache(String gameName, String roundName) async {
    try {
      print('QuestionPage: Loading game data into cache for game: $gameName, round: $roundName');
      
      final gameDataList = await DatabaseService.getGameQuestionsByRound(gameName, roundName);
      
      // Clear existing cache
      _gameData.clear();
      
      // Populate cache with question ID as key
      for (var question in gameDataList) {
        final questionId = question['id'] as int?;
        if (questionId != null) {
          _gameData[questionId] = Map<String, dynamic>.from(question);
        }
      }
      
      print('QuestionPage: Loaded ${_gameData.length} questions into cache');
    } catch (e) {
      print('QuestionPage: Error loading game data into cache: $e');
    }
  }
  
  /// Build answers list from cached game data and saved answers
  Future<void> _buildAnswersFromGameData(
    String roundName,
    dynamic questionId,
    Map<int, Map<String, dynamic>> savedAnswers,
  ) async {
    try {
      final mergedAnswers = <Map<String, dynamic>>[];
      
      // Get active game to check round_timer
      final activeGame = await _getActiveGame();
      final roundTimer = activeGame?['round_timer'] as int? ?? 0;
      
      // Process each question from cached game data
      for (var entry in _gameData.entries) {
        final qId = entry.key;
        final question = entry.value;
        
        // Determine if answer should be enabled for editing
        final isEnabled = roundTimer > 0 || (questionId != null && qId == questionId);
        
        // Get saved answer if exists
        final savedAnswer = savedAnswers[qId];
        final answerText = savedAnswer?['answer'] as String? ?? '';
        final isSelected = savedAnswer?['selected'] as bool? ?? false;
        
        // Get question data
        final answersForSelection = question['answers_for_selection'] as String?;
        final questionNumer = question['question_num'] as int? ?? qId;
        final bonusScore = question['bonus_score'] as String? ?? '0;0';
        
        // Determine input type
        String inputType = 'text';
        List<String> options = [];
        
        if (answersForSelection != null && 
            answersForSelection.isNotEmpty && 
            answersForSelection != '=') {
          options = answersForSelection.split(',').map((e) => e.trim()).toList();
          if (options.length == 1) {
            inputType = 'radio';
          } else if (options.length > 1) {
            inputType = 'list';
          }
        }
        
        // Determine checkbox state
        bool checkboxEnabled = true;
        final bonusParts = bonusScore.split(';');
        final bonusCorrect = int.tryParse(bonusParts[0]) ?? 0;
        final bonusWrong = int.tryParse(bonusParts.length > 1 ? bonusParts[1] : '0') ?? 0;
        
        if (bonusCorrect == 0 && bonusWrong == 0) {
          checkboxEnabled = false;
        }
        
        mergedAnswers.add({
          'id': qId,
          'num': questionNumer,
          'inputType': inputType,
          'options': options,
          'value': answerText,
          'selected': isSelected,
          'enabled': isEnabled,
          'checkboxEnabled': checkboxEnabled,
        });
      }
      
      setState(() {
        _answers = mergedAnswers;
      });
      
      print('QuestionPage: Built ${mergedAnswers.length} answers from game data');
    } catch (e) {
      print('QuestionPage: Error building answers from game data: $e');
    }
  }
  
  /// Update game info from active game
  void _updateGameInfo(Map<String, dynamic> activeGame) {
    try {
      final gameName = activeGame['game_name'] as String? ?? 'Current Game';
      
      // Get reg_score and bonus_score from first question in cache
      if (_gameData.isNotEmpty) {
        final firstQuestion = _gameData.values.first;
        final regScoreStr = firstQuestion['reg_score'] as String? ?? '1;0';
        final regParts = regScoreStr.split(';');
        final regScore = int.tryParse(regParts[0]) ?? 1;
        final regScoreTotal = int.tryParse(regParts.length > 1 ? regParts[1] : '0') ?? 0;
        
        final bonusScoreStr = firstQuestion['bonus_score'] as String? ?? '0;0';
        final bonusParts = bonusScoreStr.split(';');
        final bonusScore = int.tryParse(bonusParts[0]) ?? 0;
        final bonusScoreTotal = int.tryParse(bonusParts.length > 1 ? bonusParts[1] : '0') ?? 0;
        
        setState(() {
          _gameName = gameName;
          _regScore = regScore;
          _regScoreTotal = regScoreTotal;
          _bonusScore = bonusScore;
          _bonusScoreTotal = bonusScoreTotal;
        });
      } else {
        setState(() {
          _gameName = gameName;
        });
      }
    } catch (e) {
      print('QuestionPage: Error updating game info: $e');
    }
  }
  
  /// Get active game from backend
  Future<Map<String, dynamic>?> _getActiveGame() async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return null;
      }
      
      final response = await http.get(
        Uri.parse('${DatabaseService.baseUrl}/active-games'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as List;
        if (data.isNotEmpty) {
          // Get the first active game that is running
          for (var game in data) {
            if (game['is_started'] == 'running') {
              return game as Map<String, dynamic>;
            }
          }
          // If no running game, return the first one
          return data[0] as Map<String, dynamic>;
        }
      }
      return null;
    } catch (e) {
      print('Error fetching active game: $e');
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
      
      // Convert answers to map keyed by question ID
      final answersMap = <String, Map<String, dynamic>>{};
      for (var answer in _answers) {
        final questionId = answer['id'] as int?;
        if (questionId != null) {
          answersMap[questionId.toString()] = {
            'answer': answer['value'] as String? ?? '',
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

  Future<void> timer_trigger_action() async {
    // TODO: Implement timer_trigger_action
  }

  void _startTimer(int durationInSeconds) {
    // Cancel any existing timers
    _tick?.cancel();
    _blinkTimer?.cancel();
    _stopCountdownTimer?.cancel();
    
    // Set timer counter down to the duration
    timer_counter_down = durationInSeconds;
    
    // Set total time and remaining time
    _totalTime = Duration(seconds: durationInSeconds);
    _remainingTime = Duration(seconds: durationInSeconds);
    _timerStarted = true;
    _isTimerRunning = true;
    _isBlinking = false;
    _stopCountdown = 0;
    
    // Don't start blinking immediately - will start when timer reaches 5 seconds
    
    // Start countdown timer
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      
      if (timer_counter_down > 0) {
        setState(() {
          timer_counter_down--;
          _remainingTime = Duration(seconds: timer_counter_down);
          
          // Start blinking when timer reaches 5 seconds
          if (timer_counter_down == 5 && durationInSeconds > 2) {
            _startBlinking();
          }
          
          // Stop blinking when timer reaches 0
          if (timer_counter_down == 0) {
            _stopBlinking();
            _isTimerRunning = false;
          }
        });
      } else {
        _isTimerRunning = false;
        _tick?.cancel();
      }
    });
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

  void _stopTimer() {
    // Immediately stop timer and set to 0 - no countdown, no notifications
    _isTimerRunning = false;
    _timerStarted = false;
    _tick?.cancel();
    _stopCountdownTimer?.cancel();
    _stopBlinking();
    
    // Immediately set timer to 0
    setState(() {
      timer_counter_down = 0;
      _remainingTime = Duration.zero;
      _stopCountdown = 0;
    });
    
    print('QuestionPage: Timer stopped immediately, set to 0');
  }

  int _buildTimerDuration(String timestamp1, String timestamp2) {
    try {
      // Parse timestamps (format: "YYYY-MM-DD HH:MM:SS")
      final date1 = DateTime.parse(timestamp1);
      final date2 = DateTime.parse(timestamp2);
      
      // Calculate difference in seconds
      final difference = date2.difference(date1).inSeconds;
      
      // Return 0 if negative, otherwise return the difference
      return difference < 0 ? 0 : difference;
    } catch (e) {
      print('Error calculating timer duration: $e');
      return 0;
    }
  }

  void _pauseTimer() {
    _isTimerRunning = false;
    _tick?.cancel();
  }

  void _resetTimer() {
    _isTimerRunning = false;
    _timerStarted = false;
    timer_counter_down = 0;
    _stopCountdown = 0;
    _tick?.cancel();
    _stopCountdownTimer?.cancel();
    _stopBlinking();
    setState(() {
      _remainingTime = _totalTime;
    });
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _handleTimerTrigger(Map<String, dynamic> message) {
    // Only handle if player is on question_page (this method is only called when on the page)
    final timerAction = message['timer_action'] as String?;
    
    if (timerAction == null) {
      return;
    }
    
    switch (timerAction) {
      case 'START_TIME':
        // Handle both string and int types for question_timer
        dynamic questionTimerValue = message['question_timer'];
        int questionTimer = 0;
        if (questionTimerValue is int) {
          questionTimer = questionTimerValue;
        } else if (questionTimerValue is String) {
          questionTimer = int.tryParse(questionTimerValue) ?? 0;
        }
        
        // Adjust timer based on UTC time difference to account for network latency
        int adjustedTimer = _calculateAdjustedTimer(
          questionTimer,
          message['timer_start'],
        );
        
        print('QuestionPage: START_TIME received, question_timer: $questionTimer, adjusted: $adjustedTimer');
        
        if (adjustedTimer > 0) {
          _startTimer(adjustedTimer);
        } else {
          // Timer expired, set to 0
          print('QuestionPage: Timer expired (adjusted value: $adjustedTimer), setting to 0');
          _startTimer(0);
        }
        
        build_question_board(message);
        break;
        
      case 'STOP_TIMER':
        print('QuestionPage: STOP_TIMER received');
        _stopTimer();
        break;
        
      case 'LAST_TIMER':
        // Handle both string and int types for final_timer
        dynamic finalTimerValue = message['final_timer'];
        int finalTimer = 0;
        if (finalTimerValue is int) {
          finalTimer = finalTimerValue;
        } else if (finalTimerValue is String) {
          finalTimer = int.tryParse(finalTimerValue) ?? 0;
        }
        
        // Adjust timer based on UTC time difference to account for network latency
        int adjustedTimer = _calculateAdjustedTimer(
          finalTimer,
          message['timer_start'],
        );
        
        print('QuestionPage: LAST_TIMER received, final_timer: $finalTimer, adjusted: $adjustedTimer');
        
        if (adjustedTimer > 0) {
          _startTimer(adjustedTimer);
        } else {
          // Timer expired, set to 0
          print('QuestionPage: Timer expired (adjusted value: $adjustedTimer), setting to 0');
          _startTimer(0);
        }
        break;
        
      default:
        print('Unknown timer action: $timerAction');
    }
  }

  /// Calculate adjusted timer value based on UTC time difference
  /// Returns: timer_value - (current_utc_time - timer_start).inSeconds
  /// If result is positive, timer should run; if zero or negative, timer expired
  int _calculateAdjustedTimer(int timerValue, dynamic timerStart) {
    try {
      // Parse timer_start - it could be a DateTime string or already a DateTime
      DateTime? startTime;
      
      if (timerStart == null) {
        print('QuestionPage: timer_start is null, using original timer value');
        return timerValue;
      }
      
      if (timerStart is DateTime) {
        // If already a DateTime, ensure it's UTC
        startTime = timerStart.isUtc ? timerStart : timerStart.toUtc();
      } else if (timerStart is String) {
        String timerStartStr = timerStart.trim();
        
        // Parse the datetime string
        DateTime parsedTime;
        try {
          // Try parsing as-is first (handles ISO 8601 with timezone)
          parsedTime = DateTime.parse(timerStartStr);
        } catch (e) {
          // Try parsing as "YYYY-MM-DD HH:MM:SS" format (replace space with T)
          try {
            parsedTime = DateTime.parse(timerStartStr.replaceAll(' ', 'T'));
          } catch (e2) {
            print('QuestionPage: Error parsing timer_start "$timerStart": $e2');
            return timerValue;
          }
        }
        
        // Convert to UTC if not already UTC (backend sends UTC time)
        if (parsedTime.isUtc) {
          startTime = parsedTime;
        } else {
          // Treat as UTC (backend sends naive datetime as UTC)
          startTime = DateTime.utc(
            parsedTime.year,
            parsedTime.month,
            parsedTime.day,
            parsedTime.hour,
            parsedTime.minute,
            parsedTime.second,
            parsedTime.millisecond,
            parsedTime.microsecond,
          );
        }
      } else {
        print('QuestionPage: timer_start is not a valid type: ${timerStart.runtimeType}');
        return timerValue;
      }
      
      // Calculate elapsed time in seconds (both should be UTC)
      final now = DateTime.now().toUtc();
      final elapsedSeconds = now.difference(startTime).inSeconds;
      
      // Adjust timer: timer_value - elapsed_seconds
      final adjustedValue = timerValue - elapsedSeconds;
      
      print('QuestionPage: Timer adjustment - original: $timerValue, elapsed: $elapsedSeconds, adjusted: $adjustedValue');
      
      return adjustedValue.toInt();
    } catch (e) {
      print('QuestionPage: Error calculating adjusted timer: $e');
      // Return original value on error
      return timerValue;
    }
  }

  Widget _buildTimer() {
    // Progress calculation: show remaining/total, default (not started) shows full bar
    final progress = _totalTime.inSeconds > 0 
        ? _remainingTime.inSeconds / _totalTime.inSeconds 
        : 1.0;
    
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
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _gameName,
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
                  '$_regScore/$_regScoreTotal',
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
                  '$_bonusScore/$_bonusScoreTotal',
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

  Widget _buildAnswerSelection() {
    // Check if checkbox should be disabled (bonus score is 0/0)
    final isCheckboxDisabled = _bonusScore == 0 && _bonusScoreTotal == 0;
    
    return Expanded(
      child: Card(
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
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _answers.length,
                itemBuilder: (context, index) {
                  final answer = _answers[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          // Middle: Dynamic input based on type
                          Expanded(
                            child: _buildDynamicInput(answer, index),
                          ),
                          const SizedBox(width: 8),
                          // Right side: Num label (non-editable)
                          SizedBox(
                            width: 60,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  'Num',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  answer['num'].toString(),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Right side: Checkbox
                          Checkbox(
                            value: answer['selected'] as bool,
                            onChanged: (isCheckboxDisabled || !_isWriter)
                                ? null
                                : (value) {
                                    setState(() {
                                      _answers[index]['selected'] = value ?? false;
                                    });
                                    _triggerAutoSave();
                                  },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDynamicInput(Map<String, dynamic> answer, int index) {
    final inputType = answer['inputType'] as String;
    
    switch (inputType) {
      case 'radio':
        return _buildRadioButtons(answer, index);
      case 'list':
        return _buildListOptions(answer, index);
      case 'text':
      default:
        return _buildTextField(answer, index);
    }
  }

  Widget _buildRadioButtons(Map<String, dynamic> answer, int index) {
    final options = answer['options'] as List<String>;
    final selectedValue = answer['value'] as String;
    
    if (options.isEmpty) {
      return const Text('No options available', style: TextStyle(color: Colors.grey));
    }
    
    return Opacity(
      opacity: _isWriter ? 1.0 : 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: options.map((option) {
          return RadioListTile<String>(
            title: Text(
              option,
              style: TextStyle(
                color: _isWriter ? null : Colors.grey.shade600,
              ),
            ),
            value: option,
            groupValue: selectedValue,
            onChanged: _isWriter
                ? (value) {
                    setState(() {
                      _answers[index]['value'] = value ?? '';
                    });
                    _triggerAutoSave();
                  }
                : null,
            contentPadding: EdgeInsets.zero,
            dense: true,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildListOptions(Map<String, dynamic> answer, int index) {
    final options = answer['options'] as List<String>;
    final selectedValues = (answer['value'] as String).split(',').where((v) => v.isNotEmpty).toSet();
    
    if (options.isEmpty) {
      return const Text('No options available', style: TextStyle(color: Colors.grey));
    }
    
    return Opacity(
      opacity: _isWriter ? 1.0 : 0.6,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 200),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, optIndex) {
            final option = options[optIndex];
            final isSelected = selectedValues.contains(option);
            
            return InkWell(
              onTap: _isWriter
                  ? () {
                      setState(() {
                        if (isSelected) {
                          selectedValues.remove(option);
                        } else {
                          selectedValues.add(option);
                        }
                        _answers[index]['value'] = selectedValues.join(',');
                      });
                      _triggerAutoSave();
                    }
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected 
                      ? (_isWriter ? Colors.blue.shade100 : Colors.grey.shade200)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 20,
                      color: isSelected 
                          ? (_isWriter ? Colors.blue : Colors.grey.shade600)
                          : (_isWriter ? Colors.grey : Colors.grey.shade400),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        option,
                        style: TextStyle(
                          color: isSelected 
                              ? (_isWriter ? Colors.blue.shade900 : Colors.grey.shade700)
                              : (_isWriter ? Colors.black87 : Colors.grey.shade600),
                          fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTextField(Map<String, dynamic> answer, int index) {
    return TextField(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        hintText: 'Enter your answer...',
      ),
      enabled: _isWriter,
      maxLines: 3,
      minLines: 1,
      controller: TextEditingController(
        text: answer['value'] as String,
      )..selection = TextSelection.fromPosition(
        TextPosition(offset: (answer['value'] as String).length),
      ),
      onChanged: (value) {
        setState(() {
          _answers[index]['value'] = value;
        });
        _triggerAutoSave();
      },
    );
  }

  Future<void> _handleSave() async {
    try {
      // Save answers to persistent storage
      await _saveAnswers();
      
      // Also save to backend if needed (can be implemented later)
      // For now, just save to local storage
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Answers saved successfully'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Error saving answers: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving answers: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _handleRefresh() async {
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
          
          // Rebuild answers from cached game data and saved answers
          // Get round name from current message or from first answer
          String? roundName;
          if (_answers.isNotEmpty && _gameData.isNotEmpty) {
            // Try to get round name from game data
            final firstQuestion = _gameData.values.first;
            roundName = firstQuestion['round_name'] as String?;
          }
          
          if (roundName != null) {
            await _buildAnswersFromGameData(roundName, null, savedAnswers);
          }
          
          if (mounted) {
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
      if (mounted) {
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
      onPopInvoked: (didPop) async {
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
      body: Padding(
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
            // Answer Selection (scrollable)
            _buildAnswerSelection(),
            const SizedBox(height: 16),
            // Action Button
            ElevatedButton(
              onPressed: _isWriter ? _handleSave : _handleRefresh,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isWriter ? Colors.green : Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                _isWriter ? 'Save' : 'Refresh',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}
