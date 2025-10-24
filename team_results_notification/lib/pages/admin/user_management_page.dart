import 'package:flutter/material.dart';
import '../login_page.dart'; // For DatabaseService

class UserManagementPage extends StatefulWidget {
  const UserManagementPage({super.key});

  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage> {
  String _selectedFilter = 'All';
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _teams = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadTeams();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final users = await DatabaseService.getAllUsers();
      setState(() {
        _users = users;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading users: $e');
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading users: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _loadTeams() async {
    try {
      final teams = await DatabaseService.getAllTeams();
      setState(() {
        _teams = teams;
      });
    } catch (e) {
      print('Error loading teams: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading teams: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  List<Map<String, dynamic>> get _filteredUsers {
    List<Map<String, dynamic>> filtered = _users;
    
    // Apply filter
    switch (_selectedFilter) {
      case 'Deactivated':
        filtered = filtered.where((user) => !user['is_active']).toList();
        break;
      case 'Team Captains':
        filtered = filtered.where((user) => user['is_captain'] == true).toList();
        break;
      case 'Players':
        filtered = filtered.where((user) => user['role'] == 'player').toList();
        break;
      case 'Admins':
        filtered = filtered.where((user) => user['role'] == 'admin').toList();
        break;
    }
    
    // Apply search query
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((user) {
        final name = user['name']?.toString().toLowerCase() ?? '';
        final email = user['email']?.toString().toLowerCase() ?? '';
        final teamName = user['team_name']?.toString().toLowerCase() ?? '';
        final query = _searchQuery.toLowerCase();
        
        return name.contains(query) || 
               email.contains(query) || 
               teamName.contains(query);
      }).toList();
    }
    
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management'),
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
              'Manage Users',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'View, edit, and manage user accounts and roles',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            
            // User Statistics
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatCard('Total', '${_users.length}', Colors.blue),
                        _buildStatCard('Players', '${_users.where((u) => u['role'] == 'player').length}', Colors.green),
                        _buildStatCard('Admins', '${_users.where((u) => u['role'] == 'admin').length}', Colors.orange),
                        _buildStatCard('Active', '${_users.where((u) => u['is_active'] == true).length}', Colors.purple),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Search and Filter
            Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                    decoration: InputDecoration(
                      hintText: 'Search by name, email, or team...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedFilter,
                  items: const [
                    DropdownMenuItem(value: 'All', child: Text('All Users')),
                    DropdownMenuItem(value: 'Players', child: Text('Players')),
                    DropdownMenuItem(value: 'Admins', child: Text('Admins')),
                    DropdownMenuItem(value: 'Team Captains', child: Text('Team Captains')),
                    DropdownMenuItem(value: 'Deactivated', child: Text('Deactivated')),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedFilter = value!;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Users List
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Users List (${_filteredUsers.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: _loadUsers,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredUsers.isEmpty
                      ? const Center(
                          child: Text(
                            'No users found',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredUsers.length,
                          itemBuilder: (context, index) {
                            final user = _filteredUsers[index];
                            final isAdmin = user['role'] == 'admin';
                            final isCaptain = user['is_captain'] == true;
                            final isActive = user['is_active'] == true;
                            
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isAdmin 
                                      ? Colors.red.shade100 
                                      : isCaptain 
                                          ? Colors.orange.shade100 
                                          : Colors.blue.shade100,
                                  child: Icon(
                                    isAdmin 
                                        ? Icons.admin_panel_settings 
                                        : isCaptain 
                                            ? Icons.star 
                                            : Icons.person,
                                    color: isAdmin 
                                        ? Colors.red 
                                        : isCaptain 
                                            ? Colors.orange 
                                            : Colors.blue,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Text(user['name']),
                                    if (!isActive) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.red.shade100,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'INACTIVE',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.red,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(user['email']),
                                    if (isCaptain && user['team_name'] != null)
                                      Text(
                                        'Captain of ${user['team_name']}',
                                        style: TextStyle(
                                          color: Colors.orange.shade700,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      onPressed: () => _editUser(user),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.more_vert),
                                      onPressed: () => _showUserMenu(user),
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
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(height: 6),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: color,
            ),
          ),
        ],
      ),
    );
  }


  void _editUser(Map<String, dynamic> user) {
    showDialog(
      context: context,
      builder: (context) => UserEditDialog(
        user: user,
        teams: _teams,
        onUserUpdated: (updatedUser) {
          print('Received updated user data: $updatedUser');
          setState(() {
            final index = _users.indexWhere((u) => u['id'] == updatedUser['id']);
            if (index != -1) {
              print('Updating user at index $index');
              _users[index] = updatedUser;
            } else {
              print('User not found in list for update');
            }
          });
        },
      ),
    );
  }

  void _showUserMenu(Map<String, dynamic> user) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Edit User'),
            onTap: () {
              Navigator.pop(context);
              _editUser(user);
            },
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Change Role'),
            onTap: () {
              Navigator.pop(context);
              _showRoleChangeDialog(user);
            },
          ),
          ListTile(
            leading: Icon(user['is_active'] ? Icons.block : Icons.check_circle),
            title: Text(user['is_active'] ? 'Deactivate' : 'Activate'),
            onTap: () {
              Navigator.pop(context);
              _toggleUserStatus(user);
            },
          ),
        ],
      ),
    );
  }

  void _showRoleChangeDialog(Map<String, dynamic> user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change User Role'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Are you sure you want to change the role of "${user['name']}"?'),
            const SizedBox(height: 16),
            Text(
              'This action will change the user\'s permissions and access level.',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _confirmRoleChange(user);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _confirmRoleChange(Map<String, dynamic> user) {
    String newRole = user['role'] == 'admin' ? 'player' : 'admin';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Final Confirmation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('This is your final confirmation to change "${user['name']}" role.'),
            const SizedBox(height: 16),
            Text(
              'Current role: ${user['role']}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: newRole,
              decoration: const InputDecoration(
                labelText: 'New Role',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'player', child: Text('Player')),
                DropdownMenuItem(value: 'admin', child: Text('Admin')),
              ],
              onChanged: (value) {
                newRole = value!;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performRoleChange(user, newRole);
            },
            child: const Text('Confirm Change'),
          ),
        ],
      ),
    );
  }

