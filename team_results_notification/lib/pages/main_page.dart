import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:html' as html;
import '../widgets/user_info_widget.dart';
import '../services/user_data_service.dart';
import 'login_page.dart'; // For DatabaseService
import 'question_page.dart' as question_page; // For timer message forwarding and initializeTimerStatus

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  bool _isLoading = true;
  String _userName = 'User';
  String _userId = '';
  bool _hasShownTeamNotification = false;
  bool _hasTeam = false;
  String _userRole = 'player';
  bool _eligibleForActiveGame = false;
  bool _sessionValidationInProgress = false;
  bool _disconnectionHandlerRunning = false;
  Timer? _echoTimer;
  bool _isAppVisible = true;
  bool _hasShownNotification = false;
  
  // Writer status tracking
  bool _isWriter = false;
  String? _currentWriterName;
  String? _previousWriterName;
  
  // Visible connected status tracking
  int _visibleConnected = 0;
  
  // WebSocket state
  WebSocketChannel? _channel;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
    
    // Track app visibility changes
    WidgetsBinding.instance.addObserver(_AppLifecycleObserver(
      onResumed: () {
        _isAppVisible = true;
        print('App became visible - checking WebSocket connection');
        // Reconnect WebSocket if needed when app becomes visible
        if (_userRole == 'player') {
          _ensureWebSocketConnected();
        }
      },
      onPaused: () {
        _isAppVisible = false;
        print('App became hidden');
      },
    ));
    
    // Track browser tab visibility for web
    _setupBrowserVisibilityDetection();
  }

  Future<void> _checkLoginStatus() async {
    print('=== _checkLoginStatus START ===');
    final isLoggedIn = await UserDataService.isLoggedIn();
    print('isLoggedIn: $isLoggedIn');
    
    if (!isLoggedIn) {
      print('User not logged in, redirecting to login');
      Navigator.pushReplacementNamed(context, '/login');
    } else {
      print('User is logged in, loading user data');
      await _loadUserData();
    }
  }

  Future<void> _loadUserData() async {
    print('=== _loadUserData START ===');
    
    try {
      // Add overall timeout to prevent hanging
      await _loadUserDataWithTimeout();
    } catch (e) {
      print('Error in _loadUserData: $e');
      // Fallback: use local data and continue
      await _loadUserDataFallback();
    }
  }
  
  Future<void> _loadUserDataWithTimeout() async {
    await Future.any([
      _loadUserDataInternal(),
      Future.delayed(const Duration(seconds: 15), () {
        throw TimeoutException('_loadUserData timed out', const Duration(seconds: 15));
      }),
    ]);
  }
  
  Future<void> _loadUserDataInternal() async {
    // First try to load user data from local storage
    final localUserData = await UserDataService.getUserData();
    print('Local user data loaded: ${localUserData != null}');
    
    if (localUserData == null) {
      // No local data, redirect to login
      print('No local user data found, redirecting to login');
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }
    
    // For now, use local data directly to avoid session validation issues
    // TODO: Re-enable session validation once the race condition is fixed
    final userData = localUserData;
    print('Using local user data: $userData');
    print('User data keys: ${userData?.keys.toList()}');
    print('Writer status: ${userData?['writer']}');
    print('User name: ${userData?['name']}');
    print('User role: ${userData?['role']}');
    print('User ID: ${userData?['id']}');
    
    // Try to validate the session with the server (but don't fail if it doesn't work)
    if (!_sessionValidationInProgress) {
      print('Starting session validation...');
      _sessionValidationInProgress = true;
      try {
        // Add a small delay to avoid race conditions with database commits
        print('Waiting 1 second before session validation...');
        await Future.delayed(const Duration(milliseconds: 1000));
        
        print('Calling validateSession...');
        final sessionResult = await DatabaseService.validateSession().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            print('Session validation timed out, using local data');
            return {'success': false, 'message': 'Timeout'};
          },
        );
        print('Session validation result: ${sessionResult['success']}');
        if (sessionResult['success']) {
          print('Session validation successful, using fresh server data');
          // Use fresh user data from server
          final freshUserData = sessionResult['user'];
          print('Fresh user data: $freshUserData');
          setState(() {
            _userName = freshUserData?['name'] ?? 'User';
            _isWriter = freshUserData?['writer'] ?? false;
            _visibleConnected = freshUserData?['visible_connected'] ?? 0;
            _userId = freshUserData?['id']?.toString() ?? '';
            _userRole = freshUserData?['role'] ?? 'player';
          });
          print('State updated with fresh data - Name: $_userName, Role: $_userRole, ID: $_userId');
          _sessionValidationInProgress = false;
          print('Session validation complete, continuing with main page setup...');
          // Don't return here - continue with the rest of the method
        } else {
          print('Session validation failed, using local data: ${sessionResult['message']}');
          // Don't logout on initial session validation failure - this might be a race condition
          print('Using local data due to session validation failure - this is normal during initial load');
        }
      } catch (e) {
        print('Session validation error, using local data: $e');
      }
      _sessionValidationInProgress = false;
    }
    
    // Ensure we have user data before proceeding
    if (userData == null) {
      print('No user data available, redirecting to login');
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }
    
    // Initialize timer status to Idle (in case of refresh or re-login)
    await question_page.initializeTimerStatus();
    
    // Retrieve last timer setting from server and activate if needed
    try {
      final timerSettingResult = await DatabaseService.getLastTimerSetting();
      if (timerSettingResult['success'] == true && timerSettingResult['data'] != null) {
        final timerData = timerSettingResult['data'] as Map<String, dynamic>;
        // Convert to the format expected by _handleGlobalTimer
        final timerMessage = {
          'type': 'timer_trigger',
          'timer_action': timerData['timer_action'],
          'slide_number': timerData['slide_number'],
          'round_name': timerData['round_name'],
          'timer_start': timerData['timer_start'],
          'question_id': timerData['question_id'],
          'final_timer': timerData['final_timer'],
          'question_timer': timerData['question_timer']
        };
        // Activate the timer with the retrieved data
        question_page.forwardTimerMessage(timerMessage);
        print('MainPage: Retrieved and activated last timer setting from server');
      } else {
        print('MainPage: No timer setting available from server');
      }
    } catch (e) {
      print('MainPage: Error retrieving last timer setting: $e');
    }
    
    // Set loading to false to show the UI
    setState(() {
      _isLoading = false;
    });
    print('Loading set to false, UI should now be visible');
    
    // Check team assignment
    final playingInTeamId = userData['playing_in_team_id'];
    final teamName = await UserDataService.getTeamName();
    bool hasTeamId = playingInTeamId != null && playingInTeamId.toString().isNotEmpty;
    bool hasTeamName = teamName != null && teamName.isNotEmpty;
    bool hasTeam = hasTeamId || hasTeamName;
    
    setState(() {
      _userName = userData['name'] ?? 'User';
      _isWriter = userData['writer'] ?? false;
      _visibleConnected = userData['visible_connected'] ?? 0;
      _userId = userData['id']?.toString() ?? '';
      _hasTeam = hasTeam;
      _userRole = userData['role'] ?? 'player';
      _isLoading = false;
    });
    
    // Check if user has a team assigned
    await _checkTeamAssignment(userData);
    
    // Connect to WebSocket for timer updates (only for players)
    if (_userRole == 'player') {
      _connectWebSocket();
    }
    
    // Start periodic session validation to catch session invalidation
    // Disabled for now - WebSocket disconnection handling should be sufficient
    // _startPeriodicSessionValidation();
    
    // Start ECHO call timer for session validation
    print('Starting ECHO timer...');
    _startEchoTimer();
    
    // Show notification popup after successful login (only for players with a team)
    // If no team, the team dialog will show instead
    if (_userRole == 'player' && _hasTeam) {
      print('Showing notification popup for player with team...');
      _showNotificationPopup();
    }
    
    print('=== _loadUserData COMPLETE ===');
  }
  
  Future<void> _loadUserDataFallback() async {
    print('=== _loadUserDataFallback START ===');
    // Simple fallback: just use local data and continue
    final localUserData = await UserDataService.getUserData();
    
    if (localUserData == null) {
      print('No local data in fallback, redirecting to login');
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }
    
    // Get team status
    final playingInTeamId = localUserData['playing_in_team_id'];
    final teamName = await UserDataService.getTeamName();
    bool hasTeamId = playingInTeamId != null && playingInTeamId.toString().isNotEmpty;
    bool hasTeamName = teamName != null && teamName.isNotEmpty;
    bool hasTeam = hasTeamId || hasTeamName;
    
    // Set basic user data
    setState(() {
      _userName = localUserData['name'] ?? 'User';
      _isWriter = localUserData['writer'] ?? false;
      _visibleConnected = localUserData['visible_connected'] ?? 0;
      _userId = localUserData['id']?.toString() ?? '';
      _hasTeam = hasTeam;
      _userRole = localUserData['role'] ?? 'player';
      _isLoading = false;
    });
    
    // Check if user has a team assigned
    await _checkTeamAssignment(localUserData);
    
    // Connect WebSocket if player
    if (_userRole == 'player') {
      _connectWebSocket();
    }
    
    // Show notification popup only if user has a team
    if (_userRole == 'player' && hasTeam && !_hasShownNotification) {
      _showNotificationPopup();
    }
    
    print('=== _loadUserDataFallback COMPLETE ===');
  }

  // Refresh user data without session validation (for profile updates)
  Future<void> _refreshUserData() async {
    print('Refreshing user data after profile update...');
    
    // Load user data from local storage only (no session validation)
    final localUserData = await UserDataService.getUserData();
    
    if (localUserData == null) {
      print('No local user data found during refresh, redirecting to login');
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }
    
    // Update UI with fresh local data
    final playingInTeamId = localUserData['playing_in_team_id'];
    final teamName = await UserDataService.getTeamName();
    bool hasTeamId = playingInTeamId != null && playingInTeamId.toString().isNotEmpty;
    bool hasTeamName = teamName != null && teamName.isNotEmpty;
    bool hasTeam = hasTeamId || hasTeamName;
    
    setState(() {
      _userName = localUserData['name'] ?? 'User';
      _isWriter = localUserData['writer'] ?? false;
      _visibleConnected = localUserData['visible_connected'] ?? 0;
      _userId = localUserData['id']?.toString() ?? '';
      _hasTeam = hasTeam;
      _userRole = localUserData['role'] ?? 'player';
    });
    
    print('User data refreshed successfully');
    
    // Check team assignment after refresh (in case team was removed)
    await _checkTeamAssignment(localUserData);
    
    // Re-evaluate active game eligibility after profile change
    if (_userRole == 'player' && _userId.isNotEmpty) {
      await _checkForActiveGames();
    }
  }

  // Check for active games with bonus options
  Future<void> _checkForActiveGames() async {
    try {
      print('Checking for active games with bonus options...');
      final result = await DatabaseService.getPlayerActiveGames(int.parse(_userId));
      print('Active games result: ${result['success']}, games: ${result['active_games']?.length ?? 0}');
      
      if (result['success'] == true) {
        final activeGames = result['active_games'] as List? ?? [];
        print('Found ${activeGames.length} active games');
        // Player is eligible if at least one active/running game includes their team
        final eligible = activeGames.isNotEmpty;
        if (mounted) {
          setState(() {
            _eligibleForActiveGame = eligible;
          });
        }
        
        // Only show dialog if there are games with bonus options
        final gamesWithOptions = activeGames.where((game) {
          final bonusOptions = game['bonus_options'] as List? ?? [];
          print('Game ${game['id']} has ${bonusOptions.length} bonus options');
          return bonusOptions.isNotEmpty;
        }).toList();
        
        print('Found ${gamesWithOptions.length} games with bonus options');
        
        if (gamesWithOptions.isNotEmpty) {
          print('Showing bonus option selection dialog...');
          // Show bonus option selection dialog
          _showBonusOptionDialog(gamesWithOptions);
        } else {
          print('No games with bonus options found');
        }
      } else {
        print('Failed to get active games: ${result['message']}');
        if (mounted) {
          setState(() { _eligibleForActiveGame = false; });
        }
      }
    } catch (e) {
      print('Error checking for active games: $e');
      if (mounted) {
        setState(() { _eligibleForActiveGame = false; });
      }
    }
  }

  // Show bonus option selection dialog
  void _showBonusOptionDialog(List<dynamic> activeGames) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => BonusOptionSelectionDialog(
        activeGames: activeGames.cast<Map<String, dynamic>>(),
        userId: int.parse(_userId),
      ),
    );
  }

  // Check if user has a team assigned and show notification if not
  Future<void> _checkTeamAssignment(Map<String, dynamic>? userData) async {
    if (userData == null) return;
    
    // Only check for players (admins don't need teams)
    if (userData['role'] != 'player') return;
    
    // Don't show notification if already shown in this session
    if (_hasShownTeamNotification) return;
    
    final playingInTeamId = userData['playing_in_team_id'];
    final teamName = await UserDataService.getTeamName();
    
    // Primary check: playing_in_team_id from user data
    // Secondary check: team name (only if playing_in_team_id is missing)
    bool hasTeamId = playingInTeamId != null && 
                     playingInTeamId.toString().isNotEmpty && 
                     playingInTeamId.toString() != 'null' &&
                     playingInTeamId.toString().trim() != '';
    bool hasTeamName = teamName != null && teamName.isNotEmpty;
    
    // User has a team if they have either a team ID or a team name
    bool hasTeam = hasTeamId || hasTeamName;
    
    // Update the _hasTeam state variable
    setState(() {
      _hasTeam = hasTeam;
    });
    
    if (!hasTeam) {
      // Show notification popup after a short delay to ensure UI is ready
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _showNoTeamNotification();
        }
      });
    } else {
      // User has a team, reset the notification flag
      _resetTeamNotificationFlag();
    }
  }

  // Show notification popup for users without a team
  void _showNoTeamNotification() {
    // Mark that notification has been shown
    _hasShownTeamNotification = true;
    
    showDialog(
      context: context,
      barrierDismissible: false, // User must interact with the dialog
      builder: (BuildContext context) {
        return PopScope(
          canPop: false, // Prevent back button from dismissing
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Icon(Icons.group_remove, color: Colors.orange.shade600, size: 28),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'No Team Assigned',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You are not currently assigned to any team.',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 12),
                const Text(
                  'To participate in team activities and view team results, you need to join a team.',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue.shade600, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Tap the blue settings icon next to your name to update your team assignment.',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(); // Close the dialog
                  _openProfileDialog();
                },
                style: TextButton.styleFrom(
                  backgroundColor: Colors.blue.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  'Update Team',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Open profile dialog to update team assignment
  void _openProfileDialog() {
    // This will be handled by the UserInfoWidget when user taps the settings icon
    // We can trigger it by simulating a tap on the UserInfoWidget
    // For now, we'll just show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tap the blue settings icon next to your name to update your team'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  // Reset notification flag when user joins a team
  void _resetTeamNotificationFlag() {
    _hasShownTeamNotification = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text('Welcome, $_userName'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          // Connection Status Indicator
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _visibleConnected == 1 ? Icons.wifi : Icons.wifi_off,
                color: _visibleConnected == 1 ? Colors.lightGreen : Colors.red,
                size: 16,
              ),
              const SizedBox(width: 4),
              Text(
                _visibleConnected == 1 ? 'Online' : 'Offline',
                style: TextStyle(
                  fontSize: 16,
                  color: _visibleConnected == 1 ? Colors.lightGreen : Colors.red,
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          // Writer Toggle
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Writer',
                style: TextStyle(
                  fontSize: 12,
                  color: _hasTeam ? Colors.white : Colors.grey.shade400,
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: _hasTeam 
                    ? 'Toggle writer status' 
                    : 'You must be assigned to a team to become a writer',
                child: Switch(
                  value: _isWriter,
                  onChanged: _hasTeam ? _toggleWriterStatus : null,
                  activeColor: Colors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              // Call backend logout API to set visible_connected = 0
              try {
                await DatabaseService.logoutUser();
              } catch (e) {
                print('Error calling logout API: $e');
                // Continue with logout even if API call fails
              }
              
              // Close WebSocket connection
              _channel?.sink.close();
              _echoTimer?.cancel();
              
              // Clear timer status on logout
              await question_page.initializeTimerStatus();
              
              // Clear user data
              await UserDataService.clearUserData();
              Navigator.pushReplacementNamed(context, '/splash');
            },
            tooltip: 'Logout',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // User Info Widget
                    UserInfoWidget(
                      onProfileUpdated: _refreshUserData,
                    ),
                    
            // Debug: Manual session validation button (remove in production)
            if (kDebugMode) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  print('Manual session validation test...');
                  final result = await DatabaseService.validateSession();
                  print('Manual validation result: ${result['success']}, message: ${result['message']}');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Session validation: ${result['success'] ? 'SUCCESS' : 'FAILED'}'),
                      backgroundColor: result['success'] ? Colors.green : Colors.red,
                    ),
                  );
                },
                child: const Text('Test Session Validation'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () {
                  print('Current visibility status: $_isAppVisible');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('App visible: $_isAppVisible'),
                      backgroundColor: _isAppVisible ? Colors.green : Colors.orange,
                    ),
                  );
                },
                child: const Text('Check Visibility Status'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () {
                  print('Manually checking for active games...');
                  _checkForActiveGames();
                },
                child: const Text('Check Active Games'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () async {
                  print('Testing login status...');
                  final isLoggedIn = await UserDataService.isLoggedIn();
                  final userData = await UserDataService.getUserData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Logged in: $isLoggedIn, User data: ${userData != null}'),
                      backgroundColor: isLoggedIn ? Colors.green : Colors.red,
                    ),
                  );
                },
                child: const Text('Test Login Status'),
              ),
            ],
                    const SizedBox(height: 16),
                    
                    // View Summary button for all users
                    _buildViewSummaryCard(),
                    const SizedBox(height: 16),
                    
                    // Role-based Quick Actions
                    Text(
                      _userRole == 'admin' ? 'Admin Panel' : 'Game Action',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildRoleBasedActions(),
                  ],
                ),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }


  Widget _buildRoleBasedActions() {
    if (_userRole == 'admin') {
      // Admin buttons
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildActionCard(
                  'Team Management',
                  Icons.group,
                  Colors.blue,
                  () {
                    Navigator.pushNamed(context, '/admin/teams');
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionCard(
                  'User Management',
                  Icons.people,
                  Colors.green,
                  () {
                    Navigator.pushNamed(context, '/admin/users');
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildActionCard(
                  'Game Management',
                  Icons.sports_esports,
                  Colors.orange,
                  () {
                    Navigator.pushNamed(context, '/admin/games');
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildActionCard(
                  'Analytics',
                  Icons.analytics,
                  Colors.purple,
                  () {
                    Navigator.pushNamed(context, '/admin/analytics');
                  },
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      // Player buttons
      final canAccess = _hasTeam && _eligibleForActiveGame;
      return Column(
        children: [
          // Timer moved to Question page
          Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: canAccess ? 1.0 : 0.5,
                  child: _buildActionCard(
                    'Start Quiz',
                    Icons.play_arrow,
                    Colors.green,
                    canAccess 
                      ? () { Navigator.pushNamed(context, '/question'); }
                      : () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Your team is not in the active game, the team must be in an active game to start the quiz'),
                              duration: Duration(seconds: 5),
                            ),
                          );
                        },
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
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
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }



  Widget _buildViewSummaryCard() {
    final enabled = _hasTeam && _eligibleForActiveGame;
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: enabled ? () { Navigator.pushNamed(context, '/summary'); } : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.assessment,
                color: Colors.purple.shade700,
                size: 32,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'View Results',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.purple.shade700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'View your quiz results',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: enabled ? Colors.grey.shade600 : Colors.grey.shade300,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // WebSocket and Timer Management
  void _connectWebSocket() {
    if (_userId.isEmpty || _userRole != 'player') return;
    
    try {
      // Close existing connection if any
      if (_channel != null) {
        try {
          _channel!.sink.close();
          print('Closed existing WebSocket connection before reconnecting');
        } catch (e) {
          print('Error closing existing WebSocket: $e');
        }
        _channel = null;
      }
      
      // Get WebSocket URL from configurable server URL
      final wsUrl = DatabaseService.getWebSocketUrl(_userId);
      print('Connecting to WebSocket: $wsUrl');
      
      _channel = WebSocketChannel.connect(
        Uri.parse(wsUrl),
      );
      
      // Set visible connected status when WebSocket connects
      setState(() {
        _visibleConnected = 1;
      });
      print('WebSocket connected, setting visible_connected = 1');
      
      _channel!.stream.listen(
        (data) {
          final now = DateTime.now();
          final utcNow = DateTime.now().toUtc();
          print('=== WebSocket Message Received ===');
          print('Timestamp (Local): ${now.toIso8601String()}');
          print('Timestamp (UTC): ${utcNow.toIso8601String()}');
          print('Time since epoch (ms): ${now.millisecondsSinceEpoch}');
          print('Data: $data');
          try {
            final message = json.decode(data) as Map<String, dynamic>;
            print('Parsed message: $message');
            
            // Forward timer messages to question_page if it's listening
            if (message['type'] == 'timer_trigger') {
              print('Forwarding timer message to question_page');
              question_page.forwardTimerMessage(message);
            }
          } catch (e) {
            print('Error parsing WebSocket message: $e');
          }
        },
        onError: (error) {
          print('WebSocket error: $error');
          // Set visible connected status to 0 on error
          if (mounted) {
            setState(() {
              _visibleConnected = 0;
            });
            print('WebSocket error, setting visible_connected = 0');
          }
          // WebSocket error might indicate connection issues, check if we should logout
          _handleWebSocketDisconnection();
        },
        onDone: () {
          print('WebSocket connection closed - this might be due to new device login');
          // Set visible connected status to 0 when WebSocket disconnects
          if (mounted) {
            setState(() {
              _visibleConnected = 0;
            });
            print('WebSocket disconnected, setting visible_connected = 0');
          }
          // WebSocket connection closed, this might be due to new device login
          // Show immediate warning to user
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Connection lost - attempting to reconnect.\n'
                'Retry is not successful\n'
                'Please refrash the page manaully...',
                softWrap: true, // ensures wrapping
                ),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 2),
              ),
            );
          }
          _handleWebSocketDisconnection();
        },
      );
    } catch (e) {
      print('Error connecting to WebSocket: $e');
      // Set visible connected status to 0 on connection error
      if (mounted) {
        setState(() {
          _visibleConnected = 0;
        });
      }
    }
  }

  // Ensure WebSocket is connected, reconnect if needed
  void _ensureWebSocketConnected() {
    if (_userId.isEmpty || _userRole != 'player') return;
    
    // Check if WebSocket is null or closed
    bool needsReconnect = false;
    
    if (_channel == null) {
      print('WebSocket is null, needs reconnection');
      needsReconnect = true;
    } else {
      // Try to check if connection is still alive by checking the stream
      // If the stream is closed, we need to reconnect
      try {
        // The stream might be closed, but we can't directly check it
        // So we'll just try to reconnect if channel exists but visible_connected is 0
        if (_visibleConnected == 0) {
          print('WebSocket exists but visible_connected is 0, attempting reconnection');
          needsReconnect = true;
        }
      } catch (e) {
        print('Error checking WebSocket state: $e, will reconnect');
        needsReconnect = true;
      }
    }
    
    if (needsReconnect) {
      print('Reconnecting WebSocket...');
      _connectWebSocket();
    } else {
      print('WebSocket is already connected');
    }
  }

  // Handle WebSocket disconnection
  void _handleWebSocketDisconnection() {
    if (_disconnectionHandlerRunning) {
      print('Disconnection handler already running, skipping...');
      return;
    }
    
    _disconnectionHandlerRunning = true;
    print('WebSocket disconnected, attempting to reconnect...');
    
    // Try to reconnect immediately if user is still logged in
    Future.delayed(const Duration(seconds: 1), () async {
      if (!mounted) {
        _disconnectionHandlerRunning = false;
        return;
      }
      
      // Check if we have valid local data first (faster check)
      final userData = await UserDataService.getUserData();
      if (userData != null && userData['access_token'] != null && _userRole == 'player') {
        print('Have valid local data, attempting immediate reconnection...');
        _ensureWebSocketConnected();
      }
      
      // Also check login status with backend (more thorough)
      Future.delayed(const Duration(seconds: 1), () async {
        if (!mounted) {
          _disconnectionHandlerRunning = false;
          return;
        }
        
        try {
          final loginCheck = await DatabaseService.checkLoginStatus();
          print('Login check result: ${loginCheck['success']}, message: ${loginCheck['message']}');
          
          if (loginCheck['success'] == false) {
            print('Login check failed after WebSocket disconnection, but checking if we have valid local data...');
            // Check if we have valid local data before logging out
            final userData = await UserDataService.getUserData();
            if (userData != null && userData['access_token'] != null) {
              print('Have valid local data, assuming still logged in and reconnecting...');
              if (_userRole == 'player') {
                _ensureWebSocketConnected();
              }
            } else {
              print('No valid local data, logging out user');
              await _logoutUser();
            }
          } else {
            print('User still logged in after WebSocket disconnection, ensuring WebSocket is connected...');
            // User is still logged in, ensure WebSocket is connected
            if (_userRole == 'player') {
              _ensureWebSocketConnected();
            }
          }
        } catch (e) {
          print('Error during login check after WebSocket disconnection: $e');
          // Check if we have valid local data before giving up
          final userData = await UserDataService.getUserData();
          if (userData != null && userData['access_token'] != null) {
            print('Network error but have valid local data, attempting to reconnect...');
            if (_userRole == 'player') {
              _ensureWebSocketConnected();
            }
          } else {
            print('No valid local data and network error, logging out user');
            await _logoutUser();
          }
        }
        
        _disconnectionHandlerRunning = false;
      });
    });
  }

  // Logout user and redirect to login
  Future<void> _logoutUser() async {
    try {
      // Call backend logout API to set visible_connected = 0
      try {
        await DatabaseService.logoutUser();
      } catch (e) {
        print('Error calling logout API: $e');
        // Continue with logout even if API call fails
      }
      
      // Close WebSocket connection
      _channel?.sink.close();
      
      // Cancel timers
      _echoTimer?.cancel();
      
      // Clear timer status on logout
      await question_page.initializeTimerStatus();
      
      // Clear user data
      await UserDataService.clearUserData();
      
      // Show logout message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You have been logged out due to login from another device'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
        
        // Redirect to login page
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (e) {
      print('Error during logout: $e');
      // Even if there's an error, redirect to login
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    }
  }

  // Setup browser visibility detection for web
  void _setupBrowserVisibilityDetection() {
    if (kIsWeb) {
      // Listen for browser tab visibility changes
      // This will detect when user switches to other tabs or applications
      _setupWebVisibilityListener();
    }
  }
  
  // Setup web visibility listener
  void _setupWebVisibilityListener() {
    if (kIsWeb) {
      // Listen for browser tab visibility changes
      html.document.addEventListener('visibilitychange', (event) {
        if (html.document.hidden == true) {
          // Tab is hidden (user switched to another tab/app)
          _isAppVisible = false;
          print('Browser tab became hidden - user switched to another tab/app');
        } else {
          // Tab is visible (user returned to this tab)
          _isAppVisible = true;
          print('Browser tab became visible - user returned to this tab');
          // Reconnect WebSocket if needed when tab becomes visible
          if (_userRole == 'player') {
            _ensureWebSocketConnected();
          }
        }
      });
      
      // Listen for window focus/blur events
      html.window.addEventListener('blur', (event) {
        _isAppVisible = false;
        print('Browser window lost focus - user switched to another application');
      });
      
      html.window.addEventListener('focus', (event) {
        _isAppVisible = true;
        print('Browser window gained focus - user returned to this application');
        // Reconnect WebSocket if needed when window gains focus
        if (_userRole == 'player') {
          _ensureWebSocketConnected();
        }
      });
      
      // Listen for page unload (user closes tab/window)
      html.window.addEventListener('beforeunload', (event) {
        _isAppVisible = false;
        print('Page is about to unload - user is closing the tab/window');
      });
      
      print('Web visibility detection setup complete');
    }
  }

  void _handleWriterStatusChange(Map<String, dynamic> writerStatus) {
    final isWriter = writerStatus['is_writer'] ?? false;
    final currentWriterName = writerStatus['current_writer_name'];
    final previousWriterName = writerStatus['previous_writer_name'];
    
    // Check if writer status changed
    if (_isWriter != isWriter || _currentWriterName != currentWriterName) {
      setState(() {
        _previousWriterName = _currentWriterName;
        _isWriter = isWriter;
        _currentWriterName = currentWriterName;
      });
      
      // Show notification if writer status changed
      if (_previousWriterName != null && _currentWriterName != _previousWriterName) {
        _showWriterStatusNotification();
      }
    }
  }

  void _showWriterStatusNotification() {
    String message;
    if (_isWriter) {
      message = 'You are now the writer for your team';
    } else if (_currentWriterName != null) {
      message = 'Writer privilege changed to: $_currentWriterName';
    } else {
      message = 'Writer privilege has been turned OFF';
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        backgroundColor: _isWriter ? Colors.green : Colors.orange,
      ),
    );
  }

  Future<void> _toggleWriterStatus(bool value) async {
    try {
      final action = value ? 'on' : 'off';
      final result = await DatabaseService.toggleWriterStatus(action);
      
      if (result['success'] == true) {
        // Update local state
        setState(() {
          _isWriter = value;
        });
        
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'Writer status updated'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'Failed to update writer status'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
        
        // Revert the switch state
        setState(() {
          _isWriter = !value;
        });
      }
    } catch (e) {
      print('Error toggling writer status: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating writer status: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
      
      // Revert the switch state
      setState(() {
        _isWriter = !value;
      });
    }
  }

  // Show notification popup after successful login
  void _showNotificationPopup() {
    print('=== _showNotificationPopup START ===');
    if (_hasShownNotification) {
      print('Notification already shown, returning');
      return;
    }
    
    _hasShownNotification = true;
    print('Showing notification popup after login...');
    
    Timer? autoDismissTimer;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Row(
              children: [
                Icon(Icons.info, color: Colors.blue, size: 28),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Important Notice',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This app cannot be used in split view mode and should be opened in full-screen mode while the game is running. All the detected attempts to use other apps during the game will be reported to the game operator.',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  autoDismissTimer?.cancel();
                  if (mounted) {
                    Navigator.of(context).pop();
                    // Check for active games after notification is dismissed
                    _checkForActiveGamesAfterNotification();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
                child: const Text('I Understand'),
              ),
            ],
          ),
        );
      },
    );
    
    // Auto-dismiss after 10 seconds
    autoDismissTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) {
        Navigator.of(context).pop();
        print('Notification popup auto-dismissed after 10 seconds');
        // Check for active games after notification is dismissed
        _checkForActiveGamesAfterNotification();
      }
    });
  }
  
  // Check for active games after notification popup is dismissed
  void _checkForActiveGamesAfterNotification() {
    print('Notification popup dismissed, checking for active games...');
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _checkForActiveGames();
      }
    });
  }

  // Start ECHO call timer for session validation
  void _startEchoTimer() {
    print('=== _startEchoTimer START ===');
    // Send ECHO call every 5 seconds to validate session
    _echoTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      print('ECHO timer triggered');
      if (!mounted) {
        print('Widget not mounted, canceling ECHO timer');
        timer.cancel();
        return;
      }
      
      try {
        print('Sending ECHO call...');
        final echoResult = await DatabaseService.sendEchoCall(_isAppVisible).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            print('ECHO call timed out');
            // Mark as offline on timeout
            if (mounted) {
              setState(() {
                _visibleConnected = 0;
              });
            }
            return {'success': false, 'should_logout': false};
          },
        );
        print('ECHO call result: visible=$_isAppVisible, success=${echoResult['success']}, should_logout=${echoResult['should_logout']}, visible_connected=${echoResult['visible_connected']}');
        
        if (echoResult['should_logout'] == true) {
          print('ECHO call indicates session invalid, logging out user');
          timer.cancel();
          await _logoutUser();
        } else if (echoResult['success'] == true) {
          // ECHO call successful, ensure WebSocket is connected
          if (_userRole == 'player') {
            _ensureWebSocketConnected();
          }
          
          // Update visible connected status
          final visibleConnected = echoResult['visible_connected'];
          if (visibleConnected != null && visibleConnected != _visibleConnected) {
            setState(() {
              _visibleConnected = visibleConnected;
            });
            print('Visible connected status updated: $_visibleConnected');
          }
          
          // Handle writer status changes
          final writerStatus = echoResult['writer_status'];
          if (writerStatus != null) {
            _handleWriterStatusChange(writerStatus);
          }
        } else {
          // Any non-success from echo means backend may be unavailable – show Offline
          if (mounted) {
            setState(() {
              _visibleConnected = 0;
            });
          }
        }
      } catch (e) {
        print('Error during ECHO call: $e');
        // On network errors mark as Offline, do not logout
        if (mounted) {
          setState(() {
            _visibleConnected = 0;
          });
        }
      }
    });
    print('ECHO timer started');
  }

  // Start periodic session validation
  void _startPeriodicSessionValidation() {
    // Validate session every 30 seconds to catch new device logins
    Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      try {
        print('Running periodic session validation...');
        final sessionResult = await DatabaseService.validateSession();
        print('Periodic session validation result: ${sessionResult['success']}, message: ${sessionResult['message']}');
        
        // Only logout if session validation explicitly fails, not on errors
        if (sessionResult['success'] == false) {
          print('Periodic session validation failed, logging out user');
          timer.cancel();
          await _logoutUser();
        } else {
          print('Periodic session validation successful');
        }
      } catch (e) {
        print('Error during periodic session validation: $e');
        // Don't logout on error, just log it and continue
      }
    });
  }


  @override
  void dispose() {
    _echoTimer?.cancel();
    _channel?.sink.close();
    WidgetsBinding.instance.removeObserver(_AppLifecycleObserver(
      onResumed: () {},
      onPaused: () {},
    ));
    super.dispose();
  }
}

