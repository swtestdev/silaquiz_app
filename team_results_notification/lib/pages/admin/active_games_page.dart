import 'package:flutter/material.dart';
import '../login_page.dart'; // For DatabaseService
import 'active_game_starting_settings_dialog.dart';

class ActiveGamesPage extends StatefulWidget {
  const ActiveGamesPage({super.key});

  @override
  State<ActiveGamesPage> createState() => _ActiveGamesPageState();
}

class _ActiveGamesPageState extends State<ActiveGamesPage> {
  List<Map<String, dynamic>> _activeGames = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadActiveGames();
  }

  Future<void> _loadActiveGames() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final games = await DatabaseService.getActiveGames();
      setState(() {
        _activeGames = games;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading active games: $e');
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading active games: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Games'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadActiveGames,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active Games Management',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Manage running games and their settings',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: () => _showAddActiveGameDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add New Game'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Active Games List
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _activeGames.isEmpty
                      ? const Center(
                          child: Text(
                            'No active games found',
                            style: TextStyle(fontSize: 18, color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _activeGames.length,
                          itemBuilder: (context, index) {
                            final game = _activeGames[index];
                            return _buildActiveGameCard(game);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveGameCard(Map<String, dynamic> game) {
    final gameName = game['game_name'] ?? 'Unknown Game';
    final status = game['is_started'] ?? 'idle';
    final isLocked = status != 'idle';
    final teamsCount = _getTeamsCount(game['teams_ids']);
    final createdAt = game['timer_on_at']?.toString() ?? 'Unknown';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Game Header
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: _getStatusColor(status),
                  child: Icon(
                    _getStatusIcon(status),
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        gameName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Status: ${_getStatusText(status)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: _getStatusColor(status),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isLocked)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.shade300),
                    ),
                    child: const Text(
                      'LOCKED',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Game settings',
                  onPressed: () {
                    final id = game['id'];
                    final activeGameId =
                        id is int ? id : int.tryParse(id?.toString() ?? '');
                    if (activeGameId == null) return;
                    ActiveGameStartingSettingsDialog.show(
                      context,
                      activeGameId: activeGameId,
                      gameName: gameName,
                    );
                  },
                  icon: Icon(Icons.settings, color: Colors.grey.shade700),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Game Details
            Row(
              children: [
                _buildInfoChip(Icons.group, '$teamsCount teams'),
                const SizedBox(width: 8),
                _buildInfoChip(Icons.access_time, 'Created: ${_formatDate(createdAt)}'),
              ],
            ),
            const SizedBox(height: 12),

            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (status == 'idle') ...[
                  // Idle state - can edit, start, or delete
                  TextButton.icon(
                    onPressed: () => _editActiveGame(game),
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _startActiveGame(game['id']),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Game'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _deleteActiveGame(game),
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                ] else if (status == 'active') ...[
                  // Active state - can run game or stop
                  TextButton.icon(
                    onPressed: () => _runActiveGame(game['id']),
                    icon: const Icon(Icons.play_circle),
                    label: const Text('Run Game'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.blue,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _stopActiveGame(game['id']),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                    ),
                  ),
                ] else if (status == 'running') ...[
                  // Running state - can only stop and remove
                  TextButton.icon(
                    onPressed: () => _stopAndRemoveGame(game),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop & Remove'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'idle':
        return Colors.orange;
      case 'running':
        return Colors.green;
      case 'paused':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'idle':
        return Icons.schedule;
      case 'running':
        return Icons.play_circle;
      case 'paused':
        return Icons.pause_circle;
      default:
        return Icons.help;
    }
  }

  String _getStatusText(String status) {
    switch (status) {
      case 'idle':
        return 'Idle (Unlocked)';
      case 'running':
        return 'Running (Locked)';
      case 'paused':
        return 'Paused (Locked)';
      default:
        return 'Unknown';
    }
  }

  int _getTeamsCount(String? teamsIds) {
    if (teamsIds == null || teamsIds.isEmpty) return 0;
    return teamsIds.split(',').where((id) => id.trim().isNotEmpty).length;
  }

  String _formatDate(String dateString) {
    try {
      final date = DateTime.parse(dateString);
      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return 'Unknown';
    }
  }

  void _showAddActiveGameDialog() {
    showDialog(
      context: context,
      builder: (context) => AddActiveGameDialog(
        onGameAdded: () {
          _loadActiveGames();
        },
      ),
    );
  }

  void _editActiveGame(Map<String, dynamic> game) {
    showDialog(
      context: context,
      builder: (context) => AddActiveGameDialog(
        existingGame: game,
        onGameAdded: () {
          _loadActiveGames();
        },
      ),
    );
  }

  void _deleteActiveGame(Map<String, dynamic> game) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Active Game'),
        content: Text('Are you sure you want to delete "${game['game_name']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performDeleteGame(game);
            },
            child: const Text('Delete'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
    );
  }

  void _pauseGame(Map<String, dynamic> game) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Pausing game: ${game['game_name']}')),
    );
    // TODO: Implement pause game functionality
  }

  void _resumeGame(Map<String, dynamic> game) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Resuming game: ${game['game_name']}')),
    );
    // TODO: Implement resume game functionality
  }

  void _stopAndRemoveGame(Map<String, dynamic> game) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop & Remove Game'),
        content: Text('Are you sure you want to stop and remove "${game['game_name']}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performStopAndRemoveGame(game);
            },
            child: const Text('Stop & Remove'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
    );
  }

  void _startActiveGame(int gameId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start Game'),
        content: const Text('Are you sure you want to start this game? Once started, settings will be locked and cannot be modified.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performStartActiveGame(gameId);
            },
            child: const Text('Start Game'),
            style: TextButton.styleFrom(foregroundColor: Colors.green),
          ),
        ],
      ),
    );
  }

  void _pauseActiveGame(int gameId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pause Game'),
        content: const Text('Are you sure you want to pause this game?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performPauseActiveGame(gameId);
            },
            child: const Text('Pause'),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
          ),
        ],
      ),
    );
  }

  void _resumeActiveGame(int gameId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resume Game'),
        content: const Text('Are you sure you want to resume this game?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performResumeActiveGame(gameId);
            },
            child: const Text('Resume'),
            style: TextButton.styleFrom(foregroundColor: Colors.green),
          ),
        ],
      ),
    );
  }

  Future<void> _performDeleteGame(Map<String, dynamic> game) async {
    try {
      final result = await DatabaseService.deleteActiveGame(game['id']);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Game "${game['game_name']}" deleted successfully'),
            backgroundColor: Colors.green,
          ),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting game: ${result['message']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deleting game: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _performStopAndRemoveGame(Map<String, dynamic> game) async {
    try {
      final result = await DatabaseService.stopAndRemoveActiveGame(game['id']);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Game "${game['game_name']}" stopped and removed successfully'),
            backgroundColor: Colors.green,
          ),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error stopping game: ${result['message']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error stopping game: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _performStartActiveGame(int gameId) async {
    try {
      final result = await DatabaseService.startActiveGame(gameId);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Game started successfully'),
            backgroundColor: Colors.green,
          ),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error starting game: ${result['message']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error starting game: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _performPauseActiveGame(int gameId) async {
    try {
      final result = await DatabaseService.pauseActiveGame(gameId);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Game paused successfully'),
            backgroundColor: Colors.orange,
          ),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error pausing game: ${result['message']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error pausing game: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _performResumeActiveGame(int gameId) async {
    try {
      final result = await DatabaseService.resumeActiveGame(gameId);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Game resumed successfully'),
            backgroundColor: Colors.green,
          ),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error resuming game: ${result['message']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error resuming game: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _stopActiveGame(int activeGameId) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop Game'),
        content: const Text('Are you sure you want to stop this active game? This will return it to idle state.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _performStopActiveGame(activeGameId);
            },
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }

  Future<void> _performStopActiveGame(int activeGameId) async {
    try {
      final result = await DatabaseService.stopActiveGame(activeGameId);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'])),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] ?? 'Failed to stop active game')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error stopping active game: $e')),
      );
    }
  }

  Future<void> _runActiveGame(int activeGameId) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run Game'),
        content: const Text('Are you sure you want to run this active game? This will start the actual game session.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _performRunActiveGame(activeGameId);
            },
            child: const Text('Run'),
          ),
        ],
      ),
    );
  }

  Future<void> _performRunActiveGame(int activeGameId) async {
    try {
      final result = await DatabaseService.runActiveGame(activeGameId);
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'])),
        );
        _loadActiveGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] ?? 'Failed to run active game')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error running active game: $e')),
      );
    }
  }
}

