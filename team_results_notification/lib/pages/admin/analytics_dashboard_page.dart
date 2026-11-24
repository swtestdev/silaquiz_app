import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../utils/active_game_selection.dart';
import '../../utils/excel_local_save.dart';
import '../login_page.dart';
import 'admin_round_app_tracking_page.dart';
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
  bool _exportInProgress = false;

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
      _showRoundNotStartedSnackBar();
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

  void _openAppTracking(String roundName) {
    if (!_roundIsStarted(roundName)) {
      _showRoundNotStartedSnackBar();
      return;
    }

    final game = _activeGame;
    final gameId = parseActiveGameId(game?['id']);
    if (game == null || gameId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminRoundAppTrackingPage(
          activeGameId: gameId,
          gameName: game['game_name']?.toString() ?? '',
          roundName: roundName,
        ),
      ),
    );
  }

  void _showRoundNotStartedSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This round has not started yet. It will become available after the first slide is recorded in action_game_control.',
        ),
      ),
    );
  }

  Future<void> _startExcelExport() async {
    final game = _activeGame;
    final gameId = parseActiveGameId(game?['id']);
    if (game == null || gameId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active game available to export.')),
      );
      return;
    }

    var exportLocal = true;
    var exportServer = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Export Excel'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Game: ${game['game_name'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Workbook: SUMMARY tab + one tab per round (R1, R2, …).',
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Local'),
                  subtitle: const Text(
                    'Save file on this device (Save dialog)',
                  ),
                  value: exportLocal,
                  onChanged: (v) {
                    setDialogState(() => exportLocal = v ?? false);
                  },
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Server'),
                  subtitle: const Text(
                    'Save to QUZE_EXPORT_SERVER_DIR on the backend',
                  ),
                  value: exportServer,
                  onChanged: (v) {
                    setDialogState(() => exportServer = v ?? false);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (!exportLocal && !exportServer) return;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Export'),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed != true || !mounted) return;

    final destinations = <String>[
      if (exportLocal) 'local',
      if (exportServer) 'server',
    ];

    setState(() => _exportInProgress = true);

    final progress = ValueNotifier<_ExportProgressState>(
      _ExportProgressState(
        progress: 0.05,
        status: 'Starting export…',
      ),
    );

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ExportProgressDialog(progress: progress),
    );

    String? localResult;
    String? serverResult;
    var overallOk = false;

    try {
      progress.value = _ExportProgressState(
        progress: 0.15,
        status: 'Building Excel workbook on server…',
      );

      final result = await DatabaseService.exportActiveGameResults(
        gameId,
        destinations,
      );

      if (result['success'] != true) {
        progress.value = _ExportProgressState(
          progress: 1.0,
          status: result['message']?.toString() ?? 'Export failed',
          failed: true,
        );
      } else {
        progress.value = _ExportProgressState(
          progress: 0.55,
          status: 'Workbook ready (${result['round_count'] ?? '?'} rounds)',
        );

        if (exportServer) {
          final server = result['server'] as Map<String, dynamic>?;
          if (server != null && server['ok'] == true) {
            serverResult =
                'Saved on server:\n${server['path'] ?? server['filename']}';
          } else {
            serverResult =
                'Server export aborted:\n${server?['message'] ?? 'Unknown error'}';
          }
          progress.value = _ExportProgressState(
            progress: 0.72,
            status: server?['ok'] == true
                ? 'Saved on server'
                : 'Server save aborted',
          );
        }

        if (exportLocal) {
          progress.value = _ExportProgressState(
            progress: 0.82,
            status: kIsWeb
                ? 'Starting download…'
                : 'Choose where to save the file…',
          );

          final local = result['local'] as Map<String, dynamic>?;
          final base64Data = local?['file_base64']?.toString();
          final suggestedName =
              local?['filename']?.toString() ?? 'local_export.xlsx';

          if (base64Data == null || base64Data.isEmpty) {
            localResult = 'Local export failed: no file data received.';
          } else {
            final bytes = base64Decode(base64Data);
            final saveResult = await saveExcelLocally(bytes, suggestedName);
            localResult = saveResult.message;
          }
        }

        final serverOk =
            !exportServer || (result['server'] as Map?)?['ok'] == true;
        final localOk = !exportLocal ||
            (localResult?.startsWith('Download started') ?? false) ||
            (localResult?.startsWith('Saved locally') ?? false);
        overallOk = serverOk && localOk;

        progress.value = _ExportProgressState(
          progress: 1.0,
          status: overallOk ? 'Export complete' : 'Export finished with issues',
          failed: !overallOk,
        );
      }
    } catch (e) {
      progress.value = _ExportProgressState(
        progress: 1.0,
        status: 'Export failed: $e',
        failed: true,
      );
    } finally {
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => _exportInProgress = false);
      }
    }

    if (!mounted) return;

    final lines = <String>[];
    if (serverResult != null) lines.add(serverResult);
    if (localResult != null) lines.add(localResult);
    if (lines.isEmpty) {
      lines.add('Export finished.');
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(overallOk ? 'Export complete' : 'Export result'),
        content: SingleChildScrollView(
          child: Text(lines.join('\n\n')),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
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
                    'Select a started round for the scoring matrix or per-player APP tracking (visible / blur / disconnect).',
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
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      started ? Icons.grid_on : Icons.lock_clock,
                                      color: started ? Colors.green : Colors.grey,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            rn,
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                              color: started
                                                  ? null
                                                  : Colors.grey.shade700,
                                            ),
                                          ),
                                          Text(
                                            started
                                                ? 'Round started'
                                                : 'Not started yet',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: started
                                                  ? Colors.green.shade700
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: started
                                            ? () => _openRound(rn)
                                            : null,
                                        icon: const Icon(Icons.grid_on),
                                        label: const Text('Round table'),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed: started
                                            ? () => _openAppTracking(rn)
                                            : null,
                                        icon: const Icon(Icons.monitor_heart),
                                        label: const Text('Tracking APP'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
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
                        child: FilledButton.icon(
                          onPressed: _activeGame != null && !_exportInProgress
                              ? _startExcelExport
                              : null,
                          icon: const Icon(Icons.table_chart),
                          label: const Text('Export Excel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('Export PDF'),
                        ),
                      ),
                    ],
                  ),
                  if (_exportInProgress)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Export in progress…',
                        style: TextStyle(color: Colors.blue),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ExportProgressState {
  final double progress;
  final String status;
  final bool failed;

  const _ExportProgressState({
    required this.progress,
    required this.status,
    this.failed = false,
  });
}

class _ExportProgressDialog extends StatelessWidget {
  final ValueNotifier<_ExportProgressState> progress;

  const _ExportProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Exporting Excel'),
        content: ValueListenableBuilder<_ExportProgressState>(
          valueListenable: progress,
          builder: (context, state, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: state.progress.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: Colors.grey.shade200,
                  color: state.failed ? Colors.orange : Colors.blue,
                ),
                const SizedBox(height: 16),
                Text(
                  '${(state.progress * 100).round()}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  state.status,
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
