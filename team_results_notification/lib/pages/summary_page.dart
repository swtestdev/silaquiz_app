import 'package:flutter/material.dart';
import '../services/user_data_service.dart';
import 'login_page.dart'; // For DatabaseService

class SummaryPage extends StatefulWidget {
  const SummaryPage({super.key});

  @override
  State<SummaryPage> createState() => _SummaryPageState();
}

class _SummaryPageState extends State<SummaryPage> {
  bool _isLoading = true;
  String? _errorMessage;
  String? _gameName;
  String? _gameNameSafe;
  int? _teamId;
  List<String> _rounds = [];
  Map<String, List<Map<String, dynamic>>> _roundQuestions = {};
  Map<int, Map<String, dynamic>> _teamAnswers = {}; // Key: question_id, Value: answer data

  @override
  void initState() {
    super.initState();
    // Check if page was refreshed (no navigation history) - redirect to main page (same as Question page)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !Navigator.canPop(context)) {
        Navigator.pushReplacementNamed(context, '/main');
        return;
      }
    });
    _loadSummaryData();
  }

  Future<void> _loadSummaryData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Get user data to find active game and team
      final userData = await UserDataService.getUserData();
      if (userData == null) {
        setState(() {
          _errorMessage = 'User data not found. Please login again.';
          _isLoading = false;
        });
        return;
      }

      // Get team ID - it might be a numeric ID or a team code
      final teamIdRaw = userData['playing_in_team_id'];
      if (teamIdRaw == null) {
        setState(() {
          _errorMessage = 'No team assigned. Please join a team first.';
          _isLoading = false;
        });
        return;
      }

      // Try to parse as int first (if it's a numeric team ID)
      _teamId = int.tryParse(teamIdRaw.toString());
      
      // If parsing fails, it might be a team code - we'll need to handle this
      // For now, we'll try to use it as-is and let the backend handle conversion
      // The backend API should handle team code to ID conversion if needed
      if (_teamId == null) {
        // If it's not a numeric ID, we can't proceed with the current API
        // The backend expects an int for team_id parameter
        setState(() {
          _errorMessage = 'Team ID format not supported. Please contact administrator.';
          _isLoading = false;
        });
        return;
      }

      // Get active game info - we need to get it from the active games list
      final activeGamesResult = await DatabaseService.getPlayerActiveGames(int.parse(userData['id'].toString()));
      final success = activeGamesResult['success'] as bool? ?? false;
      final activeGamesList = activeGamesResult['active_games'] as List?;
      if (!success || activeGamesList == null || activeGamesList.isEmpty) {
        setState(() {
          _errorMessage = 'No active game found.';
          _isLoading = false;
        });
        return;
      }

      // Get the first active/running game
      final activeGame = activeGamesList.firstWhere(
        (game) => game['status'] == 'active' || game['status'] == 'running',
        orElse: () => activeGamesList.first,
      ) as Map<String, dynamic>;

      _gameName = activeGame['game_name'] as String?;
      if (_gameName == null) {
        setState(() {
          _errorMessage = 'Game name not found in active game.';
          _isLoading = false;
        });
        return;
      }

      // Create safe game name (for API calls)
      _gameNameSafe = _gameName!.replaceAll(' ', '_').replaceAll('-', '_').toLowerCase();

      // Load rounds for the game
      final rounds = await DatabaseService.getGameRounds(_gameName!);
      if (rounds.isEmpty) {
        setState(() {
          _errorMessage = 'No rounds found for this game.';
          _isLoading = false;
        });
        return;
      }

      _rounds = rounds;

      // Load questions for each round
      for (final roundName in _rounds) {
        final questions = await DatabaseService.getGameQuestionsByRound(_gameName!, roundName);
        _roundQuestions[roundName] = questions;
      }

      // Load team answers
      final answers = await DatabaseService.getTeamAnswersForGame(_gameNameSafe!, _teamId!);
      for (final answer in answers) {
        final questionId = answer['question_id'] as int?;
        if (questionId != null) {
          _teamAnswers[questionId] = answer;
        }
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading summary data: $e');
      setState(() {
        _errorMessage = 'Error loading summary: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  String _getResultStatus(Map<String, dynamic>? answer) {
    if (answer == null) {
      return 'no answer yet';
    }

    final isCorrect = answer['is_correct'];
    if (isCorrect == null) {
      return 'no answer yet';
    }

    if (isCorrect == 0) {
      return 'no answer yet';
    } else if (isCorrect == 1) {
      final score = answer['correct_score'] ?? 0;
      return 'correct (+$score)';
    } else if (isCorrect == -1) {
      final score = answer['wrong_score'] ?? 0;
      return 'incorrect ($score)';
    }

    return 'unknown';
  }

  Color _getResultColor(Map<String, dynamic>? answer) {
    if (answer == null) {
      return Colors.grey;
    }

    final isCorrect = answer['is_correct'];
    if (isCorrect == null || isCorrect == 0) {
      return Colors.grey;
    } else if (isCorrect == 1) {
      return Colors.green;
    } else if (isCorrect == -1) {
      return Colors.red;
    }

    return Colors.grey;
  }

  int _getResultScore(Map<String, dynamic>? answer) {
    if (answer == null) {
      return 0;
    }

    final isCorrect = answer['is_correct'];
    if (isCorrect == null || isCorrect == 0) {
      return 0;
    } else if (isCorrect == 1) {
      return answer['correct_score'] as int? ?? 0;
    } else if (isCorrect == -1) {
      return answer['wrong_score'] as int? ?? 0;
    }

    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Summary'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.pushReplacementNamed(context, '/main');
            }
          },
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () {
                            if (Navigator.canPop(context)) {
                              Navigator.pop(context);
                            } else {
                              Navigator.pushReplacementNamed(context, '/main');
                            }
                          },
                          child: const Text('Go Back'),
                        ),
                      ],
                    ),
                  ),
                )
              : _rounds.isEmpty
                  ? const Center(child: Text('No rounds found'))
                  : RefreshIndicator(
                      onRefresh: _loadSummaryData,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _rounds.length,
                        itemBuilder: (context, index) {
                          final roundName = _rounds[index];
                          final questions = _roundQuestions[roundName] ?? [];
                          
                          return _buildRoundScorecard(roundName, questions);
                        },
                      ),
                    ),
    );
  }

  Widget _buildRoundScorecard(String roundName, List<Map<String, dynamic>> questions) {
    // Calculate round totals
    int roundTotalScore = 0;
    int roundCorrectCount = 0;
    int roundIncorrectCount = 0;
    int roundNoAnswerCount = 0;

    for (final question in questions) {
      final questionId = question['id'] as int?;
      final answer = questionId != null ? _teamAnswers[questionId] : null;
      final score = _getResultScore(answer);
      roundTotalScore += score;

      if (answer == null) {
        roundNoAnswerCount++;
      } else {
        final isCorrect = answer['is_correct'];
        if (isCorrect == 1) {
          roundCorrectCount++;
        } else if (isCorrect == -1) {
          roundIncorrectCount++;
        } else {
          roundNoAnswerCount++;
        }
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Round Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade700,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  roundName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildRoundStat('Total Score', roundTotalScore.toString(), Colors.white),
                    const SizedBox(width: 16),
                    _buildRoundStat('Correct', roundCorrectCount.toString(), Colors.green.shade300),
                    const SizedBox(width: 16),
                    _buildRoundStat('Incorrect', roundIncorrectCount.toString(), Colors.red.shade300),
                    const SizedBox(width: 16),
                    _buildRoundStat('No Answer', roundNoAnswerCount.toString(), Colors.grey.shade300),
                  ],
                ),
              ],
            ),
          ),
          // Questions List
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Questions & Results:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ...questions.map((question) => _buildQuestionRow(question)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoundStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color.withOpacity(0.8),
          ),
        ),
      ],
    );
  }

  Widget _buildQuestionRow(Map<String, dynamic> question) {
    final questionId = question['id'] as int?;
    final questionNum = question['question_num']?.toString() ?? 'N/A';
    final answer = questionId != null ? _teamAnswers[questionId] : null;
    final answerText = answer?['answer']?.toString() ?? 'No answer';
    final resultStatus = _getResultStatus(answer);
    final resultColor = _getResultColor(answer);
    final score = _getResultScore(answer);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade50,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Q$questionNum',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade900,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: resultColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  resultStatus,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: resultColor,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (answerText != 'No answer')
            Text(
              'Answer: $answerText',
              style: const TextStyle(fontSize: 14),
            ),
          if (score != 0)
            Text(
              'Score: $score',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: resultColor,
              ),
            ),
        ],
      ),
    );
  }
}
