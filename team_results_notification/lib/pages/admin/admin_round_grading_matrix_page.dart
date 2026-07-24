import 'package:flutter/material.dart';
import '../../utils/score_display.dart';
import '../login_page.dart';
import 'admin_question_review_page.dart';
import 'admin_round_list_review_page.dart';

class AdminRoundGradingMatrixPage extends StatefulWidget {
  final int activeGameId;
  final String gameName;
  final String roundName;

  const AdminRoundGradingMatrixPage({
    super.key,
    required this.activeGameId,
    required this.gameName,
    required this.roundName,
  });

  @override
  State<AdminRoundGradingMatrixPage> createState() =>
      _AdminRoundGradingMatrixPageState();
}

class _AdminRoundGradingMatrixPageState
    extends State<AdminRoundGradingMatrixPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _questions = [];
  List<Map<String, dynamic>> _teams = [];
  bool _roundUsesSharedList = false;

  static const _bg = Color(0xFF000000);
  static const _bannerGreen = Color(0xFF2E7D32);
  static const _colBlue = Color(0xFF1565C0);
  static const _textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _loadGrid();
  }

  Future<void> _loadGrid() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final data = await DatabaseService.getRoundGradingGrid(
      widget.activeGameId,
      widget.roundName,
    );
    if (!mounted) return;
    if (data['success'] != true) {
      setState(() {
        _loading = false;
        _error = data['message']?.toString() ?? 'Failed to load grid';
      });
      return;
    }
    setState(() {
      _questions = (data['questions'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      _questions.sort((a, b) {
        final an = int.tryParse('${a['question_num']}') ?? 0;
        final bn = int.tryParse('${b['question_num']}') ?? 0;
        if (an != bn) return an.compareTo(bn);
        return (a['question_id'] as int).compareTo(b['question_id'] as int);
      });
      _teams = (data['teams'] as List? ?? []).cast<Map<String, dynamic>>();
      _roundUsesSharedList = data['round_uses_shared_list'] == true;
      _loading = false;
    });
  }

  Future<void> _openQuestionReview(Map<String, dynamic> question) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _roundUsesSharedList
            ? AdminRoundListReviewPage(
                activeGameId: widget.activeGameId,
                roundName: widget.roundName,
              )
            : AdminQuestionReviewPage(
                activeGameId: widget.activeGameId,
                roundName: widget.roundName,
                questionId: question['question_id'] as int,
              ),
      ),
    );
    if (changed == true) {
      await _loadGrid();
    }
  }

  Color _questionColColor(int index) {
    return index.isOdd ? _colBlue.withValues(alpha: 0.55) : _bg;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(widget.roundName),
        backgroundColor: _bannerGreen,
        foregroundColor: _textWhite,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadGrid,
          ),
        ],
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
                      color: _bannerGreen,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        widget.roundName.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _textWhite,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
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
                  ],
                ),
    );
  }

  Widget _buildTable() {
    const rankW = 44.0;
    const teamW = 160.0;
    const qW = 52.0;
    const totalW = 64.0;
    const rowH = 44.0;
    const headerH = 48.0;

    Widget headerCell(String label, {Color? bg, double w = qW, VoidCallback? onTap}) {
      return Material(
        color: bg ?? _bg,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: w,
            height: headerH,
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: _textWhite,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                decoration: onTap != null ? TextDecoration.underline : null,
              ),
            ),
          ),
        ),
      );
    }

    Widget dataCell(
      String text, {
      required double w,
      Color? bg,
      VoidCallback? onTap,
    }) {
      return Material(
        color: bg ?? _bg,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: w,
            height: rowH,
            alignment: Alignment.center,
            decoration: onTap != null
                ? BoxDecoration(
                    border: Border.all(color: Colors.transparent),
                  )
                : null,
            child: Text(
              text,
              style: const TextStyle(color: _textWhite, fontSize: 14),
            ),
          ),
        ),
      );
    }

    final header = Row(
      children: [
        headerCell('#', w: rankW),
        headerCell('КОМАНДЫ', w: teamW),
        for (var i = 0; i < _questions.length; i++)
          headerCell(
            '${_questions[i]['question_num'] ?? i + 1}',
            bg: _questionColColor(i),
            onTap: () => _openQuestionReview(_questions[i]),
          ),
        headerCell('ИТОГ', bg: _bannerGreen, w: totalW),
      ],
    );

    final rows = <Widget>[];
    for (final team in _teams) {
      final rank = team['rank']?.toString() ?? '';
      final name = team['team_name']?.toString() ?? '';
      final cells = team['cells'] as Map<String, dynamic>? ?? {};
      final total = formatScoreDisplay(
        cells.isNotEmpty
            ? sumAnswerRowPoints(cells)
            : coerceScore(team['round_total']),
      );

      rows.add(
        Row(
          children: [
            dataCell(rank, w: rankW),
            dataCell(
              name,
              w: teamW,
            ),
            for (var i = 0; i < _questions.length; i++)
              Builder(
                builder: (_) {
                  final q = _questions[i];
                  final qid = q['question_id'].toString();
                  final cell = cells[qid] as Map<String, dynamic>?;
                  final pts = formatScoreDisplay(answerRowDisplayPoints(cell));
                  return dataCell(
                    pts,
                    w: qW,
                    bg: _questionColColor(i),
                  );
                },
              ),
            dataCell(total, w: totalW, bg: _bannerGreen),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, ...rows],
    );
  }
}