class AddActiveGameDialog extends StatefulWidget {
  final Map<String, dynamic>? existingGame;
  final VoidCallback? onGameAdded;

  const AddActiveGameDialog({
    super.key,
    this.existingGame,
    this.onGameAdded,
  });

  @override
  State<AddActiveGameDialog> createState() => _AddActiveGameDialogState();
}

class _AddActiveGameDialogState extends State<AddActiveGameDialog> {
  List<Map<String, dynamic>> _availableGames = [];
  List<Map<String, dynamic>> _availableTeams = [];
  List<Map<String, dynamic>> _selectedTeams = [];
  List<Map<String, dynamic>> _bonusOptions = [];
  
  String? _selectedGameId;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final games = await DatabaseService.getAllGames();
      final teams = await DatabaseService.getAllTeams();
      final activeGames = await DatabaseService.getActiveGames();
      
      // Filter out games that are already in use by other active games
      final usedGameIds = activeGames
          .where((activeGame) => 
              widget.existingGame == null || // If creating new game
              activeGame['id'] != widget.existingGame!['id']) // Or editing different game
          .map((activeGame) => activeGame['game_id'])
          .toSet();
      
      final availableGames = games
          .where((game) => !usedGameIds.contains(game['id']))
          .toList();
      
      // Filter out teams that are already participating in other active games
      final usedTeamIds = <String>{};
      for (final activeGame in activeGames) {
        if (widget.existingGame == null || activeGame['id'] != widget.existingGame!['id']) {
          // Parse teams_ids string and add to used teams
          final teamsIds = activeGame['teams_ids'] as String?;
          if (teamsIds != null && teamsIds.isNotEmpty) {
            final teamIdList = teamsIds.split(',');
            for (final teamId in teamIdList) {
              usedTeamIds.add(teamId.trim());
            }
          }
        }
      }
      
