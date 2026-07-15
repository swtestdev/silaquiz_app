import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class UserDataService {
  static const String _userDataKey = 'user_data';
  static const String _isLoggedInKey = 'is_logged_in';
  static const String _loginTimeKey = 'login_time';
  static const String _teamNameKey = 'team_name';

  // Save user data after successful login
  static Future<void> saveUserData(Map<String, dynamic> userData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      print('UserDataService - Saving user data: $userData');
      
      // Save user data as JSON string
      final jsonString = jsonEncode(userData);
      print('UserDataService - JSON string: $jsonString');
      
      await prefs.setString(_userDataKey, jsonString);
      
      // Mark user as logged in
      await prefs.setBool(_isLoggedInKey, true);
      
      // Save login timestamp
      await prefs.setString(_loginTimeKey, DateTime.now().toIso8601String());
      
      print('User data saved successfully');
    } catch (e) {
      print('Error saving user data: $e');
    }
  }

  // Get saved user data
  static Future<Map<String, dynamic>?> getUserData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userDataString = prefs.getString(_userDataKey);
      
      print('UserDataService - Retrieved user data string: $userDataString');
      
      if (userDataString != null) {
        final userData = jsonDecode(userDataString) as Map<String, dynamic>;
        print('UserDataService - Parsed user data: $userData');
        return userData;
      }
      print('UserDataService - No user data string found');
      return null;
    } catch (e) {
      print('Error getting user data: $e');
      return null;
    }
  }

  // Check if user is logged in
  static Future<bool> isLoggedIn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn = prefs.getBool(_isLoggedInKey) ?? false;
      print('UserDataService.isLoggedIn() - result: $isLoggedIn');
      return isLoggedIn;
    } catch (e) {
      print('Error checking login status: $e');
      return false;
    }
  }

  // Get login time
  static Future<DateTime?> getLoginTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loginTimeString = prefs.getString(_loginTimeKey);
      
      if (loginTimeString != null) {
        return DateTime.parse(loginTimeString);
      }
      return null;
    } catch (e) {
      print('Error getting login time: $e');
      return null;
    }
  }

  /// Update cached writer flag after toggle or ECHO writer_status sync.
  static Future<void> setWriterFlag(bool isWriter) async {
    try {
      final userData = await getUserData();
      if (userData == null) return;
      userData['writer'] = isWriter;
      await saveUserData(userData);
    } catch (e) {
      print('Error updating writer flag: $e');
    }
  }

  // Clear user data (logout)
  static Future<void> clearUserData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      await prefs.remove(_userDataKey);
      await prefs.remove(_isLoggedInKey);
      await prefs.remove(_loginTimeKey);
      
      print('User data cleared successfully');
    } catch (e) {
      print('Error clearing user data: $e');
    }
  }

  // Get user session info
  static Future<Map<String, dynamic>> getSessionInfo() async {
    try {
      final userData = await getUserData();
      final loggedInStatus = await isLoggedIn();
      final loginTime = await getLoginTime();
      
      return {
        'userData': userData,
        'isLoggedIn': loggedInStatus,
        'loginTime': loginTime?.toIso8601String(),
        'sessionDuration': loginTime != null 
            ? DateTime.now().difference(loginTime).inMinutes 
            : 0,
      };
    } catch (e) {
      print('Error getting session info: $e');
      return {
        'userData': null,
        'isLoggedIn': false,
        'loginTime': null,
        'sessionDuration': 0,
      };
    }
  }

  // Save team name
  static Future<void> saveTeamName(String teamName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_teamNameKey, teamName);
      print('Team name saved successfully: $teamName');
    } catch (e) {
      print('Error saving team name: $e');
    }
  }

  // Get team name
  static Future<String?> getTeamName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_teamNameKey);
    } catch (e) {
      print('Error getting team name: $e');
      return null;
    }
  }

  // Clear team name
  static Future<void> clearTeamName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_teamNameKey);
      print('Team name cleared successfully');
    } catch (e) {
      print('Error clearing team name: $e');
    }
  }
}
