import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../login_page.dart'; // For DatabaseService

class GameManagementPage extends StatefulWidget {
  const GameManagementPage({super.key});

  @override
  State<GameManagementPage> createState() => _GameManagementPageState();
}

class _GameManagementPageState extends State<GameManagementPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Management'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            const Text(
              'Manage Games',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create, monitor, and control active games and rounds',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 24),
            
            // Quick Actions
            Row(
              children: [
                Expanded(
                  child: _buildActionCard(
                    'Load New Game',
                    Icons.upload_file,
                    Colors.orange,
                    () {
                      _showLoadGameDialog();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildActionCard(
                    'Active Games',
                    Icons.sports_esports,
                    Colors.blue,
                    () {
                      _showActiveGames();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Game Statistics
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Game Statistics',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatCard('Active Games', '3', Colors.green),
                        _buildStatCard('Total Rounds', '45', Colors.blue),
                        _buildStatCard('Completed', '12', Colors.orange),
                        _buildStatCard('Players Online', '28', Colors.purple),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Current Round Control
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Current Round Control',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Round 3 of 10'),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: 0.3,
                                backgroundColor: Colors.grey[300],
                                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton(
                          onPressed: () => _nextRound(),
                          child: const Text('Next Round'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pauseGame(),
                            icon: const Icon(Icons.pause),
                            label: const Text('Pause Game'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _endGame(),
                            icon: const Icon(Icons.stop),
                            label: const Text('End Game'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Active Games List
            const Text(
              'Active Games',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: 3, // Mock data
                itemBuilder: (context, index) {
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.green.shade100,
                        child: const Icon(Icons.sports_esports, color: Colors.green),
                      ),
                      title: Text('Game ${index + 1}'),
                      subtitle: Text('Round ${(index + 1) * 2} of 10 - 8 players'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.visibility),
                            onPressed: () => _viewGame(index),
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings),
                            onPressed: () => _gameSettings(index),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard(String title, IconData icon, Color color, VoidCallback onTap) {
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

  Widget _buildStatCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  void _showStartGameDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start New Game'),
        content: const Text('Game creation functionality will be implemented here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showLoadGameDialog() {
    showDialog(
      context: context,
      builder: (context) => LoadGameDialog(
        onGameLoaded: () {
          // Refresh games list or show success message
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Game loaded successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        },
      ),
    );
  }

  void _showActiveGames() {
    Navigator.pushNamed(context, '/admin/active-games');
  }

  void _nextRound() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Moving to next round...')),
    );
  }

  void _pauseGame() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Game paused')),
    );
  }

  void _endGame() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End Game'),
        content: const Text('Are you sure you want to end this game?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Game ended')),
              );
            },
            child: const Text('End Game'),
          ),
        ],
      ),
    );
  }

  void _viewGame(int gameIndex) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Viewing Game ${gameIndex + 1}')),
    );
  }

  void _gameSettings(int gameIndex) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Game ${gameIndex + 1} settings')),
    );
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
  String? _selectedFilePath;
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
              // Header
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

              // Instructions
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

              // Error Message
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

              // File Selection
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

              // Action Buttons
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

        // Handle different platforms
        if (file.bytes != null) {
          // Web platform - use bytes directly
          setState(() {
            _selectedFileBytes = file.bytes!;
            _selectedFilePath = 'web_file'; // Placeholder for UI state
          });
        } else if (file.path != null) {
          // Mobile/Desktop platform - read file from path
          final fileObj = File(file.path!);
          final bytes = await fileObj.readAsBytes();
          setState(() {
            _selectedFilePath = file.path!;
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
      // Extract game name from filename (remove extension)
      final gameName = _fileName!.replaceAll(RegExp(r'\.(xlsx|xls)$'), '');
      
      // Call API to process the Excel file
      final result = await DatabaseService.loadGameFromExcel(
        gameName,
        _selectedFileBytes!,
      );

      if (result['success'] == true) {
        if (mounted) {
          Navigator.pop(context);
          if (widget.onGameLoaded != null) {
            widget.onGameLoaded!();
          }
          
          // Show detailed success message
          final responseData = result['data'];
          
          String successMessage = 'Excel file processed successfully!\n';
          successMessage += '• File: $gameName\n';
          
          // Try to get detailed information from the response
          if (responseData != null) {
            final totalSheets = responseData['total_sheets'] ?? 0;
            final totalRows = responseData['total_rows'] ?? 0;
            final createdGames = responseData['created_games'] as List? ?? [];
            final filename = responseData['filename'] ?? gameName;
            
            successMessage += '• Games created: $totalSheets\n';
            successMessage += '• Total rows imported: $totalRows\n';
            successMessage += '• Each sheet became a separate game';
            
            // Add details about created games if available
            if (createdGames.isNotEmpty) {
              successMessage += '\n\nCreated games:';
              for (var game in createdGames.take(3)) { // Show first 3 games
                final gameName = game['game_name'] ?? 'Unknown';
                final rowCount = game['row_count'] ?? 0;
                successMessage += '\n• $gameName ($rowCount rows)';
              }
              if (createdGames.length > 3) {
                successMessage += '\n• ... and ${createdGames.length - 3} more';
              }
            }
          } else {
            // Fallback message if detailed data is not available
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
