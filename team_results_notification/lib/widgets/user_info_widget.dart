import 'dart:async';
import 'package:flutter/material.dart';
import '../services/user_data_service.dart';
import '../pages/login_page.dart';
import 'user_profile_dialog.dart';

class UserInfoWidget extends StatefulWidget {
  final VoidCallback? onProfileUpdated;
  
  const UserInfoWidget({
    super.key,
    this.onProfileUpdated,
  });

  @override
  State<UserInfoWidget> createState() => _UserInfoWidgetState();
}

class _UserInfoWidgetState extends State<UserInfoWidget> {
  Map<String, dynamic>? userData;
  bool isLoading = true;
  String? teamName;
  String? teamCode;
  bool isTeamNameLoading = false;
  DateTime? loginTime;
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _startSessionTimer();
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    try {
      final data = await UserDataService.getUserData();
      final storedTeamName = await UserDataService.getTeamName();
      final loginTimeData = await UserDataService.getLoginTime();
      
      setState(() {
        userData = data;
        teamName = storedTeamName;
        loginTime = loginTimeData;
        isLoading = false;
      });

      // If user has no team assigned in backend but has stored team name locally, clear it
      if (data != null && data['playing_in_team_id'] == null && storedTeamName != null) {
        await UserDataService.clearTeamName();
        setState(() {
          teamName = null;
        });
      }
      // If no team name stored locally and user is a player, try to fetch from API
      else if (storedTeamName == null && data != null && data['role'] == 'player' && data['playing_in_team_id'] != null) {
        await _fetchTeamNameFromAPI(data['playing_in_team_id']);
      }
      
      // If user is a captain, also fetch team code
      if (data != null && data['is_captain'] == true && data['playing_in_team_id'] != null) {
        await _fetchTeamCodeFromAPI(data['playing_in_team_id']);
      }
    } catch (e) {
      setState(() {
        isLoading = false;
      });
    }
  }

  void _startSessionTimer() {
    _sessionTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        setState(() {
          // This will trigger a rebuild and recalculate session duration
        });
      }
    });
  }

  int _getSessionDuration() {
    if (loginTime == null) return 0;
    return DateTime.now().difference(loginTime!).inMinutes;
  }

  Future<void> _fetchTeamNameFromAPI(String teamIdentifier) async {
    if (teamIdentifier.isEmpty) return;
    
    setState(() {
      isTeamNameLoading = true;
    });

    try {
      // Try to determine if it's a team code (6 characters) or team ID (numeric)
      bool isNumeric = RegExp(r'^\d+$').hasMatch(teamIdentifier);
      
      final result = await DatabaseService.getTeamName(teamIdentifier);
      
      if (result['success'] == true) {
        final fetchedTeamName = result['team_name'];
        await UserDataService.saveTeamName(fetchedTeamName);
        setState(() {
          teamName = fetchedTeamName;
        });
      } else {
        setState(() {
          teamName = "No team";
        });
      }
    } catch (e) {
      setState(() {
        teamName = "No team";
      });
    } finally {
      setState(() {
        isTeamNameLoading = false;
      });
    }
  }

  Future<void> _fetchTeamCodeFromAPI(String teamIdentifier) async {
    if (teamIdentifier.isEmpty) return;

    try {
      final result = await DatabaseService.getTeamName(teamIdentifier);
      
      if (result['success'] == true) {
        final fetchedTeamCode = result['team_code'];
        setState(() {
          teamCode = fetchedTeamCode;
        });
      }
    } catch (e) {
      // If fetching fails, teamCode remains null
    }
  }

  void _onProfileIconTap() {
    if (userData != null) {
      showDialog(
        context: context,
        builder: (context) => UserProfileDialog(
          userData: userData!,
          onProfileUpdated: () {
            // Reload user data when profile is updated
            _loadUserData();
            // Also notify parent widget to update AppBar
            if (widget.onProfileUpdated != null) {
              widget.onProfileUpdated!();
            }
          },
        ),
      );
    }
  }



  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (userData == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('No user data available'),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        userData!['role'] == 'player' 
                            ? (isTeamNameLoading 
                                ? 'Loading team...' 
                                : (teamName ?? 'No team'))
                            : 'Analytic',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // Show team code for captains
                      if (userData!['role'] == 'player' && 
                          userData!['is_captain'] == true && 
                          teamCode != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Code: $teamCode',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _onProfileIconTap,
                  child: const Icon(Icons.settings, color: Colors.blue),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              'Session: ${_getSessionDuration()} min',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
