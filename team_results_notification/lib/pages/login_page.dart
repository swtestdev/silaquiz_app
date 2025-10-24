import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/user_data_service.dart';

// API service class for authentication operations
class DatabaseService {
  // FastAPI backend endpoint (mutable at runtime) 
  // static String _baseUrl = 'http://localhost:8000/api';
  // static String _baseUrl = 'http://192.168.2.14:8000/api';
  static String _baseUrl = 'http://DESKTOP-638BFEB:8000/api';

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
  static Future<Map<String, dynamic>> sendEchoCall(bool appVisible) async {
    try {
      final userData = await UserDataService.getUserData();
      if (userData == null || userData['access_token'] == null || userData['session_token'] == null) {
        return {
          'success': false,
          'message': 'No active session found',
          'should_logout': true
        };
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/auth/echo'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${userData['access_token']}',
        },
        body: jsonEncode({
          'session_token': userData['session_token'],
          'app_visible': appVisible,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        return {
          'success': responseData['success'] ?? false,
          'message': responseData['message'] ?? 'Unknown response',
          'should_logout': responseData['should_logout'] ?? false,
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
      );
      
      if (response.statusCode == 200) {
        print('Database initialized admin successfully');
      } else {
        print('Database initialization admin failed: ${response.body}');
      }
    } catch (e) {
      print('Database initialization admin error: $e');
    }
  }

  // Update writer user status
  static Future<Map<String, dynamic>> updateWriterUserStatus(String userId, bool isActive) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/users/$userId/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'writer': isActive}),
      );

      final data = jsonDecode(response.body);
      
      if (response.statusCode == 200 && data['success'] == true) {
        return {'success': true, 'user': data['user']};
      } else {
        return {
          'success': false, 
          'message': data['message'] ?? 'Failed to update status'
        };
      }
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
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

  @override
  void initState() {
    super.initState();
    if (!_databaseInitialized) {
      _initializeDatabase();
    }
  }

  @override
  void dispose() {
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
      await DatabaseService.createUsersTable();
      _databaseInitialized = true; // Set flag after successful call
      print('Database initialized request successfully');
    } catch (e) {
      print('Database initialization request failed: $e');
    }
  }

  // Show database configuration information
  void _showDatabaseInfo() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Authentication Info',
          style: TextStyle(fontSize: isSmallScreen ? 18 : 20),
        ),
        content: SingleChildScrollView(
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
                'Switch Environment:', 
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: isSmallScreen ? 14 : 16,
                ),
              ),
              const SizedBox(height: 8),
              _EnvSelector(
                current: DatabaseService.baseUrl,
                onChanged: (value) {
                  setState(() {
                    DatabaseService.setBaseUrl(value);
                  });
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
          
          // Add a small delay to ensure data is saved before navigation
          await Future.delayed(const Duration(milliseconds: 500));
          
          // Navigate to main page
          Navigator.pushReplacementNamed(context, '/main');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result['message'] ?? 'Login failed')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
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
    final screenHeight = MediaQuery.of(context).size.height;
    final isSmallScreen = screenWidth < 600;
    final isVerySmallScreen = screenWidth < 400;
    
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.blue, Colors.purple],
          ),
        ),
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
            padding: EdgeInsets.symmetric(
              horizontal: isVerySmallScreen ? 16 : isSmallScreen ? 24 : 32,
              vertical: isVerySmallScreen ? 16 : 24,
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
    );
  }
}

class _EnvSelector extends StatefulWidget {
  final String current;
  final ValueChanged<String> onChanged;

  const _EnvSelector({
    required this.current,
    required this.onChanged,
  });

  @override
  State<_EnvSelector> createState() => _EnvSelectorState();
}

class _EnvSelectorState extends State<_EnvSelector> {
  late String _selected;
  final _customController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = _inferPreset(widget.current);
    _customController.text = widget.current;
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
    });
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
          title: Text(
            'Custom',
            style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
          ),
          value: 'custom',
          groupValue: _selected,
          onChanged: (v) {
            if (v == null) return;
            setState(() { _selected = 'custom'; });
          },
        ),
        if (_selected == 'custom') ...[
          TextField(
            controller: _customController,
            decoration: InputDecoration(
              hintText: isSmallScreen 
                  ? 'e.g. http://localhost:8000/api'
                  : 'e.g. http://DESKTOP-638BFEB:8000/api or http://192.168.2.14:8000/api',
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: isSmallScreen ? 8 : 12,
                vertical: isSmallScreen ? 8 : 12,
              ),
            ),
            style: TextStyle(fontSize: isSmallScreen ? 12 : 14),
          ),
          const SizedBox(height: 8),
          Align(
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
          ),
        ],
      ],
    );
  }

  // Note: _EnvSelectorState contains only selector UI; it intentionally does not
  // access parent state like form controllers or loading flags.
}