      final availableTeams = teams
          .where((team) => !usedTeamIds.contains(team['id'].toString()))
          .toList();
      
      setState(() {
        _availableGames = availableGames;
        _availableTeams = availableTeams;
        _isLoading = false;
      });
      
      // Load existing bonus options if editing
      if (widget.existingGame != null) {
        await _loadExistingBonusOptions();
      }
      
      // Populate existing data after loading
      _populateExistingData();
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading data: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadExistingBonusOptions() async {
    try {
      final result = await DatabaseService.getActiveGameBonusOptions(widget.existingGame!['id']);
      if (result['success'] == true) {
        setState(() {
          _bonusOptions = List<Map<String, dynamic>>.from(result['bonus_options'] ?? []);
        });
      }
    } catch (e) {
      print('Error loading existing bonus options: $e');
    }
  }

  void _populateExistingData() {
    if (widget.existingGame != null) {
      final existingGame = widget.existingGame!;
      
      // Set selected game ID
      _selectedGameId = existingGame['game_id']?.toString();
      
      // Parse and set selected teams
      final teamsIds = existingGame['teams_ids']?.toString() ?? '';
      if (teamsIds.isNotEmpty) {
        final teamIdList = teamsIds.split(',').map((id) => id.trim()).toList();
        _selectedTeams = _availableTeams.where((team) {
          return teamIdList.contains(team['id'].toString());
        }).toList();
      }
      
      // Bonus options are loaded in _loadExistingBonusOptions() method
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.9,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.sports_esports, color: Colors.blue, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.existingGame != null ? 'Edit Active Game' : 'Add New Active Game',
                    style: const TextStyle(
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

            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red.shade700),
                ),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Game Selection
                      _buildGameSelection(),
                      const SizedBox(height: 20),

                      // Team Selection
                      _buildTeamSelection(),
                      const SizedBox(height: 20),

                      // Bonus Options
                      _buildBonusOptions(),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 20),

            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _canSave() ? _saveActiveGame : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save Game'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select Game',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (_availableGames.isEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.warning, color: Colors.orange.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No games available. All games are currently being used in other active games.',
                    style: TextStyle(color: Colors.orange.shade700),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          DropdownButtonFormField<String?>(
            value: _selectedGameId,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Choose a game',
            ),
            items: _availableGames.map((game) {
              return DropdownMenuItem<String?>(
                value: game['id'].toString(),
                child: Text(game['game_name'] ?? 'Unknown Game'),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedGameId = value;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _buildTeamSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Select Teams',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text('${_selectedTeams.length} selected'),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 200,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            itemCount: _availableTeams.length,
            itemBuilder: (context, index) {
              final team = _availableTeams[index];
              final isSelected = _selectedTeams.any((t) => t['id'] == team['id']);
              
              return CheckboxListTile(
                title: Text(team['team_name'] ?? 'Unknown Team'),
                subtitle: Text('Code: ${team['team_code'] ?? 'N/A'}'),
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedTeams.add(team);
                    } else {
                      _selectedTeams.removeWhere((t) => t['id'] == team['id']);
                    }
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBonusOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Bonus Options',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            TextButton.icon(
              onPressed: _addBonusOption,
              icon: const Icon(Icons.add),
              label: const Text('Add Option'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_bonusOptions.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: const Text(
              'No bonus options added. Click "Add Option" to create custom scoring rules.',
              style: TextStyle(color: Colors.grey),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _bonusOptions.length,
            itemBuilder: (context, index) {
              return _buildBonusOptionCard(index);
            },
          ),
      ],
    );
  }

  Widget _buildBonusOptionCard(int index) {
    final option = _bonusOptions[index];
    final selectionType = option['selection_type'] ?? 'tier';
    final selectionLines = _formatBonusSelectionLines(option);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    option['name'] ?? 'Unnamed Option',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () => _removeBonusOption(index),
                  icon: const Icon(Icons.delete, color: Colors.red),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Score: ${option['correct_score']}/${option['wrong_score']}'),
            const SizedBox(height: 4),
            Text(
              'Type: ${selectionType == 'tier' ? 'Entire Tier' : 'Specific Questions'}',
              style: TextStyle(
                fontSize: 12,
                color: selectionType == 'tier' ? Colors.blue : Colors.green,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (selectionLines.isNotEmpty) ...[
              const SizedBox(height: 6),
              const Text(
                'Applies to:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              ...selectionLines.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    line,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ),
            ],
            Text(
              'Total: ${option['question_count'] ?? selectionLines.length} question(s)',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _formatBonusSelectionLines(Map<String, dynamic> option) {
    final rawDetails = option['question_details'];
    if (rawDetails is List && rawDetails.isNotEmpty) {
      final byRound = <String, List<String>>{};
      for (final entry in rawDetails) {
        if (entry is! Map) continue;
        final detail = Map<String, dynamic>.from(entry);
        final roundName =
            detail['round_name']?.toString().trim().isNotEmpty == true
                ? detail['round_name'].toString().trim()
                : 'Unknown round';
        final qNum = detail['question_num'];
        final qLabel = qNum != null && '$qNum'.trim().isNotEmpty
            ? 'Q$qNum'
            : 'ID ${detail['id']}';
        byRound.putIfAbsent(roundName, () => []).add(qLabel);
      }
      return byRound.entries
          .map((e) => '${e.key}: ${e.value.join(', ')}')
          .toList();
    }

    final selectionType = option['selection_type'] ?? 'tier';
    final selectedTiers = option['selected_tiers'] as List? ?? [];
    final selectedQuestions = option['selected_questions'] as List? ?? [];
    if (selectionType == 'tier' && selectedTiers.isNotEmpty) {
      return selectedTiers.map((t) => '$t (all questions)').cast<String>().toList();
    }
    if (selectionType == 'question' && selectedQuestions.isNotEmpty) {
      return ['Questions: ${selectedQuestions.join(', ')}'];
    }
    return [];
  }

  void _addBonusOption() {
    if (_selectedGameId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a game before adding a bonus option.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AddBonusOptionDialog(
        selectedGameId: _selectedGameId,
        availableGames: _availableGames,
        onOptionAdded: (option) {
          setState(() {
            _bonusOptions.add(option);
          });
        },
      ),
    );
  }

  void _removeBonusOption(int index) {
    setState(() {
      _bonusOptions.removeAt(index);
    });
  }

  bool _canSave() {
    return _availableGames.isNotEmpty && _selectedGameId != null && _selectedTeams.isNotEmpty;
  }

  Future<void> _saveActiveGame() async {
    if (!_canSave()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      Map<String, dynamic> result;
      
      if (widget.existingGame != null) {
        // Update existing active game
        result = await DatabaseService.updateActiveGame(
          widget.existingGame!['id'],
          _selectedGameId!,
          _selectedTeams.map((t) => t['id'].toString()).toList(),
          _bonusOptions,
        );
      } else {
        // Create new active game
        result = await DatabaseService.createActiveGame(
          _selectedGameId!,
          _selectedTeams.map((t) => t['id'].toString()).toList(),
          _bonusOptions,
        );
      }

      if (result['success'] == true) {
        Navigator.pop(context);
        if (widget.onGameAdded != null) {
          widget.onGameAdded!();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.existingGame != null 
                ? 'Active game updated successfully!' 
                : 'Active game created successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        setState(() {
          _errorMessage = result['message'] ?? 'Failed to save active game';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error saving active game: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
}

class AddBonusOptionDialog extends StatefulWidget {
  final Function(Map<String, dynamic>) onOptionAdded;
  final String? selectedGameId;
  final List<Map<String, dynamic>> availableGames;

  const AddBonusOptionDialog({
    super.key,
    required this.onOptionAdded,
    this.selectedGameId,
    this.availableGames = const [],
  });

  @override
  State<AddBonusOptionDialog> createState() => _AddBonusOptionDialogState();
}

class _AddBonusOptionDialogState extends State<AddBonusOptionDialog> {
  final _nameController = TextEditingController();
  final _correctScoreController = TextEditingController(text: '1');
  final _wrongScoreController = TextEditingController(text: '0');
  
  List<Map<String, dynamic>> _availableTiers = [];
  List<Map<String, dynamic>> _availableQuestions = [];
  List<String> _selectedTiers = [];
  List<String> _selectedQuestions = [];
  String _selectionType = 'tier'; // 'tier' or 'question'
  bool _isLoading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    if (widget.selectedGameId != null) {
      _loadGameData();
    }
  }

  @override
  void didUpdateWidget(covariant AddBonusOptionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedGameId != widget.selectedGameId &&
        widget.selectedGameId != null) {
      _loadGameData();
    }
  }

  Future<void> _loadGameData() async {
    if (widget.selectedGameId == null) return;
    
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final result = await DatabaseService.getGameStructure(widget.selectedGameId!);
      if (result['success'] == true) {
        final tiers = <Map<String, dynamic>>[];
        final questions = <Map<String, dynamic>>[];
        final tiersRaw = result['tiers'];
        final qRaw = result['questions'];
        if (tiersRaw is List) {
          for (final e in tiersRaw) {
            if (e is Map) {
              tiers.add(Map<String, dynamic>.from(e));
            }
          }
        }
        if (qRaw is List) {
          for (final e in qRaw) {
            if (e is Map) {
              questions.add(Map<String, dynamic>.from(e));
            }
          }
        }
        setState(() {
          _availableTiers = tiers;
          _availableQuestions = questions;
          if (questions.isEmpty && tiers.isEmpty) {
            final msg = result['message']?.toString().trim();
            _loadError = (msg != null && msg.isNotEmpty)
                ? msg
                : 'No tiers or questions found for the selected game.';
          }
        });
      } else {
        setState(() {
          _loadError =
              result['message']?.toString() ?? 'Failed to load game structure';
        });
      }
    } catch (e) {
      setState(() {
        _loadError = 'Error loading game data: $e';
      });
      print('Error loading game data: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'Add Bonus Option',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Option Name
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Option Name',
                        border: OutlineInputBorder(),
                        hintText: 'e.g., "РАЗМИНКА", "STATISTICS"',
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Score Settings
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _correctScoreController,
                            decoration: const InputDecoration(
                              labelText: 'Correct Answer Score',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextField(
                            controller: _wrongScoreController,
                            decoration: const InputDecoration(
                              labelText: 'Wrong Answer Score',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Selection Type
                    const Text(
                      'Apply to:',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: RadioListTile<String>(
                            title: const Text('Entire Tier'),
                            value: 'tier',
                            groupValue: _selectionType,
                            onChanged: (value) {
                              setState(() {
                                _selectionType = value!;
                                _selectedQuestions.clear();
                              });
                            },
                          ),
                        ),
                        Expanded(
                          child: RadioListTile<String>(
                            title: const Text('Specific Questions'),
                            value: 'question',
                            groupValue: _selectionType,
                            onChanged: (value) {
                              setState(() {
                                _selectionType = value!;
                                _selectedTiers.clear();
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Selection Lists
                    if (_isLoading)
                      const Center(child: CircularProgressIndicator())
                    else if (_selectionType == 'tier' && _availableTiers.isNotEmpty)
                      _buildTierSelection()
                    else if (_selectionType == 'question' && _availableQuestions.isNotEmpty)
                      _buildQuestionSelection()
                    else if (_loadError != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Text(
                          _loadError!,
                          style: TextStyle(color: Colors.orange.shade900),
                        ),
                      )
                    else if (widget.selectedGameId == null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: const Text(
                          'Please select a game first to load tiers and questions.',
                          style: TextStyle(color: Colors.orange),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: const Text(
                          'No tiers or questions found for the selected game.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            // Fixed footer with buttons
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _canAddOption() ? _addOption : null,
                    child: const Text('Add Option'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTierSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Select Tiers (${_selectedTiers.length} selected)',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            if (_availableTiers.length > 1)
              TextButton.icon(
                onPressed: _toggleSelectAllTiers,
                icon: Icon(_selectedTiers.length == _availableTiers.length 
                    ? Icons.check_box 
                    : Icons.check_box_outline_blank),
                label: Text(_selectedTiers.length == _availableTiers.length 
                    ? 'Deselect All' 
                    : 'Select All'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 120, // Reduced height for tiers since they're typically fewer
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            itemCount: _availableTiers.length,
            itemBuilder: (context, index) {
              final tier = _availableTiers[index];
              final isSelected = _selectedTiers.contains(tier['name']);
              
              return CheckboxListTile(
                dense: true, // More compact layout
                title: Text(
                  tier['name'] ?? 'Unknown Tier',
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  'Questions: ${tier['question_count'] ?? 0}',
                  style: const TextStyle(fontSize: 12),
                ),
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedTiers.add(tier['name']);
                    } else {
                      _selectedTiers.remove(tier['name']);
                    }
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildQuestionSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Select Questions (${_selectedQuestions.length}/${_availableQuestions.length} selected)',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
            if (_availableQuestions.length > 10)
              TextButton.icon(
                onPressed: _toggleSelectAllQuestions,
                icon: Icon(_selectedQuestions.length == _availableQuestions.length 
                    ? Icons.check_box 
                    : Icons.check_box_outline_blank),
                label: Text(_selectedQuestions.length == _availableQuestions.length 
                    ? 'Deselect All' 
                    : 'Select All'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: MediaQuery.of(context).size.height * 0.4, // 2/3 of dialog height for questions
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            itemCount: _availableQuestions.length,
            itemBuilder: (context, index) {
              final question = _availableQuestions[index];
              final isSelected = _selectedQuestions.contains(question['id'].toString());
              final preview =
                  question['preview']?.toString().trim() ?? '';
              final nested = question['data'];
              final roundName = (question['round_name']?.toString().trim().isNotEmpty == true)
                  ? question['round_name'].toString().trim()
                  : (nested is Map<String, dynamic>
                      ? (nested['round_name']?.toString().trim() ?? '')
                      : '');
              final qNum = question['question_num'];
              final qId = question['id'];
              final questionLabel = qNum != null && '$qNum'.trim().isNotEmpty
                  ? 'Question $qNum'
                  : 'Question $qId';
              final linkFromData = nested is Map<String, dynamic>
                  ? (nested['links_for_question']?.toString().trim() ?? '')
                  : '';
              final commFromData = nested is Map<String, dynamic>
                  ? (nested['comments']?.toString().trim() ?? '')
                  : '';
              final subtitleText = preview.isNotEmpty
                  ? preview
                  : (linkFromData.isNotEmpty
                      ? linkFromData
                      : (commFromData.isNotEmpty
                          ? commFromData
                          : 'No links or notes'));
              
              return CheckboxListTile(
                dense: true,
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        questionLabel,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (roundName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          roundName,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.blue.shade800,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                  ],
                ),
                subtitle: Text(
                  subtitleText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedQuestions.add(question['id'].toString());
                    } else {
                      _selectedQuestions.remove(question['id'].toString());
                    }
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _toggleSelectAllTiers() {
    setState(() {
      if (_selectedTiers.length == _availableTiers.length) {
        // Deselect all
        _selectedTiers.clear();
      } else {
        // Select all
        _selectedTiers = _availableTiers.map((t) => t['name'] as String).toList();
      }
    });
  }

  void _toggleSelectAllQuestions() {
    setState(() {
      if (_selectedQuestions.length == _availableQuestions.length) {
        // Deselect all
        _selectedQuestions.clear();
      } else {
        // Select all
        _selectedQuestions = _availableQuestions.map((q) => q['id'].toString()).toList();
      }
    });
  }

  bool _canAddOption() {
    if (_nameController.text.trim().isEmpty) return false;
    if (_selectionType == 'tier' && _selectedTiers.isEmpty) return false;
    if (_selectionType == 'question' && _selectedQuestions.isEmpty) return false;
    return true;
  }

  void _addOption() {
    if (!_canAddOption()) return;

    final questionDetails = _buildQuestionDetailsForSelection();

    final option = {
      'name': _nameController.text.trim(),
      'correct_score': int.tryParse(_correctScoreController.text) ?? 1,
      'wrong_score': int.tryParse(_wrongScoreController.text) ?? 0,
      'selection_type': _selectionType,
      'selected_tiers': List<String>.from(_selectedTiers),
      'selected_questions': questionDetails
          .map((q) => q['id'].toString())
          .toList(),
      'question_details': questionDetails,
      'question_count': questionDetails.length,
    };

    widget.onOptionAdded(option);
    Navigator.pop(context);
  }

  List<Map<String, dynamic>> _buildQuestionDetailsForSelection() {
    final details = <Map<String, dynamic>>[];

    String roundNameFor(Map<String, dynamic> question) {
      final direct = question['round_name']?.toString().trim();
      if (direct != null && direct.isNotEmpty) return direct;
      final nested = question['data'];
      if (nested is Map) {
        return nested['round_name']?.toString().trim() ?? '';
      }
      return '';
    }

    if (_selectionType == 'tier') {
      for (final question in _availableQuestions) {
        final roundName = roundNameFor(question);
        if (_selectedTiers.contains(roundName)) {
          details.add({
            'id': question['id'],
            'round_name': roundName,
            'question_num': question['question_num'],
          });
        }
      }
      return details;
    }

    for (final qid in _selectedQuestions) {
      Map<String, dynamic>? question;
      for (final q in _availableQuestions) {
        if (q['id'].toString() == qid) {
          question = q;
          break;
        }
      }
      if (question == null) continue;
      details.add({
        'id': question['id'],
        'round_name': roundNameFor(question),
        'question_num': question['question_num'],
      });
    }
    return details;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _correctScoreController.dispose();
    _wrongScoreController.dispose();
    super.dispose();
  }
}

