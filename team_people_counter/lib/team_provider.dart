import 'package:flutter/material.dart';
import 'team_model.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class TeamProvider extends ChangeNotifier {
  final List<Team> _teams = [];
  static const String _storageKey = 'teams_data';

  List<Team> get teams => List.unmodifiable(_teams);

  TeamProvider() {
    _loadTeams();
  }

  Future<void> _loadTeams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final teamsJson = prefs.getString(_storageKey);
      if (teamsJson != null) {
        final List<dynamic> teamsList = json.decode(teamsJson);
        _teams.clear();
        _teams.addAll(teamsList.map((json) => Team.fromJson(json)));
        notifyListeners();
      }
    } catch (e) {
      print('Error loading teams: $e');
    }
  }

  Future<void> _saveTeams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final teamsJson = json.encode(_teams.map((team) => team.toJson()).toList());
      await prefs.setString(_storageKey, teamsJson);
    } catch (e) {
      print('Error saving teams: $e');
    }
  }

  void addTeam(Team team) {
    _teams.add(team);
    notifyListeners();
    _saveTeams();
  }

  void updateTeam(int index, Team team) {
    _teams[index] = team;
    notifyListeners();
    _saveTeams();
  }

  void removeTeam(int index) {
    _teams.removeAt(index);
    notifyListeners();
    _saveTeams();
  }

  void incrementCount(int index) {
    _teams[index].count++;
    notifyListeners();
    _saveTeams();
  }

  void decrementCount(int index) {
    if (_teams[index].count > 0) {
      _teams[index].count--;
      notifyListeners();
      _saveTeams();
    }
  }

  int findTeamIndexByQr(String qrCode) {
    return _teams.indexWhere((team) => team.qrCode == qrCode);
  }

  bool hasTeamWithName(String name) {
    return _teams.any((team) => team.name.toLowerCase() == name.toLowerCase());
  }

  bool hasTeamWithQr(String qrCode) {
    return _teams.any((team) => team.qrCode == qrCode);
  }

  Team? findTeamByQr(String qrCode) {
    final index = findTeamIndexByQr(qrCode);
    if (index != -1) {
      return _teams[index];
    }
    return null;
  }

  void clearAll() {
    _teams.clear();
    notifyListeners();
    _saveTeams();
  }
} 