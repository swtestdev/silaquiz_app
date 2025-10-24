import 'package:flutter/material.dart';
import '../pages/login_page.dart';
import '../services/user_data_service.dart';

class UserProfileDialog extends StatefulWidget {
  final Map<String, dynamic> userData;
  final VoidCallback? onProfileUpdated;

  const UserProfileDialog({
    super.key,
    required this.userData,
    this.onProfileUpdated,
  });

  @override
  State<UserProfileDialog> createState() => _UserProfileDialogState();
}

class _UserProfileDialogState extends State<UserProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _teamIdController = TextEditingController();
  
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeFields();
  }

  void _initializeFields() {
    _nameController.text = widget.userData['name'] ?? '';
    _emailController.text = widget.userData['email'] ?? '';
    _teamIdController.text = widget.userData['playing_in_team_id'] ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _teamIdController.dispose();
    super.dispose();
  }

  Future<void> _updateProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Prepare profile data for API call
      final profileData = <String, dynamic>{};
      
      // Only include fields that have changed
      if (_nameController.text.trim() != (widget.userData['name'] ?? '')) {
        profileData['name'] = _nameController.text.trim();
      }
      
      if (_emailController.text.trim() != (widget.userData['email'] ?? '')) {
        profileData['email'] = _emailController.text.trim();
      }
      
      if (_passwordController.text.isNotEmpty) {
        profileData['password'] = _passwordController.text;
      }
      
      if (widget.userData['role'] == 'player') {
        final currentTeamId = widget.userData['playing_in_team_id'] ?? '';
        final newTeamId = _teamIdController.text.trim();
        
        if (newTeamId != currentTeamId) {
          profileData['playing_in_team_id'] = newTeamId.isEmpty ? null : newTeamId;
        }
      }

      // Check if there are any changes
      if (profileData.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No changes detected'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Call API to update profile
      final result = await DatabaseService.updateUserProfile(
        widget.userData['id'].toString(),
        profileData,
      );

      if (result['success'] == true) {
        // Get current user data to preserve tokens and other fields
        final currentUserData = await UserDataService.getUserData();
        final updatedUserData = result['user'];
        
        // Merge updated data with current data to preserve tokens
        final mergedUserData = <String, dynamic>{
          ...currentUserData ?? {},
          ...updatedUserData,
        };
        
        await UserDataService.saveUserData(mergedUserData);

        // If team ID changed and user is a player, fetch new team name
        if (widget.userData['role'] == 'player' && 
            profileData.containsKey('playing_in_team_id')) {
          await UserDataService.clearTeamName();
          if (updatedUserData['playing_in_team_id'] != null && 
              updatedUserData['playing_in_team_id'].toString().isNotEmpty) {
            final teamResult = await DatabaseService.getTeamName(updatedUserData['playing_in_team_id'].toString());
            if (teamResult['success'] == true) {
              await UserDataService.saveTeamName(teamResult['team_name']);
            }
          }
        }

        if (mounted) {
          Navigator.of(context).pop();
          if (widget.onProfileUpdated != null) {
            widget.onProfileUpdated!();
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['message'] ?? 'Profile updated successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = result['message'] ?? 'Failed to update profile';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error updating profile: $e';
        });
      }
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
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
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
              Row(
                children: [
                  const Icon(Icons.edit, color: Colors.blue),
                  const SizedBox(width: 8),
                  const Text(
                    'Update Profile',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              
              // Error Message
              if (_errorMessage != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: Colors.red.shade600, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          setState(() {
                            _errorMessage = null;
                          });
                        },
                        icon: Icon(Icons.close, color: Colors.red.shade600, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              
              // Name Field
              TextFormField(
                controller: _nameController,
                onChanged: (_) {
                  if (_errorMessage != null) {
                    setState(() {
                      _errorMessage = null;
                    });
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person),
                  border: OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.white,
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Email Field
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email),
                  border: OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.white,
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Email is required';
                  }
                  if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Password Field
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password (leave empty to keep current)',
                  prefixIcon: const Icon(Icons.lock),
                  filled: true,
                  fillColor: Colors.white,
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                    icon: Icon(
                      _obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value != null && value.isNotEmpty && value.length < 6) {
                    return 'Password must be at least 6 characters';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Team ID Field (only for players)
              if (widget.userData['role'] == 'player') ...[
                TextFormField(
                  controller: _teamIdController,
                  onChanged: (_) {
                    if (_errorMessage != null) {
                      setState(() {
                        _errorMessage = null;
                      });
                    }
                  },
                  decoration: const InputDecoration(
                    labelText: 'Team ID',
                    prefixIcon: Icon(Icons.group),
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white,
                    helperText: 'Enter your team code to join a team',
                  ),
                ),
                const SizedBox(height: 20),
              ] else
                const SizedBox(height: 4),
              
              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _updateProfile,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Update'),
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
}
