import 'package:flutter/material.dart';
import 'dart:async';
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
  
  @override
  void initState() {
    super.initState();
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
    
    // Unregister timer message handler
    if (_globalTimerMessageHandler == _handleTimerTrigger) {
      _globalTimerMessageHandler = null;
      print('QuestionPage: Unregistered from timer messages');
    }
    super.dispose();
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
    // TODO: Implement build_question_board
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
                          // Right side: Num field
                          SizedBox(
                            width: 60,
                            child: TextField(
                              decoration: const InputDecoration(
                                labelText: 'Num',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              ),
                              keyboardType: TextInputType.number,
                              enabled: _isWriter,
                              controller: TextEditingController(
                                text: answer['num'].toString(),
                              )..selection = TextSelection.fromPosition(
                                TextPosition(offset: answer['num'].toString().length),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  final numValue = int.tryParse(value) ?? 1;
                                  _answers[index]['num'] = numValue;
                                });
                              },
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
      },
    );
  }

  Future<void> _handleSave() async {
    // TODO: Implement save logic when backend is ready
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Save functionality will be implemented with backend integration'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _handleRefresh() async {
    // TODO: Implement refresh logic when backend is ready
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Refresh functionality will be implemented with backend integration'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Question Page'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
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
    );
  }
}
