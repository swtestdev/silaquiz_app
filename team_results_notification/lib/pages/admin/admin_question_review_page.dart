import 'package:flutter/material.dart';
import '../../utils/answer_grading.dart';
import '../../utils/score_display.dart';
import '../login_page.dart';

class AdminQuestionReviewPage extends StatefulWidget {
  final int activeGameId;
  final String roundName;
  final int questionId;

  const AdminQuestionReviewPage({
    super.key,
    required this.activeGameId,
    required this.roundName,
    required this.questionId,
  });

  @override
  State<AdminQuestionReviewPage> createState() =>
      _AdminQuestionReviewPageState();
}

class _TeamReviewState {
  final int teamId;
  final String teamName;
  double correctScore;
  double wrongScore;
  double luckyBonus;
  final List<_SlotState> slots;
  final Map<int, String> baselineAnswers;

  _TeamReviewState({
    required this.teamId,
    required this.teamName,
    required this.correctScore,
    required this.wrongScore,
    required this.luckyBonus,
    required this.slots,
    required this.baselineAnswers,
  });
}

class _SlotState {
  final int col;
  final String reference;
  String playerAnswer;
  int? isCorrect;
  final int? storedIsCorrect;

  _SlotState({
    required this.col,
    required this.reference,
    required this.playerAnswer,
    required this.isCorrect,
    required this.storedIsCorrect,
  });
}