  Future<void> _performRoleChange(Map<String, dynamic> user, String newRole) async {
    try {
      final result = await DatabaseService.updateUserAdmin(user['id'], {'role': newRole});
      
      if (result['success'] == true) {
        setState(() {
          user['role'] = newRole;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Role changed to $newRole for ${user['name']}'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'Failed to change role'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _toggleUserStatus(Map<String, dynamic> user) {
    final newStatus = !user['is_active'];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(newStatus ? 'Activate User' : 'Deactivate User'),
        content: Text(
          'Are you sure you want to ${newStatus ? 'activate' : 'deactivate'} "${user['name']}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _performStatusChange(user, newStatus);
            },
            child: Text(newStatus ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );
  }

  Future<void> _performStatusChange(Map<String, dynamic> user, bool newStatus) async {
    try {
      final result = await DatabaseService.updateUserAdmin(user['id'], {'is_active': newStatus});
      
      if (result['success'] == true) {
        setState(() {
          user['is_active'] = newStatus;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('User ${newStatus ? 'activated' : 'deactivated'}'),
            backgroundColor: newStatus ? Colors.green : Colors.orange,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'Failed to change status'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class UserEditDialog extends StatefulWidget {
  final Map<String, dynamic> user;
  final List<Map<String, dynamic>> teams;
  final Function(Map<String, dynamic>) onUserUpdated;

  const UserEditDialog({
    super.key,
    required this.user,
    required this.teams,
    required this.onUserUpdated,
  });

  @override
  State<UserEditDialog> createState() => _UserEditDialogState();
}

class _UserEditDialogState extends State<UserEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _passwordController;
  late String _selectedRole;
  late bool _isActive;
  late String? _selectedTeamId;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user['name']);
    _emailController = TextEditingController(text: widget.user['email']);
    _passwordController = TextEditingController();
    _selectedRole = widget.user['role'] ?? 'player';
    _isActive = widget.user['is_active'] ?? true;
    
    // Find the team ID based on playing_in_team_id (team code)
    final playingInTeamId = widget.user['playing_in_team_id'];
    if (playingInTeamId != null && playingInTeamId.toString().isNotEmpty) {
      // Try to find team by team_code first
      var team = widget.teams.firstWhere(
        (t) => t['team_code'] == playingInTeamId,
        orElse: () => <String, dynamic>{},
      );
      
      // If not found by team_code, try by team_id (in case playing_in_team_id contains team ID)
      if (team.isEmpty) {
        try {
          final teamIdInt = int.parse(playingInTeamId.toString());
          team = widget.teams.firstWhere(
            (t) => t['id'] == teamIdInt,
            orElse: () => <String, dynamic>{},
          );
        } catch (e) {
          // If parsing fails, team remains empty
        }
      }
      
      _selectedTeamId = team.isNotEmpty ? team['id'].toString() : null;
    } else {
      _selectedTeamId = null;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
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
                        'Edit User: ${widget.user['name']}',
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

                // Name Field
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  onChanged: (_) => _clearError(),
                ),
                const SizedBox(height: 16),

                // Email Field
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  keyboardType: TextInputType.emailAddress,
                  onChanged: (_) => _clearError(),
                ),
                const SizedBox(height: 16),

                // Password Field
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'New Password (leave empty to keep current)',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  obscureText: true,
                  onChanged: (_) => _clearError(),
                ),
                const SizedBox(height: 16),

                // Role Selection
                DropdownButtonFormField<String>(
                  value: _selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'player', child: Text('Player')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedRole = value!;
                    });
                  },
                ),
                const SizedBox(height: 16),

                // Team Selection (only for players)
                if (_selectedRole == 'player') ...[
                  DropdownButtonFormField<String?>(
                    value: _selectedTeamId,
                    decoration: const InputDecoration(
                      labelText: 'Team',
                      border: OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('No Team'),
                      ),
                      ...widget.teams.map((team) => DropdownMenuItem<String?>(
                        value: team['id'].toString(),
                        child: Text('${team['team_name']} (${team['team_code']})'),
                      )),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedTeamId = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                ],

                // Active Status
                SwitchListTile(
                  title: const Text('Active User'),
                  subtitle: const Text('User can log in and use the system'),
                  value: _isActive,
                  onChanged: (value) {
                    setState(() {
                      _isActive = value;
                    });
                  },
                ),
                const SizedBox(height: 24),

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
                      onPressed: _saveUser,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Save Changes'),
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

  Future<void> _saveUser() async {
    // Validation
    if (_nameController.text.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Name is required';
      });
      return;
    }

    if (_emailController.text.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Email is required';
      });
      return;
    }

    // Show loading
    setState(() {
      _errorMessage = null;
    });

    // Create updated user data for API
    final userData = <String, dynamic>{};
    
    if (_nameController.text.trim() != widget.user['name']) {
      userData['name'] = _nameController.text.trim();
    }
    
    if (_emailController.text.trim() != widget.user['email']) {
      userData['email'] = _emailController.text.trim();
    }
    
    if (_selectedRole != widget.user['role']) {
      userData['role'] = _selectedRole;
    }
    
    if (_isActive != widget.user['is_active']) {
      userData['is_active'] = _isActive;
    }
    
    if (_passwordController.text.isNotEmpty) {
      userData['password'] = _passwordController.text;
    }
    
    if (_selectedRole == 'player') {
      final currentTeamId = widget.user['playing_in_team_id'];
      final newTeamId = _selectedTeamId != null 
          ? widget.teams.firstWhere((t) => t['id'].toString() == _selectedTeamId)['team_code']
          : null;
      
      // Always update team assignment for players, even if setting to "No Team"
      if (currentTeamId != newTeamId) {
        userData['playing_in_team_id'] = newTeamId ?? '';
        print('Updating team assignment: $currentTeamId -> ${newTeamId ?? "No Team"}');
      }
    }

    // Only make API call if there are changes
    if (userData.isNotEmpty) {
      print('Sending user update data: $userData');
      try {
        final result = await DatabaseService.updateUserAdmin(widget.user['id'], userData);
        
        if (result['success'] == true) {
          // Create updated user data for UI
          final updatedUser = Map<String, dynamic>.from(widget.user);
          updatedUser['name'] = _nameController.text.trim();
          updatedUser['email'] = _emailController.text.trim();
          updatedUser['role'] = _selectedRole;
          updatedUser['is_active'] = _isActive;
          
          if (_selectedRole == 'player') {
            // Update team information
            final newTeamId = _selectedTeamId != null 
                ? widget.teams.firstWhere((t) => t['id'].toString() == _selectedTeamId)['team_code']
                : null;
            
            updatedUser['playing_in_team_id'] = newTeamId;
            updatedUser['team_id'] = _selectedTeamId != null ? int.parse(_selectedTeamId!) : null;
            updatedUser['team_name'] = _selectedTeamId != null 
                ? widget.teams.firstWhere((t) => t['id'].toString() == _selectedTeamId)['team_name']
                : null;
            
            // Update captain status - user is captain if they're the only member or if they were already captain
            final teamMembers = _selectedTeamId != null 
                ? widget.teams.firstWhere((t) => t['id'].toString() == _selectedTeamId)['team_members_ids']
                : null;
            if (teamMembers != null && teamMembers.toString().isNotEmpty) {
              final memberIds = teamMembers.toString().split(',');
              final memberCount = memberIds.where((id) => id.trim().isNotEmpty).length;
              updatedUser['is_captain'] = memberCount == 1 || updatedUser['is_captain'] == true;
            } else {
              updatedUser['is_captain'] = false;
            }
          } else {
            // For non-players, clear team information
            updatedUser['playing_in_team_id'] = null;
            updatedUser['team_id'] = null;
            updatedUser['team_name'] = null;
            updatedUser['is_captain'] = false;
          }

          // Call the callback
          print('Updating UI with user data: $updatedUser');
          widget.onUserUpdated(updatedUser);
          
          // Show success message
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['message'] ?? 'User updated successfully'),
              backgroundColor: Colors.green,
            ),
          );
          
          Navigator.pop(context);
        } else {
          setState(() {
            _errorMessage = result['message'] ?? 'Failed to update user';
          });
        }
      } catch (e) {
        setState(() {
          _errorMessage = 'Connection error: $e';
        });
      }
    } else {
      // No changes made
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No changes made'),
          backgroundColor: Colors.orange,
        ),
      );
      Navigator.pop(context);
    }
  }
}
