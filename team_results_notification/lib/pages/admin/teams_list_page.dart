import 'package:flutter/material.dart';
import '../login_page.dart'; // For DatabaseService

class TeamsListPage extends StatefulWidget {
  const TeamsListPage({super.key});

  @override
  State<TeamsListPage> createState() => _TeamsListPageState();
}

class _TeamsListPageState extends State<TeamsListPage> {
  List<Map<String, dynamic>> _teams = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTeams();
  }

  Future<void> _loadTeams() async {
    try {
      final teams = await DatabaseService.getAllTeams();
      setState(() {
        _teams = teams;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading teams: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  int _getMemberCount(Map<String, dynamic> team) {
    if (team['team_members_ids'] == null || team['team_members_ids'].toString().isEmpty) {
      return 0;
    }
    final memberIds = team['team_members_ids'].toString().split(',');
    return memberIds.where((id) => id.trim().isNotEmpty).length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Teams'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _loadTeams,
            icon: const Icon(Icons.refresh),
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
                const Text(
                  'Teams List',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${_teams.length} teams',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Teams List
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _teams.isEmpty
                      ? const Center(
                          child: Text(
                            'No teams found',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _teams.length,
                          itemBuilder: (context, index) {
                            final team = _teams[index];
                            final memberCount = _getMemberCount(team);
                            
                            return Card(
                              elevation: 2,
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.blue.shade100,
                                  child: Text(
                                    team['team_code'] ?? 'T',
                                    style: TextStyle(
                                      color: Colors.blue.shade700,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  team['team_name'] ?? 'Unknown Team',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('City: ${team['team_city'] ?? 'Unknown'}'),
                                    if (team['team_captain'] != null)
                                      FutureBuilder<String>(
                                        future: _getCaptainName(team['team_captain']),
                                        builder: (context, snapshot) {
                                          if (snapshot.connectionState == ConnectionState.waiting) {
                                            return Text(
                                              'Captain: Loading...',
                                              style: TextStyle(
                                                color: Colors.orange.shade700,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            );
                                          }
                                          return Text(
                                            'Captain: ${snapshot.data ?? 'Unknown'}',
                                            style: TextStyle(
                                              color: Colors.orange.shade700,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          );
                                        },
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade100,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '$memberCount members',
                                        style: TextStyle(
                                          color: Colors.green.shade700,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    PopupMenuButton<String>(
                                      icon: const Icon(Icons.more_vert),
                                      itemBuilder: (context) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Row(
                                            children: [
                                              Icon(Icons.edit, size: 18),
                                              SizedBox(width: 8),
                                              Text('Edit'),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'members',
                                          child: Row(
                                            children: [
                                              Icon(Icons.people, size: 18),
                                              SizedBox(width: 8),
                                              Text('View Members'),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Row(
                                            children: [
                                              Icon(Icons.delete, size: 18, color: Colors.red),
                                              SizedBox(width: 8),
                                              Text('Delete', style: TextStyle(color: Colors.red)),
                                            ],
                                          ),
                                        ),
                                      ],
                                      onSelected: (value) {
                                        _handleTeamAction(value, team);
                                      },
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

  void _handleTeamAction(String action, Map<String, dynamic> team) {
    switch (action) {
      case 'edit':
        _editTeam(team);
        break;
      case 'members':
        _viewMembers(team);
        break;
      case 'delete':
        _deleteTeam(team);
        break;
    }
  }

  Future<String> _getCaptainName(int captainId) async {
    try {
      final users = await DatabaseService.getAllUsers();
      final captain = users.firstWhere(
        (user) => user['id'] == captainId,
        orElse: () => {'name': 'Unknown'},
      );
      return captain['name'] ?? 'Unknown';
    } catch (e) {
      return 'Unknown';
    }
  }

  void _editTeam(Map<String, dynamic> team) {
    showDialog(
      context: context,
      builder: (context) => EditTeamDialog(
        team: team,
        onTeamUpdated: () {
          _loadTeams(); // Refresh teams list
        },
      ),
    );
  }

  void _viewMembers(Map<String, dynamic> team) {
    showDialog(
      context: context,
      builder: (context) => ViewMembersDialog(
        team: team,
      ),
    );
  }

  void _deleteTeam(Map<String, dynamic> team) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Team'),
        content: Text('Are you sure you want to delete "${team['team_name']}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Delete functionality for ${team['team_name']} will be implemented here.'),
                  backgroundColor: Colors.orange,
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class EditTeamDialog extends StatefulWidget {
  final Map<String, dynamic> team;
  final VoidCallback? onTeamUpdated;

  const EditTeamDialog({
    super.key,
    required this.team,
    this.onTeamUpdated,
  });

  @override
  State<EditTeamDialog> createState() => _EditTeamDialogState();
}

class _EditTeamDialogState extends State<EditTeamDialog> {
  final _formKey = GlobalKey<FormState>();
  final _teamNameController = TextEditingController();
  final _cityController = TextEditingController();
  
  bool _isLoading = false;
  String? _errorMessage;
  List<Map<String, dynamic>> _availableMembers = [];
  int? _selectedCaptainId;

  @override
  void initState() {
    super.initState();
    _teamNameController.text = widget.team['team_name'] ?? '';
    _cityController.text = widget.team['team_city'] ?? '';
    _selectedCaptainId = widget.team['team_captain'];
    _loadAvailableMembers();
  }

  @override
  void dispose() {
    _teamNameController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  Future<void> _loadAvailableMembers() async {
    try {
      final result = await DatabaseService.getTeamMembers(widget.team['id']);
      if (result['success'] == true) {
        setState(() {
          _availableMembers = List<Map<String, dynamic>>.from(result['members'] ?? []);
        });
      }
    } catch (e) {
      print('Error loading team members: $e');
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
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    const Icon(Icons.edit, color: Colors.blue, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Edit Team: ${widget.team['team_name']}',
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

                // Team Name Field
                TextFormField(
                  controller: _teamNameController,
                  decoration: const InputDecoration(
                    labelText: 'Team Name',
                    prefixIcon: Icon(Icons.group),
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Team name is required';
                    }
                    if (value.trim().length < 2) {
                      return 'Team name must be at least 2 characters';
                    }
                    return null;
                  },
                  onChanged: (_) => _clearError(),
                ),
                const SizedBox(height: 16),

                // City Field
                TextFormField(
                  controller: _cityController,
                  decoration: const InputDecoration(
                    labelText: 'City',
                    prefixIcon: Icon(Icons.location_city),
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'City is required';
                    }
                    if (value.trim().length < 2) {
                      return 'City must be at least 2 characters';
                    }
                    return null;
                  },
                  onChanged: (_) => _clearError(),
                ),
                const SizedBox(height: 16),

                // Captain Selection
                if (_availableMembers.isNotEmpty) ...[
                  const Text(
                    'Team Captain',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _selectedCaptainId,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: _availableMembers.map((member) {
                      return DropdownMenuItem<int>(
                        value: member['id'],
                        child: Text('${member['name']} (${member['email']})'),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedCaptainId = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                ],

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
                      onPressed: _isLoading ? null : _updateTeam,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
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
                          : const Text('Update Team'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _clearError() {
    if (_errorMessage != null) {
      setState(() {
        _errorMessage = null;
      });
    }
  }

  Future<void> _updateTeam() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final teamData = {
        'team_name': _teamNameController.text.trim(),
        'team_city': _cityController.text.trim(),
        if (_selectedCaptainId != null) 'team_captain': _selectedCaptainId,
      };

      final result = await DatabaseService.updateTeam(widget.team['id'], teamData);

      if (result['success'] == true) {
        if (mounted) {
          Navigator.pop(context);
          if (widget.onTeamUpdated != null) {
            widget.onTeamUpdated!();
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Team "${_teamNameController.text.trim()}" updated successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = result['message'] ?? 'Failed to update team';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Connection error: $e';
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

class ViewMembersDialog extends StatefulWidget {
  final Map<String, dynamic> team;

  const ViewMembersDialog({
    super.key,
    required this.team,
  });

  @override
  State<ViewMembersDialog> createState() => _ViewMembersDialogState();
}

class _ViewMembersDialogState extends State<ViewMembersDialog> {
  List<Map<String, dynamic>> _members = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final result = await DatabaseService.getTeamMembers(widget.team['id']);
      if (result['success'] == true) {
        setState(() {
          _members = List<Map<String, dynamic>>.from(result['members'] ?? []);
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = result['message'] ?? 'Failed to load members';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Connection error: $e';
        _isLoading = false;
      });
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
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.people, color: Colors.blue, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Team Members: ${widget.team['team_name']}',
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

            // Content
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
              )
            else if (_members.isEmpty)
              const Center(
                child: Text(
                  'No members found',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _members.length,
                  itemBuilder: (context, index) {
                    final member = _members[index];
                    return Card(
                      elevation: 2,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: member['is_captain'] 
                              ? Colors.orange.shade100 
                              : Colors.blue.shade100,
                          child: Icon(
                            member['is_captain'] ? Icons.star : Icons.person,
                            color: member['is_captain'] 
                                ? Colors.orange.shade700 
                                : Colors.blue.shade700,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              member['name'] ?? 'Unknown',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            if (member['is_captain']) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'CAPTAIN',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('ID: ${member['id']}'),
                            Text('Email: ${member['email'] ?? 'N/A'}'),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

            // Close Button
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
