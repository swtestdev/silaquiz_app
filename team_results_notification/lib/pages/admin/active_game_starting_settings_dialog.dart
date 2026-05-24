import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../login_page.dart';

class ActiveGameStartingSettingsDialog extends StatefulWidget {
  final int activeGameId;
  final String gameName;

  const ActiveGameStartingSettingsDialog({
    super.key,
    required this.activeGameId,
    required this.gameName,
  });

  static Future<void> show(
    BuildContext context, {
    required int activeGameId,
    required String gameName,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => ActiveGameStartingSettingsDialog(
        activeGameId: activeGameId,
        gameName: gameName,
      ),
    );
  }

  @override
  State<ActiveGameStartingSettingsDialog> createState() =>
      _ActiveGameStartingSettingsDialogState();
}

class _TeamStartRow {
  _TeamStartRow({
    required this.teamId,
    required this.teamName,
    required this.maxPlayersController,
    required this.playPlayersController,
    required this.startPointsController,
  });

  final int teamId;
  final String teamName;
  final TextEditingController maxPlayersController;
  final TextEditingController playPlayersController;
  final TextEditingController startPointsController;

  void dispose() {
    maxPlayersController.dispose();
    playPlayersController.dispose();
    startPointsController.dispose();
  }

  Map<String, dynamic> toPayload() {
    return {
      'team_id': teamId,
      'max_players': int.tryParse(maxPlayersController.text.trim()) ?? 12,
      'play_players': int.tryParse(playPlayersController.text.trim()) ?? 0,
      'start_points':
          double.tryParse(startPointsController.text.trim()) ?? 0.0,
    };
  }

  double computeTotal() {
    final maxP = int.tryParse(maxPlayersController.text.trim()) ?? 12;
    final playP = int.tryParse(playPlayersController.text.trim()) ?? 0;
    final startP = double.tryParse(startPointsController.text.trim()) ?? 0.0;
    if (maxP >= playP) return startP;
    return maxP - playP + startP;
  }
}

class _ActiveGameStartingSettingsDialogState
    extends State<ActiveGameStartingSettingsDialog> {
  final List<_TeamStartRow> _rows = [];
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final result =
          await DatabaseService.getActiveGameTeamsStart(widget.activeGameId);
      if (!mounted) return;
      if (result['success'] == true) {
        for (final row in _rows) {
          row.dispose();
        }
        _rows.clear();
        final teams = List<Map<String, dynamic>>.from(result['teams'] ?? []);
        for (final team in teams) {
          _rows.add(
            _TeamStartRow(
              teamId: int.parse(team['team_id'].toString()),
              teamName: team['team_name']?.toString() ?? 'Team',
              maxPlayersController: TextEditingController(
                text: '${team['max_players'] ?? 12}',
              ),
              playPlayersController: TextEditingController(
                text: '${team['play_players'] ?? 0}',
              ),
              startPointsController: TextEditingController(
                text: '${team['start_points'] ?? 0}',
              ),
            ),
          );
        }
        setState(() {
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage =
              result['message']?.toString() ?? 'Failed to load settings';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error loading settings: $e';
      });
    }
  }

  Future<void> _saveSettings() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final payload = _rows.map((row) => row.toPayload()).toList();
      final result = await DatabaseService.updateActiveGameTeamsStart(
        widget.activeGameId,
        payload,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result['message']?.toString() ?? 'Starting settings saved',
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        setState(() {
          _isSaving = false;
          _errorMessage =
              result['message']?.toString() ?? 'Failed to save settings';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Error saving settings: $e';
      });
    }
  }

  Widget _buildNumberField({
    required TextEditingController controller,
    required bool isFloat,
    required VoidCallback onChanged,
  }) {
    return SizedBox(
      width: 88,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.numberWithOptions(
          decimal: isFloat,
          signed: true,
        ),
        inputFormatters: isFloat
            ? [
                FilteringTextInputFormatter.allow(
                  RegExp(r'^-?\d*\.?\d*'),
                ),
              ]
            : [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))],
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          border: OutlineInputBorder(),
        ),
        onChanged: (_) => onChanged(),
      ),
    );
  }

  Widget _buildStartingTable() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 44,
        dataRowMinHeight: 52,
        dataRowMaxHeight: 64,
        columns: const [
          DataColumn(label: Text('Teams')),
          DataColumn(label: Text('MaxPlayers')),
          DataColumn(label: Text('PlayPlayers')),
          DataColumn(label: Text('StartPoints')),
          DataColumn(label: Text('Total')),
        ],
        rows: _rows.map((row) {
          final total = row.computeTotal();
          return DataRow(
            cells: [
              DataCell(
                SizedBox(
                  width: 140,
                  child: Text(
                    row.teamName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              DataCell(
                _buildNumberField(
                  controller: row.maxPlayersController,
                  isFloat: false,
                  onChanged: () => setState(() {}),
                ),
              ),
              DataCell(
                _buildNumberField(
                  controller: row.playPlayersController,
                  isFloat: false,
                  onChanged: () => setState(() {}),
                ),
              ),
              DataCell(
                _buildNumberField(
                  controller: row.startPointsController,
                  isFloat: true,
                  onChanged: () => setState(() {}),
                ),
              ),
              DataCell(
                Text(
                  total % 1 == 0 ? '${total.toInt()}' : total.toStringAsFixed(1),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.95,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.settings, color: Colors.blue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Game Settings',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.gameName,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Starting',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'MaxPlayers ≥ PlayPlayers → Total = StartPoints; '
                            'otherwise Total = MaxPlayers − PlayPlayers + StartPoints.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_rows.isEmpty)
                            const Text('No teams assigned to this active game.')
                          else
                            _buildStartingTable(),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _errorMessage!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isSaving || _isLoading || _rows.isEmpty
                        ? null
                        : _saveSettings,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isSaving ? 'Saving...' : 'Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
