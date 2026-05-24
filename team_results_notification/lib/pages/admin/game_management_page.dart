import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../login_page.dart'; // For DatabaseService
import 'active_game_starting_settings_dialog.dart';

class _ActiveGameSummary {
  const _ActiveGameSummary({
    required this.roundCount,
    required this.questionCount,
    required this.roundNames,
    required this.teamNames,
  });

  final int roundCount;
  final int questionCount;
  final List<String> roundNames;
  final List<String> teamNames;
}

class GameManagementPage extends StatefulWidget {
  const GameManagementPage({super.key});

  @override
  State<GameManagementPage> createState() => _GameManagementPageState();
}

class _GameManagementPageState extends State<GameManagementPage> {
  final ScrollController _scrollController = ScrollController();
  List<Map<String, dynamic>> _activeGames = [];
  Map<int, _ActiveGameSummary> _gameSummaries = {};
  bool _isLoadingGames = true;

  @override
  void initState() {
    super.initState();
    _loadActiveGamesList();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadActiveGamesList() async {
    setState(() {
      _isLoadingGames = true;
    });

    try {
      final games = await DatabaseService.getActiveGames();
      final teams = await DatabaseService.getAllTeams();
      final teamById = <String, String>{
        for (final t in teams)
          t['id'].toString(): (t['team_name'] as String? ?? 'Unknown Team'),
      };

      final summaries = <int, _ActiveGameSummary>{};
      for (final game in games) {
        final activeGameId = game['id'];
        if (activeGameId is! int) {
          continue;
        }

        final teamIds = _parseTeamIds(game['teams_ids']);
        final teamNames = teamIds
            .map((id) => teamById[id] ?? 'Team $id')
            .toList(growable: false);

        var roundCount = 0;
        var questionCount = 0;
        final roundNames = <String>[];

        final fromApi = game['round_names'];
        if (fromApi is List && fromApi.isNotEmpty) {
          roundNames.addAll(
            fromApi.map((e) => e.toString()).where((n) => n.trim().isNotEmpty),
          );
          roundCount = game['round_count'] is num
              ? (game['round_count'] as num).toInt()
              : roundNames.length;
          questionCount = game['question_count'] is num
              ? (game['question_count'] as num).toInt()
              : 0;
        } else {
          final gameId = game['game_id'];
          if (gameId != null) {
            final idInt = gameId is int
                ? gameId
                : int.tryParse(gameId.toString());
            if (idInt != null) {
              final rounds = await DatabaseService.getAdminGameRounds(idInt);
              if (rounds['success'] == true) {
                roundNames.addAll(
                  List<String>.from(rounds['round_names'] ?? []),
                );
                roundCount = rounds['round_count'] is num
                    ? (rounds['round_count'] as num).toInt()
                    : roundNames.length;
                questionCount = rounds['question_count'] is num
                    ? (rounds['question_count'] as num).toInt()
                    : 0;
              }
            }
          }
        }

        summaries[activeGameId] = _ActiveGameSummary(
          roundCount: roundCount,
          questionCount: questionCount,
          roundNames: roundNames,
          teamNames: teamNames,
        );
      }

      if (!mounted) return;
      setState(() {
        _activeGames = games;
        _gameSummaries = summaries;
        _isLoadingGames = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingGames = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading active games: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  List<String> _parseTeamIds(dynamic teamsIds) {
    if (teamsIds == null) return const [];
    return teamsIds
        .toString()
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  int _teamsCount(dynamic teamsIds) => _parseTeamIds(teamsIds).length;

  String _getStatusText(String status) {
    switch (status) {
      case 'idle':
        return 'Idle';
      case 'active':
        return 'Active';
      case 'running':
        return 'Running';
      case 'paused':
        return 'Paused';
      default:
        return status.isEmpty ? 'Unknown' : status;
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'idle':
        return Colors.orange;
      case 'active':
        return Colors.blue;
      case 'running':
        return Colors.green;
      case 'paused':
        return Colors.deepPurple;
      default:
        return Colors.grey;
    }
  }

  void _showGameDetailsDialog(
    Map<String, dynamic> game,
    _ActiveGameSummary summary,
  ) {
    final gameName = game['game_name'] ?? 'Unknown Game';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(gameName),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Status: ${_getStatusText(game['is_started']?.toString() ?? 'idle')}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Rounds',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (summary.roundNames.isEmpty)
                  const Text('No rounds found')
                else
                  ...summary.roundNames.map(
                    (name) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('• '),
                          Expanded(child: Text(name)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                const Text(
                  'Teams',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (summary.teamNames.isEmpty)
                  const Text('No teams assigned')
                else
                  ...summary.teamNames.map(
                    (name) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('• '),
                          Expanded(child: Text(name)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Management'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadActiveGamesList,
            tooltip: 'Refresh active games',
          ),
        ],
      ),
      body: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Manage Games',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Load games and manage active game sessions',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 24),

              Row(
                children: [
                  Expanded(
                    child: _buildActionCard(
                      'Load New Game',
                      Icons.upload_file,
                      Colors.orange,
                      _showLoadGameDialog,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildActionCard(
                      'Active Games',
                      Icons.sports_esports,
                      Colors.blue,
                      _showActiveGames,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              const Text(
                'Active Games',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (_isLoadingGames)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_activeGames.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'No active games found',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _activeGames.length,
                  itemBuilder: (context, index) {
                    final game = _activeGames[index];
                    return _buildActiveGameListTile(game);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveGameListTile(Map<String, dynamic> game) {
    final gameName = game['game_name'] ?? 'Unknown Game';
    final status = game['is_started']?.toString() ?? 'idle';
    final activeGameId = game['id'] is int ? game['id'] as int : null;
    final summary = activeGameId != null ? _gameSummaries[activeGameId] : null;
    final roundCount = summary?.roundCount ?? 0;
    final questionCount = summary?.questionCount ?? 0;
    final playersCount = _teamsCount(game['teams_ids']);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    gameName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Status: ${_getStatusText(status)}',
                    style: TextStyle(
                      fontSize: 14,
                      color: _getStatusColor(status),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Rounds: $roundCount ($questionCount)',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Players: $playersCount',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 48,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'View rounds and teams',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    onPressed: summary == null
                        ? null
                        : () => _showGameDetailsDialog(game, summary),
                    icon: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.blue.shade50,
                      child: Icon(
                        Icons.info_outline,
                        size: 18,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Game settings',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    onPressed: activeGameId == null
                        ? null
                        : () => ActiveGameStartingSettingsDialog.show(
                              context,
                              activeGameId: activeGameId,
                              gameName: gameName,
                            ),
                    icon: Icon(
                      Icons.settings,
                      size: 22,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard(
    String title,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(icon, size: 32, color: color),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLoadGameDialog() {
    showDialog(
      context: context,
      builder: (context) => LoadGameDialog(
        onGameLoaded: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Game loaded successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          _loadActiveGamesList();
        },
      ),
    );
  }

  void _showActiveGames() {
    Navigator.pushNamed(context, '/admin/active-games').then((_) {
      _loadActiveGamesList();
    });
  }
}

class LoadGameDialog extends StatefulWidget {
  final VoidCallback? onGameLoaded;

  const LoadGameDialog({
    super.key,
    this.onGameLoaded,
  });

  @override
  State<LoadGameDialog> createState() => _LoadGameDialogState();
}

class _LoadGameDialogState extends State<LoadGameDialog> {
  bool _isLoading = false;
  String? _errorMessage;
  String? _fileName;
  List<int>? _selectedFileBytes;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.9,
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.upload_file, color: Colors.orange, size: 28),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Load New Game from Excel',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info, color: Colors.blue.shade600, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Excel File Requirements',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '• Excel file can have any number of sheets\n'
                      '• Each sheet will become a separate game\n'
                      '• Game names: {filename}_{sheet_name}\n'
                      '• Each game gets its own database table\n'
                      '• Empty sheets will create empty games',
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: Colors.red.shade600, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _selectedFileBytes != null ? Colors.green : Colors.grey,
                    style: BorderStyle.solid,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Icon(
                      _selectedFileBytes != null ? Icons.check_circle : Icons.cloud_upload,
                      size: 48,
                      color: _selectedFileBytes != null ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _selectedFileBytes != null ? 'File Selected' : 'Select Excel File',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _selectedFileBytes != null ? Colors.green : Colors.grey,
                      ),
                    ),
                    if (_fileName != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _fileName!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _selectFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose File'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isLoading ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _isLoading || _selectedFileBytes == null ? null : _loadGame,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text('Load Game'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _selectFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        allowMultiple: false,
      );

      if (result != null) {
        final file = result.files.single;
        setState(() {
          _fileName = file.name;
          _errorMessage = null;
        });

        if (file.bytes != null) {
          setState(() {
            _selectedFileBytes = file.bytes!;
          });
        } else if (file.path != null) {
          final fileObj = File(file.path!);
          final bytes = await fileObj.readAsBytes();
          setState(() {
            _selectedFileBytes = bytes;
          });
        } else {
          setState(() {
            _errorMessage = 'Unable to access file data';
          });
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error selecting file: $e';
      });
    }
  }

  Future<void> _loadGame() async {
    if (_selectedFileBytes == null || _fileName == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final gameName = _fileName!.replaceAll(RegExp(r'\.(xlsx|xls)$'), '');
      final result = await DatabaseService.loadGameFromExcel(
        gameName,
        _selectedFileBytes!,
      );

      if (result['success'] == true) {
        if (mounted) {
          Navigator.pop(context);
          widget.onGameLoaded?.call();

          final responseData = result['data'];
          var successMessage = 'Excel file processed successfully!\n';
          successMessage += '• File: $gameName\n';

          if (responseData != null) {
            final totalSheets = responseData['total_sheets'] ?? 0;
            final totalRows = responseData['total_rows'] ?? 0;
            final createdGames = responseData['created_games'] as List? ?? [];

            successMessage += '• Games created: $totalSheets\n';
            successMessage += '• Total rows imported: $totalRows\n';
            successMessage += '• Each sheet became a separate game';

            if (createdGames.isNotEmpty) {
              successMessage += '\n\nCreated games:';
              for (var game in createdGames.take(3)) {
                final gName = game['game_name'] ?? 'Unknown';
                final rowCount = game['row_count'] ?? 0;
                successMessage += '\n• $gName ($rowCount rows)';
              }
              if (createdGames.length > 3) {
                successMessage += '\n• ... and ${createdGames.length - 3} more';
              }
            }
          } else {
            successMessage += '• Games and tables created successfully\n';
            successMessage += '• Check the database for created tables\n';
            successMessage += '• Each sheet became a separate game';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(successMessage),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 8),
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = result['message'] ?? 'Failed to load game';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading game: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}
