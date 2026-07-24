import 'package:flutter/material.dart';

import '../../utils/active_game_selection.dart';
import '../login_page.dart';
import 'admin_round_grading_matrix_page.dart';

class AnalyticsDashboardPage extends StatefulWidget {
  const AnalyticsDashboardPage({super.key});

  @override
  State<AnalyticsDashboardPage> createState() => _AnalyticsDashboardPageState();
}

class _AnalyticsDashboardPageState extends State<AnalyticsDashboardPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _activeGame;
  List<String> _rounds = [];
  Set<String> _startedRounds = {};

  @override
  void initState() {
    super.initState();
    _loadHub();
  }

  Future<void> _loadHub() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final games = await DatabaseService.getActiveGames();
      final current = pickCurrentActiveGame(games);

      List<String> rounds = [];
      Set<String> started = {};

      if (current != null) {
        final fromApi = current['round_names'];
        if (fromApi is List && fromApi.isNotEmpty) {
          rounds = fromApi.map((e) => e.toString()).toList();
        } else {
          final gameName = current['game_name']?.toString() ?? '';
          if (gameName.isNotEmpty) {
            rounds = await DatabaseService.getGameRounds(gameName);
          }
        }

        final gameId = parseActiveGameId(current['id']);
        if (gameId != null) {
          final status = await DatabaseService.getActiveGameStartedRounds(gameId);
          if (status['success'] == true) {
            final raw = status['started_rounds'];
            if (raw is List) {
              started = raw.map((e) => e.toString()).toSet();
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _activeGame = current;
        _rounds = rounds;
        _startedRounds = started;
        _loading = false;
        if (current == null) {
          _error =
              'No active game available. Create or start a game (status must not be idle).';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  bool _roundIsStarted(String roundName) => _startedRounds.contains(roundName);

  void _openRound(String roundName) {
    if (!_roundIsStarted(roundName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This round has not started yet. It will become available after the first slide is recorded in action_game_control.',
          ),
        ),
      );
      return;
    }

    final game = _activeGame;
    final gameId = parseActiveGameId(game?['id']);
    if (game == null || gameId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminRoundGradingMatrixPage(
          activeGameId: gameId,
          gameName: game['game_name']?.toString() ?? '',
          roundName: roundName,
        ),
      ),
    ).then((_) {
      if (mounted) _loadHub();
    });
  }

  void _exportData(String format) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Exporting data as $format...'),
        action: SnackBarAction(
          label: 'View',
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$format export completed')),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics — Grading'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadHub,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Live game grading',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Select a started round to open the scoring matrix and grade team answers.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  if (_activeGame != null) ...[
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.sports_esports, color: Colors.green),
                        title: Text(_activeGame!['game_name']?.toString() ?? 'Game'),
                        subtitle: Text(
                          'Status: ${_activeGame!['is_started'] ?? 'unknown'} · '
                          'ID: ${_activeGame!['id']}',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Rounds',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    if (_rounds.isEmpty)
                      const Text('No rounds found for this game.')
                    else
                      ..._rounds.map((rn) {
                        final started = _roundIsStarted(rn);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: started ? null : Colors.grey.shade100,
                          child: ListTile(
                            leading: Icon(
                              started ? Icons.grid_on : Icons.lock_clock,
                              color: started ? Colors.green : Colors.grey,
                            ),
                            title: Text(
                              rn,
                              style: TextStyle(
                                color: started ? null : Colors.grey.shade700,
                              ),
                            ),
                            subtitle: Text(
                              started
                                  ? 'Round started — tap to open scoreboard'
                                  : 'Not started yet',
                              style: TextStyle(
                                color: started ? Colors.green.shade700 : Colors.grey,
                              ),
                            ),
                            trailing: Icon(
                              started ? Icons.chevron_right : Icons.block,
                              color: started ? null : Colors.grey,
                            ),
                            enabled: started,
                            onTap: started ? () => _openRound(rn) : null,
                          ),
                        );
                      }),
                  ] else if (_error != null)
                    Card(
                      color: Colors.orange.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_error!),
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text(
                    'Export Data',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _exportData('CSV'),
                          icon: const Icon(Icons.file_download),
                          label: const Text('Export CSV'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _exportData('PDF'),
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('Export PDF'),
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