class _AdminQuestionReviewPageState extends State<AdminQuestionReviewPage> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _question;
  List<_TeamReviewState> _teams = [];
  List<int> _orderedCols = [];

  static const _bg = Color(0xFF000000);
  static const _bannerGreen = Color(0xFF2E7D32);
  static const _textWhite = Colors.white;
  /// Match player text slots (see AnswerEditorDialog.textSlotMaxLength).
  static const _answerChipMaxLines = 3;
  static const _slotColumnWidth = 132.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final data = await DatabaseService.getQuestionReview(
      widget.activeGameId,
      widget.roundName,
      widget.questionId,
    );
    if (!mounted) return;
    if (data['success'] != true) {
      setState(() {
        _loading = false;
        _error = data['message']?.toString() ?? 'Failed to load review';
      });
      return;
    }

    final question = Map<String, dynamic>.from(data['question'] as Map);
    _orderedCols = orderedAnswerCols(question);
    if (_orderedCols.isEmpty) _orderedCols = [1];

    final teamsRaw = (data['teams'] as List? ?? []).cast<Map<String, dynamic>>();
    final teams = teamsRaw.map((t) {
      final slotsRaw = (t['slots'] as List? ?? []).cast<Map<String, dynamic>>();
      final baseline = <int, String>{};
      final slots = slotsRaw.map((s) {
        final col = s['col'] as int;
        final answer = (s['player_answer'] ?? '').toString();
        if (answer.trim().isNotEmpty) {
          baseline[col] = answer.trim();
        }
        return _SlotState(
          col: col,
          reference: (s['reference'] ?? '').toString(),
          playerAnswer: answer,
          isCorrect: parseStoredGrade(s['suggested_is_correct']),
          storedIsCorrect: parseStoredGrade(s['stored_is_correct']),
        );
      }).toList();
      return _TeamReviewState(
        teamId: t['team_id'] as int,
        teamName: t['team_name']?.toString() ?? '',
        correctScore: coerceScore(t['correct_score']).toDouble(),
        wrongScore: coerceScore(t['wrong_score']).toDouble(),
        luckyBonus: coerceScore(t['lucky_bonus']).toDouble(),
        slots: slots,
        baselineAnswers: baseline,
      );
    }).toList();

    setState(() {
      _question = question;
      _teams = teams;
      _loading = false;
    });
  }

  ParsedQuestionKind get _parsed =>
      parseAnswersForSelection(_question?['answers_for_selection']?.toString());

  String get _kindLabel {
    switch (_parsed.kind) {
      case 'radio':
        return 'Radio';
      case 'list':
        return 'List';
      default:
        return 'Text';
    }
  }

  Future<void> _onSlotTap(_TeamReviewState team, _SlotState slot) async {
    final hasText = slot.playerAnswer.trim().isNotEmpty;
    if (hasText) {
      setState(() {
        final cur = slot.isCorrect ?? 0;
        slot.isCorrect = cur == 1 ? -1 : 1;
      });
      return;
    }

    final ctrl = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add answer'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Answer for ${team.teamName}',
            hintText: slot.reference.isNotEmpty ? slot.reference : 'Slot ${slot.col}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = ctrl.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx, text);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (added == null || !mounted) return;
    setState(() {
      slot.playerAnswer = added;
      slot.isCorrect = -1;
    });
  }

  List<Map<String, dynamic>> _buildSavePayload() {
    return _teams.map((team) {
      return {
        'team_id': team.teamId,
        'correct_score': team.correctScore,
        'wrong_score': team.wrongScore,
        'lucky_bonus': team.luckyBonus,
        'slots': team.slots.map((s) {
          final slotPayload = <String, dynamic>{
            'col': s.col,
            'is_correct': s.isCorrect,
          };
          final baseline = team.baselineAnswers[s.col];
          if (baseline == null && s.playerAnswer.trim().isNotEmpty) {
            slotPayload['player_answer'] = s.playerAnswer.trim();
          }
          return slotPayload;
        }).toList(),
      };
    }).toList();
  }

  Future<void> _saveAndBack() async {
    setState(() => _saving = true);
    final result = await DatabaseService.saveQuestionReviewBatch(
      widget.activeGameId,
      widget.roundName,
      widget.questionId,
      teams: _buildSavePayload(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result['success'] == true) {
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ?? 'Save failed'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _scoreField({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required double width,
  }) {
    final ctrl = TextEditingController(text: formatScoreDisplay(value));
    return SizedBox(
      width: width,
      child: TextField(
        controller: ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(color: _textWhite, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: _bannerGreen),
          ),
        ),
        onSubmitted: (v) {
          final parsed = double.tryParse(v.trim());
          if (parsed != null) onChanged(parsed);
        },
        onChanged: (v) {
          final parsed = double.tryParse(v.trim());
          if (parsed != null) onChanged(parsed);
        },
      ),
    );
  }

  Widget _verdictChip(_TeamReviewState team, _SlotState slot) {
    final text = slot.playerAnswer.trim();
    final label = text.isEmpty ? 'No answer' : text;
    final grade = text.isEmpty ? 0 : (slot.isCorrect ?? 0);
    final chip = Material(
      color: verdictChipColor(grade),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => _onSlotTap(team, slot),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minWidth: 72, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: _answerChipMaxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: verdictChipTextColor(grade),
              fontSize: 12,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    return verdictChipWithStoredLine(storedGrade: slot.storedIsCorrect, chip: chip);
  }

  Widget _buildTable() {
    if (_teams.isEmpty) {
      return const Center(
        child: Text('No teams', style: TextStyle(color: _textWhite)),
      );
    }

    const corrW = 56.0;
    const wrongW = 56.0;
    const teamW = 140.0;
    const slotW = _slotColumnWidth;
    const bonusW = 56.0;
    const headerH = 56.0;

    Widget headerCell(String label, {double w = slotW}) {
      return Container(
        width: w,
        constraints: const BoxConstraints(minHeight: headerH),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(4),
        color: _bannerGreen,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: _answerChipMaxLines,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _textWhite,
            fontWeight: FontWeight.bold,
            fontSize: 11,
            height: 1.2,
          ),
        ),
      );
    }

    final slotHeaders = _teams.first.slots.map((s) {
      final ref = s.reference.trim();
      return headerCell(ref.isNotEmpty ? ref : 'Slot ${s.col}', w: slotW);
    }).toList();

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headerCell('+', w: corrW),
        headerCell('−', w: wrongW),
        headerCell('КОМАНДЫ', w: teamW),
        ...slotHeaders,
        headerCell('Bonus', w: bonusW),
      ],
    );

    final rows = _teams.map((team) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: corrW,
              alignment: Alignment.center,
              color: _bg,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _scoreField(
                label: '',
                value: team.correctScore,
                width: corrW - 4,
                onChanged: (v) => setState(() => team.correctScore = v),
              ),
            ),
            Container(
              width: wrongW,
              alignment: Alignment.center,
              color: _bg,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _scoreField(
                label: '',
                value: team.wrongScore,
                width: wrongW - 4,
                onChanged: (v) => setState(() => team.wrongScore = v),
              ),
            ),
            Container(
              width: teamW,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: _bg,
              child: Text(
                team.teamName,
                style: const TextStyle(color: _textWhite, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...team.slots.map(
              (slot) => Container(
                width: slotW,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(4),
                color: _bg,
                child: _verdictChip(team, slot),
              ),
            ),
            Container(
              width: bonusW,
              alignment: Alignment.center,
              color: _bg,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _scoreField(
                label: '',
                value: team.luckyBonus,
                width: bonusW - 4,
                onChanged: (v) => setState(() => team.luckyBonus = v),
              ),
            ),
          ],
        ),
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, ...rows],
    );
  }

  @override
  Widget build(BuildContext context) {
    final qnum = _question?['question_num'] ?? widget.questionId;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text('Q$qnum · $_kindLabel'),
        backgroundColor: _bannerGreen,
        foregroundColor: _textWhite,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _textWhite))
          : _error != null
              ? Center(
                  child: Text(_error!, style: const TextStyle(color: _textWhite)),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: _bannerGreen.withValues(alpha: 0.35),
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '${widget.roundName.toUpperCase()} · Question $qnum · $_kindLabel',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _textWhite,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: _buildTable(),
                        ),
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _saving
                                    ? null
                                    : () => Navigator.pop(context),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _textWhite,
                                  side: const BorderSide(color: _textWhite),
                                ),
                                child: const Text('Back No Changes'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _saving ? null : _saveAndBack,
                                style: FilledButton.styleFrom(
                                  backgroundColor: _bannerGreen,
                                ),
                                child: _saving
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: _textWhite,
                                        ),
                                      )
                                    : const Text('Save and Back'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
