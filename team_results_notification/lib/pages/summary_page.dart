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

  /// Matches game table nonempty answer1..answer4; 0 nonempty → single slot.
  int _expectedSlotCountFromQuestion(Map<String, dynamic> question) {
    var c = 0;
    for (final key in ['answer1', 'answer2', 'answer3', 'answer4']) {
      final v = question[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        c++;
      }
    }
    return c == 0 ? 1 : c;
  }

  List<String> _fourPlayerAnswers(Map<String, dynamic>? answer) {
    if (answer == null) {
      return ['', '', '', ''];
    }
    return [
      answer['player_answer1']?.toString() ?? '',
      answer['player_answer2']?.toString() ?? '',
      answer['player_answer3']?.toString() ?? '',
      answer['player_answer4']?.toString() ?? '',
    ];
  }

  int? _asSlotGrade(dynamic v) {
    if (v == null) {
      return null;
    }
    if (v is int) {
      return v;
    }
    return int.tryParse(v.toString());
  }

  bool _hasPerSlotGrades(Map<String, dynamic>? answer) {
    if (answer == null) {
      return false;
    }
    for (final k in ['is_correct_1', 'is_correct_2', 'is_correct_3', 'is_correct_4']) {
      if (answer[k] != null) {
        return true;
      }
    }
    return false;
  }

  /// JSON / SQL may surface whole numbers as [double]; map keys must stay stable for lookups.
  int? _asInt(dynamic v) {
    if (v == null) {
      return null;
    }
    if (v is int) {
      return v;
    }
    if (v is double) {
      return v.round();
    }
    return int.tryParse(v.toString());
  }

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
        final questionId = _asInt(answer['question_id']);
        if (questionId != null) {
          _teamAnswers[questionId] = answer;
        }
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading summary data: $e');
      setState(() {
        _errorMessage = 'Error loading summary: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  /// Earned / admin-adjusted points for totals and pills. Prefer final_score; legacy fallback unchanged.
  num _playerFacingPoints(Map<String, dynamic>? answer) {
    if (answer == null) {
      return 0;
    }
    final fs = answer['final_score'];
    if (fs != null) {
      return _coerceScore(fs);
    }
    if (_hasPerSlotGrades(answer)) {
      return _coerceScore(answer['correct_score']);
    }

    final isCorrect = answer['is_correct'];
    if (isCorrect == null || isCorrect == 0) {
      return 0;
    } else if (isCorrect == 1) {
      return _coerceScore(answer['correct_score']);
    } else if (isCorrect == -1) {
      return _coerceScore(answer['wrong_score']);
    }
    return 0;
  }

  num _luckyBonusPoints(Map<String, dynamic>? answer) {
    if (answer == null) {
      return 0;
    }
    return _coerceScore(answer['lucky_bonus']);
  }

  /// Question score including any populated lucky bonus (used for round totals and row score).
  num _questionTotalPoints(Map<String, dynamic>? answer) {
    return _playerFacingPoints(answer) + _luckyBonusPoints(answer);
  }

  /// Non-empty only when a graded result exists (hides the old "no answer yet" when answer text is present).
  String? _getResultPillText(Map<String, dynamic>? answer) {
    if (answer == null) {
      return null;
    }
    if (_hasPerSlotGrades(answer)) {
      final net = _playerFacingPoints(answer);
      final isCorrect = answer['is_correct'];
      if (isCorrect == 1) {
        return 'correct (+$net)';
      }
      if (isCorrect == -1) {
        return 'incorrect ($net)';
      }
      if (net != 0) {
        return 'partial ($net)';
      }
      return 'graded';
    }
    final isCorrect = answer['is_correct'];
    if (isCorrect == 1) {
      final score = _playerFacingPoints(answer);
      return 'correct (+$score)';
    }
    if (isCorrect == -1) {
      final score = _playerFacingPoints(answer);
      return 'incorrect ($score)';
    }
    return null;
  }

  /// Shown when bonus scores are stored for this row; empty for regular (reg) score.
  String? _bonusNoteForQuestion(
    Map<String, dynamic> question,
    Map<String, dynamic>? answer,
  ) {
    if (answer == null) {
      return null;
    }
    final bStr = (question['bonus_score'] as String? ?? '0;0').split(';');
    final bCr = double.tryParse(bStr[0].trim()) ?? 0.0;
    final bW = double.tryParse(bStr.length > 1 ? bStr[1].trim() : '0') ?? 0.0;
    if (bCr == 0 && bW == 0) {
      return null;
    }
    final cs = (answer['correct_score'] is num) ? (answer['correct_score'] as num).toDouble() : double.tryParse('${answer['correct_score'] ?? 0}') ?? 0.0;
    final ws = (answer['wrong_score'] is num) ? (answer['wrong_score'] as num).toDouble() : double.tryParse('${answer['wrong_score'] ?? 0}') ?? 0.0;
    if (cs == bCr && ws == bW) {
      return 'Bonus';
    }
    return null;
  }

  /// Scores may be int or double from SQL/JSON (e.g. 0.5); never use `as int?` on dynamic.
  num _coerceScore(dynamic raw) {
    if (raw == null) {
      return 0;
    }
    if (raw is num) {
      return raw;
    }
    return num.tryParse(raw.toString()) ?? 0;
  }

  /// One sign only: +N for positive, -N for negative (not "+-N").
  String _formatSignedPoints(num value) {
    if (value > 0) {
      return '+$value';
    }
    if (value < 0) {
      return '$value';
    }
    return '0';
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

  /// Row background for View Results: green (correct), red (incorrect), white (undefined / 0).
  Color _getQuestionRowBackgroundColor(Map<String, dynamic>? answer) {
    if (answer == null) {
      return Colors.white;
    }
    final isCorrect = answer['is_correct'];
    if (isCorrect == 1) {
      return Colors.green.shade50;
    }
    if (isCorrect == -1) {
      return Colors.red.shade50;
    }
    return Colors.white;
  }

  num _getResultScore(Map<String, dynamic>? answer) {
    return _questionTotalPoints(answer);
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
    // Calculate round totals (fractional scores from DB are valid)
    num roundTotalScore = 0;
    int roundCorrectCount = 0;
    int roundIncorrectCount = 0;
    int roundNoAnswerCount = 0;

    for (final question in questions) {
      final questionId = _asInt(question['id']);
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
            color: color.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  Widget _gradeChipForSlot(int? grade) {
    if (grade == null) {
      return const SizedBox.shrink();
    }
    late final Color bg;
    late final Color fg;
    late final String label;
    if (grade == 1) {
      label = '✓';
      bg = Colors.green.shade100;
      fg = Colors.green.shade900;
    } else if (grade == -1) {
      label = '✗';
      bg = Colors.red.shade100;
      fg = Colors.red.shade900;
    } else {
      label = '○';
      bg = Colors.grey.shade200;
      fg = Colors.grey.shade700;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: fg,
        ),
      ),
    );
  }

  /// Per-question answer lines: up to [kSlots] rows with optional per-slot grade chips.
  Widget _buildAnswerLines(Map<String, dynamic> question, Map<String, dynamic>? answer) {
    final kSlots = _expectedSlotCountFromQuestion(question);
    final parts = List<String>.from(_fourPlayerAnswers(answer));
    final syn = answer?['answer']?.toString() ?? '';
    if (parts.every((s) => s.trim().isEmpty) && syn.trim().isNotEmpty) {
      final lines = syn.split('\n');
      for (var i = 0; i < 4 && i < lines.length; i++) {
        parts[i] = lines[i];
      }
    }

    final grades = [
      _asSlotGrade(answer?['is_correct_1']),
      _asSlotGrade(answer?['is_correct_2']),
      _asSlotGrade(answer?['is_correct_3']),
      _asSlotGrade(answer?['is_correct_4']),
    ];

    final children = <Widget>[];
    for (var i = 0; i < kSlots; i++) {
      final t = parts[i].trim();
      final display = t.isEmpty ? '—' : t;
      children.add(
        Padding(
          padding: EdgeInsets.only(top: children.isEmpty ? 0 : 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  kSlots > 1 ? '${i + 1}' : '',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  display,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              _gradeChipForSlot(grades[i]),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildQuestionRow(Map<String, dynamic> question) {
    final questionId = _asInt(question['id']);
    final questionNum = question['question_num']?.toString() ?? 'N/A';
    final answer = questionId != null ? _teamAnswers[questionId] : null;
    final kSlots = _expectedSlotCountFromQuestion(question);
    final pa = _fourPlayerAnswers(answer);
    final syn = answer?['answer']?.toString().trim() ?? '';
    final hasAnswerContent =
        pa.any((s) => s.trim().isNotEmpty) || syn.isNotEmpty;
    final resultPill = _getResultPillText(answer);
    final resultColor = _getResultColor(answer);
    final rowBg = _getQuestionRowBackgroundColor(answer);
    final score = _getResultScore(answer);
    final bonusNote = _bonusNoteForQuestion(question, answer);
    final luckyBonus = _luckyBonusPoints(answer);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
        color: rowBg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                    if (hasAnswerContent && bonusNote != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '($bonusNote)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber.shade900,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (resultPill != null && resultPill.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: resultColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    resultPill,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: resultColor,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          if (hasAnswerContent) ...[
            const SizedBox(height: 8),
            Text(
              kSlots > 1 ? 'Your answers' : 'Answer',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _buildAnswerLines(question, answer),
          ],
          if (luckyBonus != 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Lucky bonus: ${_formatSignedPoints(luckyBonus)}',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.deepPurple.shade800,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (_hasPerSlotGrades(answer) || score != 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Score: $score',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: resultColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
