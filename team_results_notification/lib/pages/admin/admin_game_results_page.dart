import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../utils/active_game_selection.dart';
import '../../utils/score_display.dart';
import '../login_page.dart';

class AdminGameResultsPage extends StatefulWidget {
  final int? activeGameId;

  const AdminGameResultsPage({super.key, this.activeGameId});

  @override
  State<AdminGameResultsPage> createState() => _AdminGameResultsPageState();
}

class _AdminGameResultsPageState extends State<AdminGameResultsPage> {
  bool _loading = true;
  String? _error;
  String _gameName = '';
  List<String> _roundNames = [];
  List<Map<String, dynamic>> _teams = [];
  int? _resolvedActiveGameId;

  static const _bg = Color(0xFF000000);
  static const _bannerGreen = Color(0xFF2E7D32);
  static const _colBlue = Color(0xFF1565C0);
  static const _textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _loadScoreboard();
  }

  Future<int?> _resolveActiveGameId() async {
    final games = await DatabaseService.getActiveGames();
    final current = pickCurrentActiveGame(games);
    final resolved = parseActiveGameId(current?['id']);
    if (resolved != null) return resolved;
    return widget.activeGameId;
  }

  Future<void> _loadScoreboard() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final activeGameId = await _resolveActiveGameId();
      if (activeGameId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No active game available (all games are idle).';
        });
        return;
      }

      _resolvedActiveGameId = activeGameId;
      if (kDebugMode) {
        print('AdminGameResultsPage: loading scoreboard for active_game_id=$activeGameId');
      }

      final data = await DatabaseService.getActiveGameScoreboard(activeGameId);
      if (!mounted) return;

      if (data['success'] != true) {
        if (kDebugMode) {
          print('AdminGameResultsPage: scoreboard error: ${data['message']}');
        }
        setState(() {
          _loading = false;
          _error = data['message']?.toString() ?? 'Failed to load scoreboard';
        });
        return;
      }

      setState(() {
        _gameName = data['game_name']?.toString() ?? '';
        _roundNames =
            (data['round_names'] as List? ?? []).map((e) => e.toString()).toList();
        _teams = (data['teams'] as List? ?? []).cast<Map<String, dynamic>>();
        _loading = false;
        if (_teams.isEmpty) {
          _error = 'No teams found for this active game.';
        }
      });
    } catch (e) {
      if (kDebugMode) {
        print('AdminGameResultsPage: exception: $e');
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Color _roundColColor(int index) => index.isOdd ? _colBlue.withValues(alpha: 0.55) : _bg;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('View Results'),
        backgroundColor: _bannerGreen,
        foregroundColor: _textWhite,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadScoreboard),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _textWhite))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: _textWhite),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: _bannerGreen,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _gameName.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _textWhite,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (_resolvedActiveGameId != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'Game ID: $_resolvedActiveGameId',
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
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
    const teamW = 180.0;
    const roundW = 72.0;
    const totalW = 72.0;
    const rowH = 44.0;
    const headerH = 48.0;

    Widget headerCell(String label, {Color? bg, double w = roundW}) {
      return Container(
        width: w,
        height: headerH,
        alignment: Alignment.center,
        color: bg ?? _bg,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _textWhite,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      );
    }

    Widget dataCell(String text, {required double w, Color? bg}) {
      return Container(
        width: w,
        height: rowH,
        alignment: Alignment.center,
        color: bg ?? _bg,
        child: Text(
          text,
          style: const TextStyle(color: _textWhite, fontSize: 14),
        ),
      );
    }

    final header = Row(
      children: [
        headerCell('#', w: rankW),
        headerCell('КОМАНДЫ', w: teamW),
        for (var i = 0; i < _roundNames.length; i++)
          headerCell(_roundNames[i], bg: _roundColColor(i), w: roundW),
        headerCell('ИТОГ', bg: _bannerGreen, w: totalW),
      ],
    );

    final rows = <Widget>[];
    for (final team in _teams) {
      final rank = team['rank']?.toString() ?? '';
      final name = team['team_name']?.toString() ?? '';
      final total = formatScoreDisplay(coerceScore(team['total']));
      final roundScores = team['round_scores'] as Map<String, dynamic>? ?? {};

      rows.add(
        Row(
          children: [
            dataCell(rank, w: rankW),
            dataCell(name, w: teamW),
            for (var i = 0; i < _roundNames.length; i++)
              dataCell(
                formatScoreDisplay(
                  coerceScore(roundScores[_roundNames[i]] ?? roundScores[_roundNames[i].toString()]),
                ),
                w: roundW,
                bg: _roundColColor(i),
              ),
            dataCell(total, w: totalW, bg: _bannerGreen),
          ],
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, ...rows]);
  }
}
