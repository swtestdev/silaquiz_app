import 'package:flutter/material.dart';
import '../../utils/answer_grading.dart';
import '../../utils/score_display.dart';
import '../login_page.dart';

class AdminRoundListReviewPage extends StatefulWidget {
  final int activeGameId;
  final String roundName;

  const AdminRoundListReviewPage({
    super.key,
    required this.activeGameId,
    required this.roundName,
  });

  @override
  State<AdminRoundListReviewPage> createState() =>
      _AdminRoundListReviewPageState();
}

class _CanonicalRowState {
  final int rowIndex;
  final int questionId;
  final int slotCol;
  final String label;
  double correctScore;
  double wrongScore;

  _CanonicalRowState({
    required this.rowIndex,
    required this.questionId,
    required this.slotCol,
    required this.label,
    required this.correctScore,
    required this.wrongScore,
  });
}

class _TeamCellState {
  final int teamId;
  final String teamName;
  String playerAnswer;
  int? isCorrect;
  final int? storedIsCorrect;
  final int questionId;
  final int slotCol;
  final String? baselineAnswer;

  _TeamCellState({
    required this.teamId,
    required this.teamName,
    required this.playerAnswer,
    required this.isCorrect,
    required this.storedIsCorrect,
    required this.questionId,
    required this.slotCol,
    required this.baselineAnswer,
  });
}