class BonusOptionSelectionDialog extends StatefulWidget {
  final List<Map<String, dynamic>> activeGames;
  final int userId;

  const BonusOptionSelectionDialog({
    super.key,
    required this.activeGames,
    required this.userId,
  });

  @override
  State<BonusOptionSelectionDialog> createState() => _BonusOptionSelectionDialogState();
}

class _BonusOptionSelectionDialogState extends State<BonusOptionSelectionDialog> {
  Map<String, dynamic>? _selectedGame;
  String? _selectedOption;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Select the first game by default
    if (widget.activeGames.isNotEmpty) {
      _selectedGame = widget.activeGames.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.9,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
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
                Icon(Icons.notifications_active, color: Colors.blue),
                const SizedBox(width: 8),
                const Text(
                  'Game Options',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Game Selection
            if (widget.activeGames.length > 1) ...[
              const Text(
                'Select Game:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<Map<String, dynamic>>(
                value: _selectedGame,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
                items: widget.activeGames.map((game) {
                  return DropdownMenuItem(
                    value: game,
                    child: Text(game['game_name'] ?? 'Unknown Game'),
                  );
                }).toList(),
                onChanged: (game) {
                  setState(() {
                    _selectedGame = game;
                    _selectedOption = null; // Reset selection when game changes
                  });
                },
              ),
              const SizedBox(height: 16),
            ],
            
            // Bonus Options
            if (_selectedGame != null) ...[
              const Text(
                'Select Bonus Option:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: (_selectedGame!['bonus_options']?.length ?? 0) + 1, // +1 for "Leave default"
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      // Add "Leave default" option at the top
                      final isSelected = _selectedOption == 'Leave default';
                      return RadioListTile<String>(
                        title: Text(
                          'Leave default',
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: Colors.green.shade700,
                          ),
                        ),
                        subtitle: const Text(
                          'Use standard scoring (1/0)',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: 'Leave default',
                        groupValue: _selectedOption,
                        onChanged: (value) {
                          setState(() {
                            _selectedOption = value;
                          });
                        },
                      );
                    }
                    
                    final option = _selectedGame!['bonus_options'][index - 1];
                    final isSelected = _selectedOption == option['name'];
                    
                    return RadioListTile<String>(
                      title: Text(
                        option['name'] ?? 'Unknown Option',
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        'Score: ${option['correct_score']}/${option['wrong_score']}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: option['name'],
                      groupValue: _selectedOption,
                      onChanged: (value) {
                        setState(() {
                          _selectedOption = value;
                        });
                      },
                    );
                  },
                ),
              ),
            ],
            
            const SizedBox(height: 24),
            
            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Skip'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _selectedOption != null ? _selectOption : null,
                  child: _isLoading 
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Select Option'),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Future<void> _selectOption() async {
    if (_selectedOption == null || _selectedGame == null) return;
    
    setState(() {
      _isLoading = true;
    });
    
    try {
      if (_selectedOption == 'Leave default') {
        // For "Leave default", call the API to remove all bonus options
        final result = await DatabaseService.selectDefaultOption(
          _selectedGame!['id'],
          widget.userId,
        );
        
        if (result['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Using default scoring (1/0) - all bonus options removed'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: ${result['message']}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } else {
        // For bonus options, call the API
        final result = await DatabaseService.selectBonusOption(
          _selectedGame!['id'],
          widget.userId,
          _selectedOption!,
        );
        
        if (result['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Bonus option "${_selectedOption}" selected successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: ${result['message']}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error selecting option: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
}

// App lifecycle observer for tracking visibility
class _AppLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResumed;
  final VoidCallback onPaused;

  _AppLifecycleObserver({
    required this.onResumed,
    required this.onPaused,
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onResumed();
        break;
      case AppLifecycleState.paused:
        onPaused();
        break;
      default:
        break;
    }
  }
}


