import 'package:flutter/material.dart';
import 'dart:async';

class QuestionPage extends StatefulWidget {
  const QuestionPage({super.key});

  @override
  State<QuestionPage> createState() => _QuestionPageState();
}

class _QuestionPageState extends State<QuestionPage> {
  int _currentQuestionIndex = 0;
  int? _selectedAnswer;
  bool _isAnswered = false;
  bool _showResult = false;
  int _score = 0;

  // Simple local quiz timer (UI moved from main page)
  Duration _gameTime = Duration.zero;
  Duration _totalTime = const Duration(minutes: 45);
  bool _isTimerRunning = false;
  int? _currentSlide;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _startLocalTimer();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _startLocalTimer() {
    _isTimerRunning = true;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_isTimerRunning) {
        setState(() {
          _gameTime = Duration(seconds: _gameTime.inSeconds + 1);
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildTimeBar() {
    final progress = _totalTime.inSeconds > 0 ? _gameTime.inSeconds / _totalTime.inSeconds : 0.0;
    final currentTime = _formatDuration(_gameTime);
    final totalTime = _formatDuration(_totalTime);
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
                  color: _isTimerRunning ? Colors.green.shade700 : Colors.orange.shade700,
                ),
                const SizedBox(width: 8),
                Text(
                  'Quiz Timer',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _isTimerRunning ? Colors.green.shade700 : Colors.orange.shade700,
                  ),
                ),
                if (_currentSlide != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Slide $_currentSlide',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
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
                  _isTimerRunning ? Colors.green.shade600 : Colors.orange.shade600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  currentTime,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: _isTimerRunning ? Colors.green.shade600 : Colors.orange.shade600,
                  ),
                ),
                Text(
                  totalTime,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Sample questions data
  final List<Map<String, dynamic>> _questions = [
    {
      'question': 'What is the capital of France?',
      'options': ['London', 'Berlin', 'Paris', 'Madrid'],
      'correct': 2,
      'explanation': 'Paris is the capital and largest city of France.',
    },
    {
      'question': 'Which planet is known as the Red Planet?',
      'options': ['Venus', 'Mars', 'Jupiter', 'Saturn'],
      'correct': 1,
      'explanation': 'Mars is often called the Red Planet due to iron oxide on its surface.',
    },
    {
      'question': 'What is 2 + 2?',
      'options': ['3', '4', '5', '6'],
      'correct': 1,
      'explanation': '2 + 2 equals 4.',
    },
    {
      'question': 'Who painted the Mona Lisa?',
      'options': ['Vincent van Gogh', 'Pablo Picasso', 'Leonardo da Vinci', 'Michelangelo'],
      'correct': 2,
      'explanation': 'Leonardo da Vinci painted the Mona Lisa between 1503-1519.',
    },
    {
      'question': 'What is the largest ocean on Earth?',
      'options': ['Atlantic', 'Indian', 'Pacific', 'Arctic'],
      'correct': 2,
      'explanation': 'The Pacific Ocean is the largest and deepest ocean on Earth.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final currentQuestion = _questions[_currentQuestionIndex];
    final isLastQuestion = _currentQuestionIndex == _questions.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text('Question ${_currentQuestionIndex + 1} of ${_questions.length}'),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Timer moved here under Question page
            _buildTimeBar(),
            const SizedBox(height: 16),
            // Progress indicator
            LinearProgressIndicator(
              value: (_currentQuestionIndex + 1) / _questions.length,
              backgroundColor: Colors.grey[300],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
            const SizedBox(height: 24),
            
            // Question card
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentQuestion['question'],
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // Answer options
                    ...List.generate(
                      currentQuestion['options'].length,
                      (index) => _buildOptionTile(
                        index,
                        currentQuestion['options'][index],
                        currentQuestion['correct'],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Explanation (shown after answering)
            if (_showResult) ...[
              Card(
                color: _selectedAnswer == currentQuestion['correct'] 
                    ? Colors.green.withOpacity(0.1)
                    : Colors.red.withOpacity(0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _selectedAnswer == currentQuestion['correct']
                                ? Icons.check_circle
                                : Icons.cancel,
                            color: _selectedAnswer == currentQuestion['correct']
                                ? Colors.green
                                : Colors.red,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _selectedAnswer == currentQuestion['correct']
                                ? 'Correct!'
                                : 'Incorrect!',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _selectedAnswer == currentQuestion['correct']
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        currentQuestion['explanation'],
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            
            const Spacer(),
            
            // Action buttons
            Row(
              children: [
                if (_currentQuestionIndex > 0)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _showResult ? _previousQuestion : null,
                      child: const Text('Previous'),
                    ),
                  ),
                if (_currentQuestionIndex > 0) const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isAnswered && !_showResult
                        ? _checkAnswer
                        : _showResult
                            ? (isLastQuestion ? _finishQuiz : _nextQuestion)
                            : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(
                      _isAnswered && !_showResult
                          ? 'Check Answer'
                          : _showResult
                              ? (isLastQuestion ? 'Finish Quiz' : 'Next Question')
                              : 'Select an answer',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionTile(int index, String option, int correctAnswer) {
    Color? backgroundColor;
    Color? textColor;
    IconData? icon;

    if (_showResult) {
      if (index == correctAnswer) {
        backgroundColor = Colors.green.withOpacity(0.2);
        textColor = Colors.green;
        icon = Icons.check_circle;
      } else if (index == _selectedAnswer && index != correctAnswer) {
        backgroundColor = Colors.red.withOpacity(0.2);
        textColor = Colors.red;
        icon = Icons.cancel;
      }
    } else if (_selectedAnswer == index) {
      backgroundColor = Colors.blue.withOpacity(0.2);
      textColor = Colors.blue;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: backgroundColor,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _selectedAnswer == index ? Colors.blue : Colors.grey[300],
          child: Text(
            String.fromCharCode(65 + index), // A, B, C, D
            style: TextStyle(
              color: _selectedAnswer == index ? Colors.white : Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          option,
          style: TextStyle(
            color: textColor,
            fontWeight: _selectedAnswer == index ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        trailing: icon != null ? Icon(icon, color: textColor) : null,
        onTap: _showResult ? null : () {
          setState(() {
            _selectedAnswer = index;
            _isAnswered = true;
          });
        },
      ),
    );
  }

  void _checkAnswer() {
    setState(() {
      _showResult = true;
      if (_selectedAnswer == _questions[_currentQuestionIndex]['correct']) {
        _score += 10;
      }
    });
  }

  void _nextQuestion() {
    setState(() {
      _currentQuestionIndex++;
      _selectedAnswer = null;
      _isAnswered = false;
      _showResult = false;
    });
  }

  void _previousQuestion() {
    setState(() {
      _currentQuestionIndex--;
      _selectedAnswer = null;
      _isAnswered = false;
      _showResult = false;
    });
  }

  void _finishQuiz() {
    Navigator.pushReplacementNamed(
      context,
      '/summary',
      arguments: {
        'score': _score,
        'totalQuestions': _questions.length,
        'correctAnswers': _score ~/ 10,
      },
    );
  }
}