class _AdminRoundListReviewPageState extends State<AdminRoundListReviewPage> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<_CanonicalRowState> _rows = [];
  List<Map<String, dynamic>> _teamsMeta = [];
  final Map<String, _TeamCellState> _cells = {};

  static const _bg = Color(0xFF000000);
  static const _bannerGreen = Color(0xFF2E7D32);
  static const _textWhite = Colors.white;

  String _cellKey(int teamId, int rowIndex) => '$teamId:$rowIndex';

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
    final data = await DatabaseService.getRoundListReview(
      widget.activeGameId,
      widget.roundName,
    );
    if (!mounted) return;
    if (data['success'] != true) {
      setState(() {
        _loading = false;
        _error = data['message']?.toString() ?? 'Failed to load list review';
      });
      return;
    }

    final canonical = (data['canonical_rows'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final teamsRaw = (data['teams'] as List? ?? []).cast<Map<String, dynamic>>();

    final rows = canonical.map((r) {
      return _CanonicalRowState(
        rowIndex: r['row_index'] as int,
        questionId: r['question_id'] as int,
        slotCol: r['slot_col'] as int,
        label: (r['label'] ?? '').toString(),
        correctScore: coerceScore(r['default_correct_score']).toDouble(),
        wrongScore: coerceScore(r['default_wrong_score']).toDouble(),
      );
    }).toList();

    _cells.clear();
    for (final team in teamsRaw) {
      final teamId = team['team_id'] as int;
      final teamName = team['team_name']?.toString() ?? '';
      final cells = (team['cells'] as List? ?? []).cast<Map<String, dynamic>>();
      for (final c in cells) {
        final rowIndex = c['row_index'] as int;
        final answer = (c['player_answer'] ?? '').toString();
        final baseline = answer.trim().isNotEmpty ? answer.trim() : null;
        _cells[_cellKey(teamId, rowIndex)] = _TeamCellState(
          teamId: teamId,
          teamName: teamName,
          playerAnswer: answer,
          isCorrect: parseStoredGrade(c['suggested_is_correct']),
          storedIsCorrect: parseStoredGrade(c['stored_is_correct']),
          questionId: c['question_id'] as int,
          slotCol: c['slot_col'] as int,
          baselineAnswer: baseline,
        );
        final row = rows.firstWhere((r) => r.rowIndex == rowIndex);
        row.correctScore = coerceScore(c['correct_score'] ?? row.correctScore).toDouble();
        row.wrongScore = coerceScore(c['wrong_score'] ?? row.wrongScore).toDouble();
      }
    }

    setState(() {
      _rows = rows;
      _teamsMeta = teamsRaw;
      _loading = false;
    });
  }

  _TeamCellState? _cell(int teamId, int rowIndex) =>
      _cells[_cellKey(teamId, rowIndex)];

  Future<void> _onCellTap(_TeamCellState cell) async {
    final hasText = cell.playerAnswer.trim().isNotEmpty;
    if (hasText) {
      setState(() {
        final cur = cell.isCorrect ?? 0;
        cell.isCorrect = cur == 1 ? -1 : 1;
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
            labelText: 'Answer for ${cell.teamName}',
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
      cell.playerAnswer = added;
      cell.isCorrect = -1;
    });
  }

  List<Map<String, dynamic>> _buildSavePayload() {
    final byTeam = <int, List<Map<String, dynamic>>>{};
    for (final row in _rows) {
      for (final team in _teamsMeta) {
        final teamId = team['team_id'] as int;
        final cell = _cell(teamId, row.rowIndex);
        if (cell == null) continue;
        byTeam.putIfAbsent(teamId, () => []);
        final payload = <String, dynamic>{
          'question_id': cell.questionId,
          'slot_col': cell.slotCol,
          'is_correct': cell.isCorrect,
          'correct_score': row.correctScore,
          'wrong_score': row.wrongScore,
        };
        if (cell.baselineAnswer == null && cell.playerAnswer.trim().isNotEmpty) {
          payload['player_answer'] = cell.playerAnswer.trim();
        }
        byTeam[teamId]!.add(payload);
      }
    }
    return byTeam.entries
        .map((e) => {'team_id': e.key, 'cells': e.value})
        .toList();
  }

  Future<void> _saveAndBack() async {
    setState(() => _saving = true);
    final result = await DatabaseService.saveRoundListReviewBatch(
      widget.activeGameId,
      widget.roundName,
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
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    final ctrl = TextEditingController(text: formatScoreDisplay(value));
    return TextField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(color: _textWhite, fontSize: 11),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _bannerGreen),
        ),
      ),
      onChanged: (v) {
        final parsed = double.tryParse(v.trim());
        if (parsed != null) onChanged(parsed);
      },
    );
  }

  Widget _verdictChip(_TeamCellState cell) {
    final text = cell.playerAnswer.trim();
    final label = text.isEmpty ? 'No answer' : text;
    final grade = text.isEmpty ? 0 : (cell.isCorrect ?? 0);
    final chip = Material(
      color: verdictChipColor(grade),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => _onCellTap(cell),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: const BoxConstraints(minWidth: 64, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: verdictChipTextColor(grade),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    return verdictChipWithStoredLine(storedGrade: cell.storedIsCorrect, chip: chip);
  }

  Widget _buildTable() {
    if (_rows.isEmpty || _teamsMeta.isEmpty) {
      return const Center(
        child: Text('No list data', style: TextStyle(color: _textWhite)),
      );
    }

    const labelW = 160.0;
    const corrW = 48.0;
    const wrongW = 48.0;
    const cellW = 96.0;
    const rowH = 52.0;
    const headerH = 48.0;

    Widget headerCell(String label, {double w = cellW}) {
      return Container(
        width: w,
        height: headerH,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(4),
        color: _bannerGreen,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _textWhite,
            fontWeight: FontWeight.bold,
            fontSize: 11,
          ),
        ),
      );
    }

    final header = Row(
      children: [
        headerCell('Right list answers', w: labelW),
        headerCell('+', w: corrW),
        headerCell('−', w: wrongW),
        for (final t in _teamsMeta)
          headerCell(
            t['team_name']?.toString() ?? 'Team',
            w: cellW,
          ),
      ],
    );

    final dataRows = _rows.map((row) {
      return Row(
        children: [
          Container(
            width: labelW,
            height: rowH,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: _bg,
            child: Text(
              row.label,
              style: const TextStyle(color: _textWhite, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: corrW,
            height: rowH,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(4),
            color: _bg,
            child: _scoreField(
              value: row.correctScore,
              onChanged: (v) => setState(() => row.correctScore = v),
            ),
          ),
          Container(
            width: wrongW,
            height: rowH,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(4),
            color: _bg,
            child: _scoreField(
              value: row.wrongScore,
              onChanged: (v) => setState(() => row.wrongScore = v),
            ),
          ),
          for (final t in _teamsMeta)
            Builder(
              builder: (_) {
                final teamId = t['team_id'] as int;
                final cell = _cell(teamId, row.rowIndex);
                return Container(
                  width: cellW,
                  height: rowH,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(4),
                  color: _bg,
                  child: cell != null ? _verdictChip(cell) : const SizedBox(),
                );
              },
            ),
        ],
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, ...dataRows],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text('${widget.roundName} · List review'),
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
                      child: const Text(
                        'SHARED LIST REVIEW',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _textWhite,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
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
