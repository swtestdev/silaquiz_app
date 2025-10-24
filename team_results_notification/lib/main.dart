import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/splash_page.dart';
import 'pages/login_page.dart';
import 'pages/main_page.dart';
import 'pages/question_page.dart';
import 'pages/summary_page.dart';
import 'pages/admin/team_management_page.dart';
import 'pages/admin/teams_list_page.dart';
import 'pages/admin/user_management_page.dart';
import 'pages/admin/game_management_page.dart';
import 'pages/admin/active_games_page.dart';
import 'pages/admin/analytics_dashboard_page.dart';
import 'services/user_data_service.dart';

void main() {
  runApp(const PWAApp());
}

class PWAApp extends StatelessWidget {
  const PWAApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quiz Сила Мысли',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      initialRoute: '/splash',
      routes: {
        '/splash': (context) => const SplashPage(),
        '/login': (context) => const LoginPage(),
        '/main': (context) => const MainPage(),
        '/question': (context) => const QuestionPage(),
        '/summary': (context) => const SummaryPage(),
        '/admin/teams': (context) => const TeamManagementPage(),
        '/admin/teams-list': (context) => const TeamsListPage(),
        '/admin/users': (context) => const UserManagementPage(),
        '/admin/games': (context) => const GameManagementPage(),
        '/admin/active-games': (context) => const ActiveGamesPage(),
        '/admin/analytics': (context) => const AnalyticsDashboardPage(),
      },
      debugShowCheckedModeBanner: false,
    );
  }
} 