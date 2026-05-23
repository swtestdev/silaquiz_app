import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_data_service.dart';
import '../services/api_config_service.dart';
import 'dart:html' as html;
import 'question_page.dart' show initializeTimerStatus;

// API service class for authentication operations
class DatabaseService {
  // FastAPI backend endpoint - loaded from ApiConfigService at startup, mutable at runtime
  static String _baseUrl = ApiConfigService.defaultBaseUrl;

  static String get baseUrl => _baseUrl;
  static void setBaseUrl(String url) {
    // Basic normalization
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    _baseUrl = url;
  }
  
  // Get WebSocket URL from base URL
  static String getWebSocketUrl(String userId) {
    // Convert HTTP URL to WebSocket URL
    String wsUrl = _baseUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
    // Remove /api suffix if present
    if (wsUrl.endsWith('/api')) {
      wsUrl = wsUrl.substring(0, wsUrl.length - 4);
    }
    return '$wsUrl/ws/timer/$userId';
  }
  
  // Method to check user credentials via API
  static Future<Map<String, dynamic>> checkCredentials(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/auth/login'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': email,
          'password': password,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'user': data['user'],
          'access_token': data['access_token'],
          'session_token': data['session_token'],
        };
      } else {
        final data = jsonDecode(response.body);
        return {
          'success': false,
          'message': data['detail'] ?? data['message'] ?? 'Login failed',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  // Method to validate current session
  static Future<Map<String, dynamic>> validateSession() async {
    try {
      final userData = await UserDataService.getUserData();
      print('Session validation - Local user data: $userData');
      
      if (userData == null || userData['access_token'] == null) {
        print('Session validation - No access token found');
        return {
          'success': false,
          'message': 'No active session found'
        };
      }

      print('Session validation - Making request to server with token: ${userData['access_token'].substring(0, 20)}...');
      
      final response = await http.get(
        Uri.parse('$_baseUrl/auth/validate-session'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${userData['access_token']}',
        },
      );

      print('Session validation - Server response status: ${response.statusCode}');
      print('Session validation - Server response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success']) {
          print('Session validation - Success, updating local data');
          // Get current local data to preserve tokens
          final currentUserData = await UserDataService.getUserData();
          if (currentUserData != null) {
            // Merge server data with local data to preserve tokens
            final mergedData = <String, dynamic>{
              ...currentUserData,
              ...data['user'],
              // Preserve the original tokens
              'access_token': currentUserData['access_token'],
              'session_token': currentUserData['session_token'],
            };
            await UserDataService.saveUserData(mergedData);
            print('Session validation - Merged data with preserved tokens');
            return {
              'success': true,
              'user': mergedData
            };
          } else {
            // No local data, just use server data
            await UserDataService.saveUserData(data['user']);
            return {
              'success': true,
              'user': data['user']
            };
          }
        } else {
          print('Session validation - Server returned success=false');
          // Session is invalid, but don't clear local data immediately
          // Let the app decide what to do with invalid sessions
          return {
            'success': false,
            'message': data['message'] ?? 'Session validation failed'
          };
        }
      } else {
        print('Session validation - Server returned error status: ${response.statusCode}');
        // Session is invalid, but don't clear local data immediately
        // Let the app decide what to do with invalid sessions
        return {
          'success': false,
          'message': 'Session validation failed'
        };
      }
    } catch (e) {
      print('Session validation - Exception: $e');
      return {
        'success': false,
        'message': 'Session validation failed: ${e.toString()}'
      };
    }
  }

  // Method to send ECHO call for session validation
  static Future<Map<String, dynamic>> sendEchoCall(
    bool appVisible, {
    String source = 'periodic',
    String? visibilityReason,
  }) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null || userData['session_token'] == null) {
        return {
          'success': false,
          'message': 'No active session found',
          'should_logout': true
        };
      }

      final body = <String, dynamic>{
        'session_token': userData['session_token'],
        'app_visible': appVisible,
        'source': source,
      };
      if (visibilityReason != null && visibilityReason.isNotEmpty) {
        body['visibility_reason'] = visibilityReason;
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/auth/echo'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${userData['access_token']}',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        return {
          'success': responseData['success'] ?? false,
          'message': responseData['message'] ?? 'Unknown response',
          'should_logout': responseData['should_logout'] ?? false,
          'visible_connected': responseData['visible_connected'] ?? 0,
          'writer_status': responseData['writer_status'] ?? null,
        };
      } else {
        return {
          'success': false,
          'message': 'Echo call failed with status ${response.statusCode}',
          'should_logout': true
        };
      }
    } catch (e) {
      print('Echo call error: $e');
      return {
        'success': false,
        'message': 'Echo call failed: ${e.toString()}',
        'should_logout': false  // Don't logout on network errors
      };
    }
  }

  // Method to toggle writer status
  static Future<Map<String, dynamic>> toggleWriterStatus(String action) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return {
          'success': false,
          'message': 'No active session found',
        };
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/team/toggle-writer'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${userData['access_token']}',
        },
        body: jsonEncode({
          'action': action, // 'on' or 'off'
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        return {
          'success': responseData['success'] ?? false,
          'message': responseData['message'] ?? 'Unknown response',
          'writer_status': responseData['writer_status'] ?? null,
        };
      } else {
        return {
          'success': false,
          'message': 'Toggle writer status failed with status ${response.statusCode}',
        };
      }
    } catch (e) {
      print('Toggle writer status error: $e');
      return {
        'success': false,
        'message': 'Toggle writer status failed: ${e.toString()}',
      };
    }
  }

  // Method to check if user is still logged in (simpler than session validation)
  static Future<Map<String, dynamic>> checkLoginStatus() async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return {
          'success': false,
          'message': 'No active session found'
        };
      }

      // Add timeout to prevent hanging
      final response = await http.get(
        Uri.parse('$_baseUrl/auth/check-login'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${userData['access_token']}',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return {
          'success': true,
          'logged_in': true
        };
      } else {
        return {
          'success': false,
          'message': 'Not logged in'
        };
      }
    } catch (e) {
      // If there's a network error, assume user is still logged in if we have valid local data
      print('Login check network error: $e');
      final userData = await UserDataService.getUserData();
      if (userData != null && userData['access_token'] != null) {
        print('Network error but have valid local data, assuming still logged in');
        return {
          'success': true,
          'logged_in': true
        };
      }
      return {
        'success': false,
        'message': 'Login check failed: ${e.toString()}'
      };
    }
  }

  // Method to logout user
  static Future<Map<String, dynamic>> logoutUser() async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return {
          'success': false,
          'message': 'No active session found'
        };
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/auth/logout'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${userData['access_token']}',
        },
      );

      if (response.statusCode == 200) {
        // Clear local user data
        await UserDataService.clearUserData();
        return {
          'success': true,
          'message': 'Logout successful'
        };
      } else {
        final data = jsonDecode(response.body);
        return {
          'success': false,
          'message': data['detail'] ?? data['message'] ?? 'Logout failed',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Logout failed: ${e.toString()}'
      };
    }
  }

  // Get last timer setting from server
  static Future<Map<String, dynamic>> getLastTimerSetting() async {
    try {
      final result = await _makeApiCall('/timer/last-setting');
      print('getLastTimerSetting: Raw result from _makeApiCall: $result');
      
      // _makeApiCall wraps the response in {"success": true, "data": <response>}
      // The backend returns {"success": True, "data": <timer_setting>}
      // So result['data'] contains the backend response
      if (result['success'] == true && result['data'] != null) {
        final backendResponse = result['data'] as Map<String, dynamic>;
        print('getLastTimerSetting: Backend response: $backendResponse');
        
        // Check if backend response has success and data fields
        if (backendResponse['success'] == true && backendResponse['data'] != null) {
          print('Last timer data: ${backendResponse['data']}');
          return {
            'success': true,
            'data': backendResponse['data']
          };
        } else {
          print('getLastTimerSetting: Backend returned success=false or data=null');
          return {
            'success': false,
            'message': backendResponse['message'] ?? 'No timer setting available',
            'data': null
          };
        }
      } else {
        print('getLastTimerSetting: _makeApiCall returned success=false or data=null');
        return {
          'success': false,
          'message': result['message'] ?? 'No timer setting available',
          'data': null
        };
      }
    } catch (e) {
      print('getLastTimerSetting: Exception: $e');
      return {
        'success': false,
        'message': 'Error getting last timer setting: ${e.toString()}',
        'data': null
      };
    }
  }

  // Helper method to handle API calls with session validation
  static Future<Map<String, dynamic>> _makeApiCall(String endpoint, {String method = 'GET', Map<String, dynamic>? body}) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return {
          'success': false,
          'message': 'No active session found',
          'should_logout': true
        };
      }

      final response = method == 'GET' 
        ? await http.get(
            Uri.parse('$_baseUrl$endpoint'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${userData['access_token']}',
            },
          )
        : await http.post(
            Uri.parse('$_baseUrl$endpoint'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${userData['access_token']}',
            },
            body: body != null ? jsonEncode(body) : null,
          );

      if (response.statusCode == 401) {
        // Session is invalid, clear local data
        await UserDataService.clearUserData();
        return {
          'success': false,
          'message': 'Session expired. Please login again.',
          'should_logout': true
        };
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'data': data
        };
      } else {
        final data = jsonDecode(response.body);
        return {
          'success': false,
          'message': data['detail'] ?? data['message'] ?? 'Request failed'
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Request failed: ${e.toString()}'
      };
    }
  }

  // Method to initialize database (this would be called by your backend)
  static Future<void> createUsersTable() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/init-db'),
        headers: {
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw Exception('Database initialization request timed out');
        },
      );
      
      if (response.statusCode == 200) {
        print('Database initialized admin successfully');
      } else {
        print('Database initialization admin failed: ${response.body}');
        throw Exception('Database initialization failed with status ${response.statusCode}');
      }
    } catch (e) {
      print('Database initialization admin error: $e');
      rethrow; // Re-throw to be caught by the calling method
    }
  }

  // Method to get team name by team code or team ID
  static Future<Map<String, dynamic>> getTeamName(String teamIdentifier) async {
    try {
      // Determine if it's a team code (6 characters) or team ID (numeric)
      bool isNumeric = RegExp(r'^\d+$').hasMatch(teamIdentifier);
      
      Map<String, dynamic> requestBody;
      if (isNumeric) {
        requestBody = {'team_id': int.parse(teamIdentifier)};
      } else {
        requestBody = {'team_code': teamIdentifier};
      }
      
      final response = await http.post(
        Uri.parse('$_baseUrl/teams/get_team_name'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );

      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'team_id': data['team_id'],
          'team_name': data['team_name'],
          'team_code': data['team_code'],
          'team_city': data['team_city'],
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to get team name',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  // Method to update user profile
  static Future<Map<String, dynamic>> updateUserProfile(String userId, Map<String, dynamic> profileData) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/users/$userId/profile'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(profileData),
      );

      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'user': data['user'],
          'message': data['message'],
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to update profile',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  // Method to register new user via FastAPI
  static Future<Map<String, dynamic>> registerUser(String email, String password, String name) async {
    try {
      print('Attempting to register user: $email');
      print('API URL: $_baseUrl/auth/register');
      final response = await http.post(
        Uri.parse('$_baseUrl/auth/register'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': email,
          'password': password,
          'name': name,
        }),
      );
      print('Registration response status: ${response.statusCode}');
      print('Registration response body: ${response.body}');

      final data = jsonDecode(response.body);
      
      // Check for successful registration (status 200/201 or success message)
      if (response.statusCode == 200 || response.statusCode == 201 || 
          data['success'] == true || data['message']?.contains('successful') == true) {
        return {
          'success': true,
          'user': data['user'],
          'message': data['message'] ?? 'Registration successful',
        };
      } else {
        return {
          'success': false,
          'message': data['detail'] ?? data['message'] ?? 'Registration failed',
        };
      }
    } catch (e) {
      print('Registration error: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  // Admin API methods
  static Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/users'),
        headers: {'Content-Type': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      } else {
        print('Failed to get users: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error getting users: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getAllTeams() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/teams'),
        headers: {'Content-Type': 'application/json'},
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      } else {
        print('Failed to get teams: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error getting teams: $e');
      return [];
    }
  }

  static Future<Map<String, dynamic>> updateUserAdmin(int userId, Map<String, dynamic> userData) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/admin/users/$userId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(userData),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message'],
          'user': data['user']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to update user'
        };
      }
    } catch (e) {
      print('Error updating user: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> createTeam(String teamName, String city) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/teams'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'team_name': teamName,
          'team_city': city,
        }),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message'],
          'team': data['team']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to create team'
        };
      }
    } catch (e) {
      print('Error creating team: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> updateTeam(int teamId, Map<String, dynamic> teamData) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/admin/teams/$teamId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(teamData),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to update team'
        };
      }
    } catch (e) {
      print('Error updating team: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> getTeamMembers(int teamId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/teams/$teamId/members'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'team_name': data['team_name'],
          'team_code': data['team_code'],
          'members': data['members']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to get team members'
        };
      }
    } catch (e) {
      print('Error getting team members: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> loadGameFromExcel(String gameName, List<int> fileBytes) async {
    try {
      // Convert bytes to base64 for transmission
      final base64String = base64Encode(fileBytes);
      
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/games/load-excel'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'game_name': gameName,
          'file_data': base64String,
        }),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message'],
          'data': data['data']  // Updated to match new API response structure
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to load game from Excel'
        };
      }
    } catch (e) {
      print('Error loading game from Excel: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  // Active Games Management APIs
  static Future<List<Map<String, dynamic>>> getActiveGames() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/active-games'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return List<Map<String, dynamic>>.from(data['games'] ?? []);
      } else {
        print('Error getting active games: ${data['message']}');
        return [];
      }
    } catch (e) {
      print('Error getting active games: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getAllGames() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/games'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return List<Map<String, dynamic>>.from(data['games'] ?? []);
      } else {
        print('Error getting all games: ${data['message']}');
        return [];
      }
    } catch (e) {
      print('Error getting all games: $e');
      return [];
    }
  }

  static Future<Map<String, dynamic>> createActiveGame(
    String gameId,
    List<String> teamIds,
    List<Map<String, dynamic>> bonusOptions,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/active-games'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'game_id': gameId,
          'team_ids': teamIds,
          'bonus_options': bonusOptions,
        }),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message'],
          'active_game': data['active_game']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to create active game'
        };
      }
    } catch (e) {
      print('Error creating active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> updateActiveGame(
    int activeGameId,
    String gameId,
    List<String> teamIds,
    List<Map<String, dynamic>> bonusOptions,
  ) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'game_id': gameId,
          'team_ids': teamIds,
          'bonus_options': bonusOptions,
        }),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message'],
          'active_game': data['active_game']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to update active game'
        };
      }
    } catch (e) {
      print('Error updating active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> deleteActiveGame(int activeGameId) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to delete active game'
        };
      }
    } catch (e) {
      print('Error deleting active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> stopAndRemoveActiveGame(int activeGameId) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to stop and remove active game'
        };
      }
    } catch (e) {
      print('Error stopping and removing active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> getGameStructure(String gameId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/games/$gameId/structure'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'tiers': data['tiers'],
          'questions': data['questions'],
          'game_info': data['game_info']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to get game structure'
        };
      }
    } catch (e) {
      print('Error getting game structure: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> getActiveGameBonusOptions(int activeGameId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId/bonus-options'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'bonus_options': data['bonus_options']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to get bonus options'
        };
      }
    } catch (e) {
      print('Error getting bonus options: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> startActiveGame(int activeGameId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId/start'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to start active game'
        };
      }
    } catch (e) {
      print('Error starting active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> pauseActiveGame(int activeGameId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId/pause'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to pause active game'
        };
      }
    } catch (e) {
      print('Error pausing active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> resumeActiveGame(int activeGameId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId/resume'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to resume active game'
        };
      }
    } catch (e) {
      print('Error resuming active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> stopActiveGame(int activeGameId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId/stop'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to stop active game'
        };
      }
    } catch (e) {
      print('Error stopping active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  /// Get all distinct rounds for a game
  /// Returns list of round names
  static Future<List<String>> getGameRounds(String gameName) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return [];
      }
      
      final encodedGameName = Uri.encodeComponent(gameName);
      
      final response = await http.get(
        Uri.parse('$_baseUrl/games/$encodedGameName/rounds'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data.cast<String>();
        }
      }
      return [];
    } catch (e) {
      print('Error fetching game rounds: $e');
      return [];
    }
  }

  /// Get game questions by round name
  /// Returns list of questions with all their data
  static Future<List<Map<String, dynamic>>> getGameQuestionsByRound(String gameName, String roundName) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return [];
      }
      
      final encodedGameName = Uri.encodeComponent(gameName);
      final encodedRoundName = Uri.encodeComponent(roundName);
      
      final response = await http.get(
        Uri.parse('$_baseUrl/games/$encodedGameName/round/$encodedRoundName'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data.cast<Map<String, dynamic>>();
        } else if (data is Map) {
          return [Map<String, dynamic>.from(data)];
        }
      }
      return [];
    } catch (e) {
      print('Error fetching game questions by round: $e');
      return [];
    }
  }

  /// Single question by game table primary key (when round-filtered list is empty).
  static Future<Map<String, dynamic>?> getGameQuestionById(String gameName, int questionId) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return null;
      }

      final encodedGameName = Uri.encodeComponent(gameName);

      final response = await http.get(
        Uri.parse('$_baseUrl/games/$encodedGameName/question-by-id/$questionId'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      }
      return null;
    } catch (e) {
      print('Error fetching game question by id: $e');
      return null;
    }
  }

  /// Get team answers for a specific game
  /// Returns list of answers keyed by question_id
  static Future<List<Map<String, dynamic>>> getTeamAnswersForGame(String gameNameSafe, int teamId) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return [];
      }
      
      final encodedGameName = Uri.encodeComponent(gameNameSafe);
      
      final response = await http.get(
        Uri.parse('$_baseUrl/active-games/team-answers/$encodedGameName/$teamId'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data.cast<Map<String, dynamic>>();
        } else if (data is Map && data['answers'] is List) {
          return (data['answers'] as List).cast<Map<String, dynamic>>();
        }
      }
      return [];
    } catch (e) {
      print('Error getting team answers: $e');
      return [];
    }
  }

  /// Batch upsert team answer text in active_teams_answers_{game} (writer-only; server enforces).
  static Future<Map<String, dynamic>> putTeamAnswersBatch(
    String gameNameSafe,
    int teamId,
    List<Map<String, dynamic>> answers, {
    String? roundName,
    int? roundTimer,
    Object? clientRevision,
  }) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return {
          'success': false,
          'error': 'not_authenticated',
          'message': 'No user session',
        };
      }
      final encodedGameName = Uri.encodeComponent(gameNameSafe);
      final body = <String, dynamic>{
        'answers': answers
            .map(
              (a) {
                final m = <String, dynamic>{
                  'question_id': a['question_id'],
                };
                final useSlots = a.containsKey('player_answer1');
                if (useSlots) {
                  m['player_answer1'] = a['player_answer1'] ?? '';
                  m['player_answer2'] = a['player_answer2'] ?? '';
                  m['player_answer3'] = a['player_answer3'] ?? '';
                  m['player_answer4'] = a['player_answer4'] ?? '';
                } else {
                  m['answer'] = a['answer'] ?? '';
                }
                if (a['correct_score'] != null) {
                  m['correct_score'] = a['correct_score'];
                }
                if (a['wrong_score'] != null) {
                  m['wrong_score'] = a['wrong_score'];
                }
                if (a['lucky_bonus'] != null) {
                  m['lucky_bonus'] = a['lucky_bonus'];
                }
                if (a.containsKey('final_score')) {
                  m['final_score'] = a['final_score'];
                }
                return m;
              },
            )
            .toList(),
      };
      if (roundName != null && roundName.isNotEmpty) {
        body['round_name'] = roundName;
      }
      if (roundTimer != null) {
        body['round_timer'] = roundTimer;
      }
      if (clientRevision != null) {
        body['client_revision'] = clientRevision;
      }
      final response = await http.put(
        Uri.parse('$_baseUrl/active-games/team-answers/$encodedGameName/$teamId'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      final dynamic decoded = response.body.isNotEmpty ? jsonDecode(response.body) : null;
      if (response.statusCode == 200) {
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
        return {'success': true, 'updated': 0, 'conflicts': []};
      }
      if (response.statusCode == 409) {
        return {
          'success': false,
          'statusCode': 409,
          'raw': decoded,
        };
      }
      return {
        'success': false,
        'statusCode': response.statusCode,
        'message': decoded is Map ? (decoded['detail']?.toString() ?? response.body) : response.body,
      };
    } catch (e) {
      print('Error putTeamAnswersBatch: $e');
      return {
        'success': false,
        'error': 'network',
        'message': e.toString(),
      };
    }
  }

  /// Get action_game_control data for a specific round_name
  /// Returns the last question_id entry for the given round_name
  static Future<Map<String, dynamic>?> getActionGameControlByRound(String gameNameSafe, String roundName) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null) {
        return null;
      }
      
      final encodedGameName = Uri.encodeComponent(gameNameSafe);
      final encodedRoundName = Uri.encodeComponent(roundName);
      
      final response = await http.get(
        Uri.parse('$_baseUrl/action-game-control/$encodedGameName/round/$encodedRoundName'),
        headers: {
          'Authorization': 'Bearer ${userData['access_token']}',
          'Content-Type': 'application/json',
        },
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true && data['data'] != null) {
          return data['data'] as Map<String, dynamic>;
        }
      }
      return null;
    } catch (e) {
      print('Error getting action_game_control data: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>> runActiveGame(int activeGameId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/admin/active-games/$activeGameId/run'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to run active game'
        };
      }
    } catch (e) {
      print('Error running active game: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> getPlayerActiveGames(int userId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/player/active-games/$userId'),
        headers: {'Content-Type': 'application/json'},
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'active_games': data['active_games']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to get active games'
        };
      }
    } catch (e) {
      print('Error getting player active games: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> selectBonusOption(int activeGameId, int userId, String optionName) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/player/select-bonus-option'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'active_game_id': activeGameId,
          'user_id': userId,
          'option_name': optionName,
        }),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to select bonus option'
        };
      }
    } catch (e) {
      print('Error selecting bonus option: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

  static Future<Map<String, dynamic>> selectDefaultOption(int activeGameId, int userId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/player/select-default-option'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'active_game_id': activeGameId,
          'user_id': userId,
        }),
      );
      
      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message']
        };
      } else {
        return {
          'success': false,
          'message': data['message'] ?? 'Failed to select default option'
        };
      }
    } catch (e) {
      print('Error selecting default option: $e');
      return {
        'success': false,
        'message': 'Connection failed: ${e.toString()}'
      };
    }
  }

}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _isSignUp = false;
  bool _databaseInitialized = false; // Add flag to prevent multiple calls
  
  // Version info
  String _appVersion = 'Loading...';
  String _buildNumber = '';
  /// Avoid showing the native update dialog on every periodic version check.
  bool _didPromptNativeUpdateThisSession = false;
  
  // Periodic update check timer
  Timer? _updateCheckTimer;
  
  // Fallback version - MUST match pubspec.yaml version
  // Update this whenever you update pubspec.yaml version
  // Current: version: 1.0.0+2
  static const String _fallbackVersion = '1.0.0';
  static const String _fallbackBuild = '2';

  @override
  void initState() {
    super.initState();
    // Re-read API URL as safety net (fixes web storage timing on refresh)
    ApiConfigService.getApiBaseUrl().then((apiUrl) {
      DatabaseService.setBaseUrl(apiUrl);
      if (mounted) {
        setState(() {});
        _maybeShowVersionUpgradeSnackBar();
      }
    });
    if (!_databaseInitialized) {
      // Don't await this - let it run in background
      _initializeDatabase();
    }
    
    // Load version info immediately
    _loadVersionInfo();
    
    // Check if this is an update reload
    _checkIfUpdateReload();
    
    // Reload version info after a delay to ensure new bundle is loaded (important after update)
    // This helps catch the new version after cache clear and reload
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        _loadVersionInfo(); // Reload version info
      }
    });
    
    // Delay update check to ensure page is fully loaded and any cached content is cleared
    // This is especially important after a hard reload
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _checkForUpdates();
      }
    });
    
    // Set up periodic update checks (every 5 minutes)
    // This ensures the app automatically detects new versions even if user doesn't refresh
    _updateCheckTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      if (mounted) {
        print('Periodic update check triggered');
        _loadVersionInfo(); // Reload version to catch any automatic updates
        _checkForUpdates(); // Check for new versions from backend
      }
    });
  }
  
  
  // Check if this page load was triggered by an update
  Future<void> _checkIfUpdateReload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final updatingApp = prefs.getBool('updating_app') ?? false;
      final updateStartedAt = prefs.getString('update_started_at');
      
      if (updatingApp && updateStartedAt != null) {
        print('This is an update reload, will verify version after short delay');
        
        // After a short delay, check if version updated and clear flags
        // Reduced delay for faster update verification
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            // Reload version info once (faster update check)
            await _loadVersionInfo();
            
            // Check if version now matches backend
            String currentVersion = '';
            
            // On web, use fallback directly (package_info_plus doesn't work on web)
            if (kIsWeb) {
              currentVersion = '$_fallbackVersion+$_fallbackBuild';
              print('Running on web - using fallback version: $currentVersion');
            } else {
              // Try to get version from PackageInfo (for mobile/native)
              // Reduced retries for faster update verification
              for (int i = 0; i < 3; i++) {
                try {
                  if (i > 0) {
                    await Future.delayed(Duration(milliseconds: 300)); // Shorter delay
                  }
                  final packageInfo = await PackageInfo.fromPlatform();
                  if (packageInfo.version.isNotEmpty && packageInfo.buildNumber.isNotEmpty) {
                    currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
                    print('Got version on attempt ${i + 1}: $currentVersion');
                    break;
                  }
                } catch (e) {
                  // Handle MissingPluginException
                  if (e.toString().contains('MissingPluginException') || 
                      e.toString().contains('no implementation found')) {
                    print('PackageInfo plugin not available, using fallback');
                    currentVersion = '$_fallbackVersion+$_fallbackBuild';
                    break;
                  }
                  print('Error getting version (attempt ${i + 1}): $e');
                }
              }
              
              // Fallback if all retries failed - must match pubspec.yaml
              if (currentVersion.isEmpty) {
                currentVersion = '$_fallbackVersion+$_fallbackBuild';
                print('Using fallback version for comparison: $currentVersion');
              }
            }
            
            try {
              final response = await http.get(
                Uri.parse('${DatabaseService.baseUrl}/app/version'),
              ).timeout(const Duration(seconds: 3));
              
              if (response.statusCode == 200) {
                final data = jsonDecode(response.body);
                final latestVersion = '${data['version']}+${data['build']}';
                
                if (currentVersion == latestVersion) {
                  print('Update successful! Version now matches: $currentVersion');
                  // Clear the update flag and last_update_version
                  await prefs.remove('updating_app');
                  await prefs.remove('update_started_at');
                  await prefs.remove('last_update_version');
                  
                  if (mounted) await _loadVersionInfo();
                  print('Update flags cleared - version matches');
                } else {
                  print('Version still doesn\'t match. Current: $currentVersion, Latest: $latestVersion');
                  print('This might mean the new version hasn\'t been deployed to the server yet.');
                  // Don't clear flags yet - wait a bit longer and check again
                  // But clear them after a shorter timeout to prevent infinite suppression
                  Future.delayed(const Duration(seconds: 10), () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('updating_app');
                    await prefs.remove('update_started_at');
                    print('Update flags cleared after timeout');
                  });
                }
              }
            } catch (e) {
              print('Error checking version after update: $e');
              // Clear flags after error to prevent infinite suppression
              Future.delayed(const Duration(seconds: 8), () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('updating_app');
                await prefs.remove('update_started_at');
                print('Update flags cleared after error timeout');
              });
            }
          } catch (e) {
            print('Error in update reload check: $e');
          }
        });
      }
    } catch (e) {
      print('Error checking update reload: $e');
    }
  }
  
  // Load app version info with retry logic for mobile
  Future<void> _loadVersionInfo({int retryCount = 0}) async {
    const maxRetries = 3;
    const retryDelay = Duration(milliseconds: 500);
    
    // On web, package_info_plus doesn't work reliably, use fallback directly
    if (kIsWeb) {
      print('Running on web - using fallback version: $_fallbackVersion+$_fallbackBuild');
      setState(() {
        _appVersion = _fallbackVersion;
        _buildNumber = _fallbackBuild;
      });
      return;
    }
    
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version;
      final build = packageInfo.buildNumber;
      
      print('PackageInfo (attempt ${retryCount + 1}) - version: "$version", build: "$build"');
      
      // Validate that we got valid version info
      if (version.isNotEmpty && build.isNotEmpty) {
        print('Setting version to: $version+$build');
        setState(() {
          _appVersion = version;
          _buildNumber = build;
        });
        return; // Success, exit
      } else {
        print('PackageInfo returned empty values - version: "$version", build: "$build"');
      }
    } catch (e) {
      // Handle MissingPluginException specifically (common on web)
      if (e.toString().contains('MissingPluginException') || 
          e.toString().contains('no implementation found')) {
        print('PackageInfo plugin not available (web or plugin issue), using fallback');
        setState(() {
          _appVersion = _fallbackVersion;
          _buildNumber = _fallbackBuild;
        });
        return;
      }
      print('Error loading version info (attempt ${retryCount + 1}): $e');
    }
    
    // If we got here, PackageInfo failed or returned empty
    // Retry if we haven't exceeded max retries
    if (retryCount < maxRetries) {
      print('Retrying version load in ${retryDelay.inMilliseconds}ms...');
      await Future.delayed(retryDelay);
      return _loadVersionInfo(retryCount: retryCount + 1);
    }
    
    // All retries failed - use fallback
    // IMPORTANT: This fallback MUST match pubspec.yaml version
    print('All retries failed, using fallback version: $_fallbackVersion+$_fallbackBuild');
    setState(() {
      _appVersion = _fallbackVersion;
      _buildNumber = _fallbackBuild;
    });
  }
  
  // Check for app updates
  Future<void> _checkForUpdates() async {
    try {
      // Skip update check if we just updated (within last 5 seconds)
      // This prevents the notification from reappearing immediately after update
      final prefs = await SharedPreferences.getInstance();
      final updateStartedAt = prefs.getString('update_started_at');
      if (updateStartedAt != null) {
        try {
          final updateTime = DateTime.parse(updateStartedAt);
          final timeSinceUpdate = DateTime.now().difference(updateTime);
          if (timeSinceUpdate.inSeconds < 5) {
            print('Skipping update check - update was just performed ${timeSinceUpdate.inSeconds}s ago');
            return; // Skip this check, we're still in the update process
          }
        } catch (e) {
          print('Error parsing update_started_at: $e');
        }
      }
      
      // Get current version with retry logic
      String currentVersion = ''; // Initialize to empty string
      int retryCount = 0;
      const maxRetries = 3;
      
      // On web, package_info_plus doesn't work reliably, use fallback directly
      if (kIsWeb) {
        currentVersion = '$_fallbackVersion+$_fallbackBuild';
        print('Running on web - using fallback version for comparison: $currentVersion');
      } else {
        // Try to get version from PackageInfo (for mobile/native)
        while (retryCount < maxRetries) {
          try {
            final packageInfo = await PackageInfo.fromPlatform();
            final version = packageInfo.version;
            final build = packageInfo.buildNumber;
            
            if (version.isNotEmpty && build.isNotEmpty) {
              currentVersion = '$version+$build';
              print('✓ PackageInfo success (attempt ${retryCount + 1}): version="$version", build="$build"');
              print('✓ Current app version: $currentVersion');
              break; // Success
            } else {
              print('✗ PackageInfo returned empty - version: "$version", build: "$build"');
            }
          } catch (e) {
            // Handle MissingPluginException specifically
            if (e.toString().contains('MissingPluginException') || 
                e.toString().contains('no implementation found')) {
              print('PackageInfo plugin not available, using fallback');
              currentVersion = '$_fallbackVersion+$_fallbackBuild';
              break;
            }
            print('Error getting package info (attempt ${retryCount + 1}): $e');
          }
          
          retryCount++;
          if (retryCount < maxRetries) {
            await Future.delayed(Duration(milliseconds: 500));
          }
        }
        
        // If all retries failed, use fallback matching pubspec.yaml
        if (currentVersion.isEmpty) {
          currentVersion = '$_fallbackVersion+$_fallbackBuild';
          print('Using fallback version: $currentVersion');
        }
      }
      
      // Check if we've already shown update notification for this version
      // (prefs was already declared above, reuse it)
      final lastUpdateVersion = prefs.getString('last_update_version');
      
      // Check backend for latest version
      try {
        final response = await http.get(
          Uri.parse('${DatabaseService.baseUrl}/app/version'),
        ).timeout(const Duration(seconds: 3));
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final latestVersion = data['version'] as String?;
          final latestBuild = data['build'] as String?;
          
          if (latestVersion != null && latestBuild != null) {
            final latestFullVersion = '$latestVersion+$latestBuild';
            print('=== UPDATE CHECK ===');
            print('Latest version from backend: $latestFullVersion');
            print('Current app version: $currentVersion');
            print('lastUpdateVersion (from SharedPreferences): $lastUpdateVersion');
            print('Versions match: ${latestFullVersion == currentVersion}');
            print('Comparison: "$latestFullVersion" != "$currentVersion" = ${latestFullVersion != currentVersion}');
            
            // Check if we're in the middle of an update process
            final updateStartedAt = prefs.getString('update_started_at');
            bool isUpdating = false;
            if (updateStartedAt != null) {
              try {
                final updateTime = DateTime.parse(updateStartedAt);
                final timeSinceUpdate = DateTime.now().difference(updateTime);
                if (timeSinceUpdate.inSeconds < 5) {
                  isUpdating = true;
                  print('Update in progress (${timeSinceUpdate.inSeconds}s ago) - suppressing notification');
                }
              } catch (e) {
                print('Error parsing update_started_at: $e');
              }
            }
            
            // Automatically update when versions are different
            // No notification popup - update happens silently in the background
            // BUT: Don't update if we're already in the middle of an update
            if (latestFullVersion != currentVersion && !isUpdating) {
              print('>>> UPDATE AVAILABLE! <<<');
              print('Latest: $latestFullVersion, Current: $currentVersion');
              
              await prefs.setString('last_update_version', latestFullVersion);
              
              if (kIsWeb) {
                print('Web: auto-updating silently (cache clear + reload)...');
                await _handleUpdateSilently();
              } else if (!_didPromptNativeUpdateThisSession) {
                _didPromptNativeUpdateThisSession = true;
                print('Native: showing update instructions (once this session)...');
                await _handleUpdate();
              }
            } else if (latestFullVersion == currentVersion) {
              // Version matches - we're up to date!
              print('>>> VERSION IS UP TO DATE <<<');
              print('Current: $currentVersion matches Latest: $latestFullVersion');
              print('No update notification needed (versions are the same).');
              
              // Clear any stored update notification flag
              await prefs.remove('last_update_version');
              
              _loadVersionInfo();
            } else {
              print('>>> UNEXPECTED STATE <<<');
              print('Latest: $latestFullVersion, Current: $currentVersion');
              print('Neither condition matched - this should not happen!');
            }
          }
        }
      } catch (e) {
        // Backend endpoint might not exist yet, that's okay
        print('Update check failed (endpoint may not exist): $e');
      }
    } catch (e) {
      print('Error checking for updates: $e');
    }
  }
  
  // Handle app update silently - no UI, automatic update
  Future<void> _handleUpdateSilently() async {
    try {
      print('Starting silent automatic update...');
      
      // Set update flags
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('updating_app', true);
      await prefs.setString('update_started_at', DateTime.now().toIso8601String());
      
      // For PWA/web, delete all caches and reload immediately
      if (kIsWeb) {
        await _deleteAllCachesAndReload();
      } else {
        // For native mobile apps, we can't auto-update, but we'll try to reload
        // The app will check for updates on next launch
        print('Native app detected - update will be applied on next app restart');
      }
    } catch (e) {
      print('Error handling silent update: $e');
    }
  }
  
  // Handle app update - simple approach: delete caches and reload
  Future<void> _handleUpdate() async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Updating app... Clearing cache and reloading...'),
            duration: Duration(seconds: 2),
          ),
        );
        
        // Clear the update notification flag so we can check again after reload
        final prefs = await SharedPreferences.getInstance();
        // Don't remove last_update_version here - we'll check after reload
        // Instead, set a flag that we're about to update
        await prefs.setBool('updating_app', true);
        await prefs.setString('update_started_at', DateTime.now().toIso8601String());
        
        // For PWA/web, delete all caches and reload
        if (kIsWeb) {
          await _deleteAllCachesAndReload();
        } else {
          // For mobile apps, show instructions
          if (mounted) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Update Instructions'),
                content: const Text(
                  'To update the app:\n\n'
                  '1. Close the app completely\n'
                  '2. Reopen the app from your app launcher\n\n'
                  'The app will automatically download the latest version.',
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
        }
      }
    } catch (e) {
      print('Error handling update: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating app: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
  
  // Aggressive cache deletion and reload for mobile PWA updates
  Future<void> _deleteAllCachesAndReload() async {
    try {
      print('Starting aggressive cache deletion and reload...');
      
      // Step 1: Clear all storage (localStorage, sessionStorage)
      try {
        html.window.localStorage.clear();
        html.window.sessionStorage.clear();
        print('Local and session storage cleared');
      } catch (e) {
        print('Error clearing storage: $e');
      }
      
      // Step 2: Delete all caches FIRST (before unregistering service worker)
      final caches = html.window.caches;
      if (caches != null) {
        try {
          final cacheNames = await caches.keys();
          print('Found ${cacheNames.length} caches to delete');
          for (var cacheName in cacheNames) {
            await caches.delete(cacheName);
            print('Cache deleted: $cacheName');
          }
          // Wait a bit to ensure cache deletion completes
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          print('Error deleting caches: $e');
        }
      }
      
      // Step 3: Unregister all service workers
      final serviceWorker = html.window.navigator.serviceWorker;
      if (serviceWorker != null) {
        try {
          final registrations = await serviceWorker.getRegistrations();
          print('Found ${registrations.length} service workers to unregister');
          for (var registration in registrations) {
            // Send message to skip waiting first
            if (registration.installing != null) {
              registration.installing!.postMessage({'type': 'SKIP_WAITING'});
            }
            if (registration.waiting != null) {
              registration.waiting!.postMessage({'type': 'SKIP_WAITING'});
            }
            if (registration.active != null) {
              registration.active!.postMessage({'type': 'SKIP_WAITING'});
            }
            // Now unregister
            final unregistered = await registration.unregister();
            print('Service worker unregistered: $unregistered');
          }
          // Wait for unregistration to complete
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          print('Error unregistering service workers: $e');
        }
      }
      
      // Step 4: Force navigation to base URL with cache-busting parameters
      print('Forcing page reload with cache bypass...');
      final origin = html.window.location.origin;
      final pathname = html.window.location.pathname;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final random = (timestamp % 100000).toString();
      
      // Navigate to base URL with multiple cache-busting parameters
      final reloadUrl = '$origin$pathname?_update=$timestamp&_cb=$random&_nocache=true';
      
      print('Navigating to: $reloadUrl');
      
      // Use location.replace to avoid history entry
      html.window.location.replace(reloadUrl);
      
      // If that doesn't work, try location.href after a delay
      Future.delayed(const Duration(milliseconds: 1000), () {
        try {
          print('Fallback: forcing reload via location.href');
          html.window.location.href = reloadUrl;
        } catch (e) {
          print('Error with location.href fallback: $e');
          // Last resort: regular reload
          try {
            html.window.location.reload();
          } catch (e2) {
            print('Error with final reload: $e2');
          }
        }
      });
    } catch (e) {
      print('Error in deleteAllCachesAndReload: $e');
      // Last resort: try regular reload
      try {
        html.window.location.reload();
      } catch (e2) {
        print('Error with final reload attempt: $e2');
      }
    }
  }

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // Initialize database and create tables
  Future<void> _initializeDatabase() async {
    if (_databaseInitialized) return; // Prevent multiple calls
    
    try {
      // Add timeout to prevent hanging
      await DatabaseService.createUsersTable().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          print('Database initialization timed out - backend may not be running');
        },
      );
      _databaseInitialized = true; // Set flag after successful call
      print('Database initialized request successfully');
    } catch (e) {
      print('Database initialization request failed: $e');
      // Don't set _databaseInitialized to true on error
      // This allows retry on next login attempt
    }
  }

  // Show database configuration information
  void _maybeShowVersionUpgradeSnackBar() {
    if (ApiConfigService.wasConfigVersionUpgraded && mounted) {
      ApiConfigService.clearConfigVersionUpgradedFlag();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'New version installed. Check server URL in Database Info if something doesn\'t work.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  void _showDatabaseInfo() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;
    final scrollController = ScrollController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Authentication Info',
          style: TextStyle(fontSize: isSmallScreen ? 18 : 20),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
            minHeight: 200,
          ),
          child: Scrollbar(
            controller: scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
            controller: scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current API Settings:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: isSmallScreen ? 14 : 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'API URL: ${DatabaseService.baseUrl}',
                style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
              ),
              const SizedBox(height: 16),
              Text(
                'Switch Game Server:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: isSmallScreen ? 14 : 16,
                ),
              ),
              const SizedBox(height: 8),
              _EnvSelector(
                current: DatabaseService.baseUrl,
                scrollController: scrollController,
                onChanged: (value) async {
                  DatabaseService.setBaseUrl(value);
                  await ApiConfigService.setApiBaseUrl(value);
                  if (mounted) setState(() {});
                  final isCustomUrl = !value.contains('localhost:8000') &&
                      !value.contains('pythonanywhere.com');
                  if (isCustomUrl && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
              const SizedBox(height: 16),

              Text(
                'Sign Up Example:', 
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: isSmallScreen ? 14 : 16,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                '1) Open Sign Up\n'
                '2) Full Name: John Smith\n'
                '3) Email: john.smith@example.com\n'
                '4) Password: StrongPass123\n'
                '5) Confirm Password: StrongPass123\n'
                '6) Tap Sign Up',
                style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
              ),
              const SizedBox(height: 16),
              Text(
                'Tip: For local testing, ensure your FastAPI server is reachable from this device.',
                style: TextStyle(
                  fontSize: isSmallScreen ? 10 : 12, 
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            ),
          ),
        ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
            ),
          ),
        ],
      ),
    );
  }

  // Handle login
  Future<void> _handleLogin() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final result = await DatabaseService.checkCredentials(
          _emailController.text.trim(),
          _passwordController.text,
        );

        if (result['success']) {
          // Clear any previous team name before saving new user data
          await UserDataService.clearTeamName();
          
          // Save user data to local storage (including session token)
          final userDataToSave = <String, dynamic>{
            ...result['user'],
            'access_token': result['access_token'],
            'session_token': result['session_token'],
          };
          await UserDataService.saveUserData(userDataToSave);
          
          // Initialize timer status to Idle on login
          await initializeTimerStatus();
          
          // If user has a team, fetch and save team name
          final userData = result['user'];
          if (userData['playing_in_team_id'] != null && userData['playing_in_team_id'].toString().isNotEmpty) {
            try {
              final teamResult = await DatabaseService.getTeamName(userData['playing_in_team_id'].toString());
              if (teamResult['success'] == true && teamResult['team_name'] != null) {
                await UserDataService.saveTeamName(teamResult['team_name']);
                print('Team name saved after login: ${teamResult['team_name']}');
              }
            } catch (e) {
              print('Error fetching team name after login: $e');
            }
          }
          
          // Show success message
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Welcome back, ${result['user']['name']}!'),
              backgroundColor: Colors.green,
            ),
          );
          
          // Navigate to main page immediately (data is already saved)
          if (mounted) {
            Navigator.pushReplacementNamed(context, '/main');
          }
        } else {
          final msg = result['message'] ?? 'Login failed';
          final isConnectionError = msg.toString().contains('Connection') || msg.toString().contains('Failed to fetch');
          final hint = (kIsWeb && DatabaseService.baseUrl.contains('localhost') && isConnectionError)
              ? '\n\nOn mobile: use Database Info to set your server IP (e.g. http://192.168.0.1:8000/api).'
              : '';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$msg$hint'), duration: const Duration(seconds: 8)),
          );
        }
      } catch (e) {
        final errMsg = e.toString();
        final isConnectionError = errMsg.contains('Connection') || errMsg.contains('Failed to fetch');
        final hint = (kIsWeb && DatabaseService.baseUrl.contains('localhost') && isConnectionError)
            ? '\n\nOn mobile: use Database Info to set your server IP (e.g. http://192.168.0.1:8000/api).'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $errMsg$hint'), duration: const Duration(seconds: 8)),
        );
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Handle sign up
  Future<void> _handleSignUp() async {
    print('_handleSignUp called, _isSignUp = $_isSignUp');
    if (_formKey.currentState!.validate()) {
      print('Form validation passed, proceeding with registration...');
      setState(() {
        _isLoading = true;
      });

      try {
        final result = await DatabaseService.registerUser(
          _emailController.text.trim(),
          _passwordController.text,
          _nameController.text.trim(),
        );

        if (result['success']) {
          print('Registration successful, switching to login mode...');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Account created successfully! Please sign in with your credentials.'),
              backgroundColor: Colors.green,
            ),
          );
          
          // Switch back to login mode and clear form
          setState(() {
            print('Before state change: _isSignUp = $_isSignUp');
            _isSignUp = false;
            _isLoading = false;
            _emailController.clear();
            _passwordController.clear();
            _nameController.clear();
            _confirmPasswordController.clear();
            print('After state change: _isSignUp = $_isSignUp');
          });
          
          // Force a rebuild after a short delay to ensure state change takes effect
          Future.delayed(Duration(milliseconds: 100), () {
            if (mounted) {
              setState(() {
                print('Forced rebuild: _isSignUp = $_isSignUp');
              });
            }
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result['message'] ?? 'Registration failed')),
          );
          setState(() {
            _isLoading = false;
          });
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
        setState(() {
          _isLoading = false;
        });
      }
    } else {
      print('Form validation failed, not proceeding with registration');
    }
  }

  // Toggle between login and sign up modes
  void _toggleMode() {
    setState(() {
      _isSignUp = !_isSignUp;
      _emailController.clear();
      _passwordController.clear();
      _nameController.clear();
      _confirmPasswordController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final isSmallScreen = screenWidth < 600;
    final isVerySmallScreen = screenWidth < 400;
    
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.blue, Colors.purple],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Left icon (LaLaFa)
              Positioned(
                left: isVerySmallScreen ? 8 : isSmallScreen ? 16 : 32,
                top: isVerySmallScreen ? 20 : 40,
                child: Image.asset(
                  'images/right.png',
                  width: isVerySmallScreen ? 40 : isSmallScreen ? 160 : 180,
                  height: isVerySmallScreen ? 40 : isSmallScreen ? 160 : 180,
                  fit: BoxFit.contain,
                ),
              ),
              // Right icon (SilaMisli)
              Positioned(
                right: isVerySmallScreen ? 8 : isSmallScreen ? 16 : 32,
                top: isVerySmallScreen ? 20 : 40,
                child: Image.asset(
                  'images/left.png',
                  width: isVerySmallScreen ? 40 : isSmallScreen ? 160 : 180,
                  height: isVerySmallScreen ? 40 : isSmallScreen ? 160 : 180,
                  fit: BoxFit.contain,
                ),
              ),
              // Main content
              Center(
                child: SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.only(
                    left: isVerySmallScreen ? 16 : isSmallScreen ? 24 : 32,
                    right: isVerySmallScreen ? 16 : isSmallScreen ? 24 : 32,
                    top: isVerySmallScreen ? 16 : 24,
                    bottom: keyboardHeight > 0 ? keyboardHeight + 16 : (isVerySmallScreen ? 16 : 24),
                  ),
                  child: Card(
              margin: EdgeInsets.all(isVerySmallScreen ? 8 : isSmallScreen ? 16 : 32),
              elevation: 8,
              child: Padding(
                padding: EdgeInsets.all(isVerySmallScreen ? 16 : isSmallScreen ? 24 : 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isSmallScreen ? double.infinity : 400,
                    minWidth: isVerySmallScreen ? 280 : 320,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      Icon(
                        Icons.lock_outline,
                        size: isVerySmallScreen ? 48 : isSmallScreen ? 56 : 64,
                        color: Colors.blue,
                      ),
                      SizedBox(height: isVerySmallScreen ? 16 : 24),
                      Text(
                        _isSignUp ? 'Create Account' : 'Welcome Back',
                        style: TextStyle(
                          fontSize: isVerySmallScreen ? 22 : isSmallScreen ? 26 : 28,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: isVerySmallScreen ? 6 : 8),
                      Text(
                        _isSignUp ? 'Sign up for a new account' : 'Sign in to your account',
                        style: TextStyle(
                          fontSize: isVerySmallScreen ? 14 : 16,
                          color: Colors.grey,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: isVerySmallScreen ? 24 : 32),
                      // Name field (only for sign up)
                      if (_isSignUp) ...[
                        TextFormField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: 'Full Name',
                            prefixIcon: Icon(Icons.person, size: isVerySmallScreen ? 20 : 24),
                            border: const OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: isVerySmallScreen ? 12 : 16,
                              vertical: isVerySmallScreen ? 12 : 16,
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter your full name';
                            }
                            if (value.length < 2) {
                              return 'Name must be at least 2 characters';
                            }
                            return null;
                          },
                        ),
                        SizedBox(height: isVerySmallScreen ? 12 : 16),
                      ],
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email, size: isVerySmallScreen ? 20 : 24),
                          border: const OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: isVerySmallScreen ? 12 : 16,
                            vertical: isVerySmallScreen ? 12 : 16,
                          ),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter your email';
                          }
                          if (!value.contains('@')) {
                            return 'Please enter a valid email';
                          }
                          return null;
                        },
                      ),
                      SizedBox(height: isVerySmallScreen ? 12 : 16),
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock, size: isVerySmallScreen ? 20 : 24),
                          border: const OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: isVerySmallScreen ? 12 : 16,
                            vertical: isVerySmallScreen ? 12 : 16,
                          ),
                        ),
                        obscureText: true,
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter your password';
                          }
                          if (value.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      // Confirm password field (only for sign up)
                      if (_isSignUp) ...[
                        SizedBox(height: isVerySmallScreen ? 12 : 16),
                        TextFormField(
                          controller: _confirmPasswordController,
                          decoration: InputDecoration(
                            labelText: 'Confirm Password',
                            prefixIcon: Icon(Icons.lock_outline, size: isVerySmallScreen ? 20 : 24),
                            border: const OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: isVerySmallScreen ? 12 : 16,
                              vertical: isVerySmallScreen ? 12 : 16,
                            ),
                          ),
                          obscureText: true,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please confirm your password';
                            }
                            if (value != _passwordController.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),
                      ],
                      SizedBox(height: isVerySmallScreen ? 20 : 24),
                      SizedBox(
                        width: double.infinity,
                        height: isVerySmallScreen ? 44 : 48,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : (_isSignUp ? _handleSignUp : _handleLogin),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(isVerySmallScreen ? 6 : 8),
                            ),
                          ),
                          child: _isLoading
                              ? SizedBox(
                                  width: isVerySmallScreen ? 20 : 24,
                                  height: isVerySmallScreen ? 20 : 24,
                                  child: const CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _isSignUp ? 'Sign Up' : 'Sign In',
                                  style: TextStyle(
                                    fontSize: isVerySmallScreen ? 14 : 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                      SizedBox(height: isVerySmallScreen ? 12 : 16),
                      if (!_isSignUp) ...[
                        TextButton(
                          onPressed: () {
                            // Handle forgot password
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Forgot password feature coming soon')),
                            );
                          },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              horizontal: isVerySmallScreen ? 8 : 12,
                              vertical: isVerySmallScreen ? 4 : 8,
                            ),
                          ),
                          child: Text(
                            'Forgot Password?',
                            style: TextStyle(
                              fontSize: isVerySmallScreen ? 12 : 14,
                            ),
                          ),
                        ),
                        SizedBox(height: isVerySmallScreen ? 6 : 8),
                      ],
                      TextButton(
                        onPressed: _toggleMode,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            horizontal: isVerySmallScreen ? 8 : 12,
                            vertical: isVerySmallScreen ? 4 : 8,
                          ),
                        ),
                        child: Text(
                          _isSignUp 
                              ? 'Already have an account? Sign In'
                              : 'Don\'t have an account? Sign Up',
                          style: TextStyle(
                            fontSize: isVerySmallScreen ? 12 : 14,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      SizedBox(height: isVerySmallScreen ? 6 : 8),
                      TextButton(
                        onPressed: () {
                          _showDatabaseInfo();
                        },
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            horizontal: isVerySmallScreen ? 8 : 12,
                            vertical: isVerySmallScreen ? 4 : 8,
                          ),
                        ),
                        child: Text(
                          'Database Info',
                          style: TextStyle(
                            fontSize: isVerySmallScreen ? 12 : 14,
                          ),
                        ),
                      ),
                      // Version display at bottom
                      SizedBox(height: isVerySmallScreen ? 12 : 16),
                      Padding(
                        padding: EdgeInsets.only(top: isVerySmallScreen ? 8 : 12),
                        child: Text(
                          'Version $_appVersion+$_buildNumber',
                          style: TextStyle(
                            fontSize: isVerySmallScreen ? 10 : 12,
                            color: Colors.grey[600],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ),
          ),
          ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EnvSelector extends StatefulWidget {
  final String current;
  final ScrollController scrollController;
  final ValueChanged<String> onChanged;

  const _EnvSelector({
    required this.current,
    required this.scrollController,
    required this.onChanged,
  });

  @override
  State<_EnvSelector> createState() => _EnvSelectorState();
}

class _EnvSelectorState extends State<_EnvSelector> {
  late String _selected;
  final _customController = TextEditingController();
  final _customFieldKey = GlobalKey();
  final FocusNode _customFocusNode = FocusNode();
  final FocusNode _localFocusNode = FocusNode();
  final FocusNode _cloudFocusNode = FocusNode();
  final FocusNode _customRadioFocusNode = FocusNode();
  bool _showCustomExample = false;

  @override
  void initState() {
    super.initState();
    _selected = _inferPreset(widget.current);
    _customController.text = widget.current;
    _showCustomExample = _selected == 'custom';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusSelectedOption();
    });
  }

  @override
  void didUpdateWidget(_EnvSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.current != oldWidget.current) {
      _selected = _inferPreset(widget.current);
      _customController.text = widget.current;
      _showCustomExample = _selected == 'custom';
      // Defer setState to next frame to avoid "RenderBox was not laid out" during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _customController.dispose();
    _customFocusNode.dispose();
    _localFocusNode.dispose();
    _cloudFocusNode.dispose();
    _customRadioFocusNode.dispose();
    super.dispose();
  }

  String _inferPreset(String url) {
    if (url.contains('localhost:8000')) return 'local';
    if (url.contains('pythonanywhere.com')) return 'cloud';
    return 'custom';
  }

  void _apply(String value) {
    widget.onChanged(value);
    setState(() {
      _selected = _inferPreset(value);
      _customController.text = value;
      _showCustomExample = _selected == 'custom';
    });
    _focusSelectedOption();
  }

  void _focusSelectedOption() {
    switch (_selected) {
      case 'local':
        _localFocusNode.requestFocus();
        break;
      case 'cloud':
        _cloudFocusNode.requestFocus();
        break;
      case 'custom':
      default:
        _focusCustomField();
        break;
    }
  }

  void _focusCustomField() {
    void doFocus() {
      if (!mounted) return;
      _customRadioFocusNode.unfocus();
      _customFocusNode.requestFocus();
      _customController.selection = const TextSelection.collapsed(offset: 0);
    }
    void scheduleFocus() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        doFocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          doFocus();
          Future.delayed(const Duration(milliseconds: 150), doFocus);
          Future.delayed(const Duration(milliseconds: 400), doFocus);
        });
      });
    }
    scheduleFocus();
  }

  Widget _buildCustomField(bool isSmallScreen) {
    return RepaintBoundary(
      key: _customFieldKey,
      child: TextField(
        controller: _customController,
        focusNode: _customFocusNode,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          hintText: isSmallScreen
              ? 'e.g. http://localhost:8000/api'
              : 'e.g. http://DESKTOP-638BFEB:8000/api or http://192.168.2.14:8000/api',
          helperText: _showCustomExample
              ? (isSmallScreen
                  ? 'Example: http://localhost:8000/api'
                  : 'Example: http://DESKTOP-638BFEB:8000/api')
              : null,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(
            horizontal: isSmallScreen ? 8 : 12,
            vertical: isSmallScreen ? 8 : 12,
          ),
        ),
        style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
        onChanged: (_) {
          if (_showCustomExample) {
            setState(() {
              _showCustomExample = false;
            });
          }
        },
      ),
    );
  }

  Widget _buildApplyButton(bool isSmallScreen) {
    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton(
        onPressed: () {
          final value = _customController.text.trim();
          if (value.isNotEmpty) {
            _apply(value);
          }
        },
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: isSmallScreen ? 12 : 16,
            vertical: isSmallScreen ? 8 : 12,
          ),
        ),
        child: Text(
          'Apply',
          style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          focusNode: _localFocusNode,
          title: Text(
            'Local PC (example: DESKTOP-638BFEB / 192.168.2.14)',
            style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
          ),
          subtitle: Text(
            'http://localhost:8000/api',
            style: TextStyle(fontSize: isSmallScreen ? 10 : 12),
          ),
          value: 'local',
          groupValue: _selected,
          onChanged: (v) {
            if (v == null) return;
            _apply('http://localhost:8000/api');
          },
        ),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          focusNode: _cloudFocusNode,
          title: Text(
            'Cloud (PythonAnywhere)',
            style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
          ),
          subtitle: Text(
            'https://<your-username>.pythonanywhere.com/api',
            style: TextStyle(fontSize: isSmallScreen ? 10 : 12),
          ),
          value: 'cloud',
          groupValue: _selected,
          onChanged: (v) {
            if (v == null) return;
            _apply('https://<your-username>.pythonanywhere.com/api');
          },
        ),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          focusNode: _customRadioFocusNode,
          title: Text(
            'Custom',
            style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
          ),
          value: 'custom',
          groupValue: _selected,
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _selected = 'custom';
              _showCustomExample = true;
            });
            _focusCustomField();
          },
        ),
        if (_selected == 'custom') ...[
          _buildCustomField(isSmallScreen),
          const SizedBox(height: 8),
          _buildApplyButton(isSmallScreen),
        ],
      ],
    );
  }

  // Note: _EnvSelectorState contains only selector UI; it intentionally does not
  // access parent state like form controllers or loading flags.
}
