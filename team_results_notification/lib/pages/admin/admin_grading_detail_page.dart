import 'package:flutter/material.dart';
import '../../utils/answer_grading.dart';
import '../../utils/score_display.dart';
import '../login_page.dart';

class AdminGradingDetailPage extends StatefulWidget {
  final int activeGameId;
  final String roundName;
  final int teamId;
  final String teamName;
  final Map<String, dynamic> question;
  final Map<String, dynamic>? cell;

  const AdminGradingDetailPage({
    super.key,
    required this.activeGameId,
    required this.roundName,
    required this.teamId,
    required this.teamName,
    required this.question,
    this.cell,
  });

  @override
  State<AdminGradingDetailPage> createState() => _AdminGradingDetailPageState();
}

class _AdminGradingDetailPageState extends State<AdminGradingDetailPage> {
  late List<int> _orderedCols;
  late Map<int, int?> _decisions;
  late List<TextEditingController> _playerCtrls;
  late TextEditingController _scoreOverrideCtrl;
  bool _saving = false;
  bool _useScoreOverride = false;

  @override
  void initState() {
    super.initState();
    _orderedCols = orderedAnswerCols(widget.question);
    _decisions = {};
    for (final col in _orderedCols) {
      final key = 'is_correct_$col';
      final cur = widget.cell?[key];
      final sug = widget.cell?['suggested_is_correct_$col'];
      _decisions[col] = cur is int
          ? cur
          : (cur != null ? int.tryParse(cur.toString()) : null) ??
              (sug is int ? sug : int.tryParse(sug?.toString() ?? ''));
    }
    _playerCtrls = List.generate(4, (i) {
      final col = i + 1;
      final v = widget.cell?['player_answer$col']?.toString() ?? '';
      return TextEditingController(text: v);
    });
    final fs = widget.cell?['final_score'];
    _scoreOverrideCtrl = TextEditingController(
      text: fs != null ? formatScoreDisplay(coerceScore(fs)) : '',
    );
    _useScoreOverride = fs != null;
  }

  @override
  void dispose() {
    for (final c in _playerCtrls) {
      c.dispose();
    }
    _scoreOverrideCtrl.dispose();
    super.dispose();
  }

  ParsedQuestionKind get _parsed =>
      parseAnswersForSelection(widget.question['answers_for_selection']?.toString());

  String get _kindLabel {
    switch (_parsed.kind) {
      case 'radio':
        return 'Radio';
      case 'list':
        return 'List';
      case 'equals':
        return 'Text';
      default:
        return 'Text';
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    double? overrideScore;
    if (_useScoreOverride && _scoreOverrideCtrl.text.trim().isNotEmpty) {
      overrideScore = double.tryParse(_scoreOverrideCtrl.text.trim());
    }

    final result = await DatabaseService.saveAdminGrade(
      widget.activeGameId,
      teamId: widget.teamId,
      questionId: widget.question['question_id'] as int,
      playerAnswer1: _playerCtrls[0].text,
      playerAnswer2: _playerCtrls[1].text,
      playerAnswer3: _playerCtrls[2].text,
      playerAnswer4: _playerCtrls[3].text,
      isCorrect1: _orderedCols.contains(1) ? _decisions[1] : null,
      isCorrect2: _orderedCols.contains(2) ? _decisions[2] : null,
      isCorrect3: _orderedCols.contains(3) ? _decisions[3] : null,
      isCorrect4: _orderedCols.contains(4) ? _decisions[4] : null,
      finalScore: overrideScore,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Grade saved')),
      );
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

  Widget _panel(String title, Widget child) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Widget _referencePanel() {
    final reg = coerceScore(widget.question['reg_score'] ?? widget.cell?['correct_score']);
    final wrong = coerceScore(widget.cell?['wrong_score'] ?? 0);
    final children = <Widget>[];

    if (_parsed.kind == 'radio') {
      children.add(Text('Options pool: ${_parsed.options.join(' · ')}'));
      final correct = answerCellText(widget.question, 1);
      children.add(Text('Correct choice: $correct'));
    } else if (_parsed.kind == 'list') {
      final pool = widget.question['list_pool'];
      if (pool is List && pool.isNotEmpty) {
        children.add(Text('Full list pool: ${pool.join(' · ')}'));
      }
      children.add(const SizedBox(height: 4));
      for (final col in _orderedCols) {
        final syns = splitSynonyms(answerCellText(widget.question, col));
        children.add(Text('Slot $col → ${syns.join(' ; ')}'));
      }
    } else {
      for (final col in _orderedCols) {
        final syns = splitSynonyms(answerCellText(widget.question, col));
        if (syns.isEmpty) {
          children.add(Text('Slot $col: —'));
        } else {
          children.add(Text('Slot $col: ${syns.join(' ; ')}'));
        }
      }
    }
    children.add(const SizedBox(height: 8));
    children.add(Text('Points: +$reg if correct · $wrong if wrong'));

    return _panel('REFERENCE — CORRECT ANSWER(S)  [$_kindLabel]', Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ));
  }

  Widget _playerPanel() {
    return _panel(
      'PLAYER ANSWER',
      Column(
        children: _orderedCols.map((col) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _playerCtrls[col - 1],
              decoration: InputDecoration(
                labelText: 'Slot $col',
                border: const OutlineInputBorder(),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _autoCheckPanel() {
    return _panel(
      'AUTO-CHECK (strict match)',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _orderedCols.map((col) {
          final sug = widget.cell?['suggested_is_correct_$col'];
          final grade = sug is int ? sug : int.tryParse(sug?.toString() ?? '');
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Slot $col: ${autoCheckEmoji(grade)} ${slotGradeLabel(grade)}',
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _decisionPanel() {
    return _panel(
      'YOUR DECISION',
      Column(
        children: [
          ..._orderedCols.map((col) {
            final val = _decisions[col];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Slot $col', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Row(
                    children: [
                      Expanded(
                        child: RadioListTile<int>(
                          title: const Text('Correct'),
                          value: 1,
                          groupValue: val,
                          onChanged: (v) => setState(() => _decisions[col] = v),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<int>(
                          title: const Text('Wrong'),
                          value: -1,
                          groupValue: val,
                          onChanged: (v) => setState(() => _decisions[col] = v),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<int>(
                          title: const Text('No answer'),
                          value: 0,
                          groupValue: val,
                          onChanged: (v) => setState(() => _decisions[col] = v),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
          SwitchListTile(
            title: const Text('Override score manually'),
            value: _useScoreOverride,
            onChanged: (v) => setState(() => _useScoreOverride = v),
          ),
          if (_useScoreOverride)
            TextField(
              controller: _scoreOverrideCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Final score',
                border: OutlineInputBorder(),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final qnum = widget.question['question_num'] ?? widget.question['question_id'];
    return Scaffold(
      appBar: AppBar(
        title: Text('Q$qnum · ${widget.teamName}'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Round: ${widget.roundName}',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            _referencePanel(),
            _playerPanel(),
            _autoCheckPanel(),
            _decisionPanel(),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Back to matrix'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
