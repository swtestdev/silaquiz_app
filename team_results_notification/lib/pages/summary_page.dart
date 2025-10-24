import 'package:flutter/material.dart';

class SummaryPage extends StatefulWidget {
  const SummaryPage({super.key});

  @override
  State<SummaryPage> createState() => _SummaryPageState();
}

class _SummaryPageState extends State<SummaryPage> {
  int _score = 0;
  int _totalQuestions = 5;
  int _correctAnswers = 0;
  double _percentage = 0.0;
  String _grade = '';
  String _message = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Get data passed from question page
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    if (args != null) {
      _score = args['score'] ?? 0;
      _totalQuestions = args['totalQuestions'] ?? 5;
      _correctAnswers = args['correctAnswers'] ?? 0;
      _percentage = (_correctAnswers / _totalQuestions) * 100;
      _grade = _getGrade(_percentage);
      _message = _getMessage(_percentage);
    }
  }

  String _getGrade(double percentage) {
    if (percentage >= 90) return 'A+';
    if (percentage >= 80) return 'A';
    if (percentage >= 70) return 'B';
    if (percentage >= 60) return 'C';
    if (percentage >= 50) return 'D';
    return 'F';
  }

  String _getMessage(double percentage) {
    if (percentage >= 90) return 'Outstanding! You\'re a quiz master!';
    if (percentage >= 80) return 'Excellent work! You did great!';
    if (percentage >= 70) return 'Good job! You\'re on the right track!';
    if (percentage >= 60) return 'Not bad! Keep practicing!';
    if (percentage >= 50) return 'You passed! Try to improve next time.';
    return 'Don\'t give up! Practice makes perfect!';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiz Summary'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Score Card
            Card(
              elevation: 8,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _getGradientColors(_percentage),
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.emoji_events,
                      size: 64,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _grade,
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_percentage.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontSize: 24,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _message,
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Statistics
            const Text(
              'Quiz Statistics',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'Score',
                    _score.toString(),
                    Icons.star,
                    Colors.amber,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    'Correct',
                    '$_correctAnswers/$_totalQuestions',
                    Icons.check_circle,
                    Colors.green,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 12),
            
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'Percentage',
                    '${_percentage.toStringAsFixed(1)}%',
                    Icons.percent,
                    Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    'Grade',
                    _grade,
                    Icons.school,
                    Colors.purple,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 24),
            
            // Performance Chart (Simple)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Performance Breakdown',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildPerformanceBar('Correct Answers', _correctAnswers, _totalQuestions, Colors.green),
                    const SizedBox(height: 8),
                    _buildPerformanceBar('Incorrect Answers', _totalQuestions - _correctAnswers, _totalQuestions, Colors.red),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pushReplacementNamed(context, '/question');
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retake Quiz'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pushReplacementNamed(context, '/main');
                    },
                    icon: const Icon(Icons.home),
                    label: const Text('Back to Home'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Share Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  _showShareDialog();
                },
                icon: const Icon(Icons.share),
                label: const Text('Share Results'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPerformanceBar(String label, int value, int total, Color color) {
    final percentage = total > 0 ? value / total : 0.0;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text('$value/$total'),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: percentage,
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ],
    );
  }

  List<Color> _getGradientColors(double percentage) {
    if (percentage >= 90) return [Colors.green, Colors.green.shade700];
    if (percentage >= 80) return [Colors.blue, Colors.blue.shade700];
    if (percentage >= 70) return [Colors.orange, Colors.orange.shade700];
    if (percentage >= 60) return [Colors.yellow, Colors.yellow.shade700];
    return [Colors.red, Colors.red.shade700];
  }

  void _showShareDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share Results'),
        content: Text(
          'I scored $_score points ($_percentage%) on the quiz and got a grade of $_grade! $_message',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Results copied to clipboard!')),
              );
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}

