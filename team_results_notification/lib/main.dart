import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
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

final DebugConsoleController _debugConsole = DebugConsoleController();

void main() {
  final enableDebugConsole =
      kIsWeb && Uri.base.queryParameters['debug']?.toLowerCase() == 'true';
  _debugConsole.enabled = enableDebugConsole;

  runZonedGuarded(
    () {
      runApp(PWAApp(enableDebugConsole: enableDebugConsole));
    },
    (error, stack) {
      if (enableDebugConsole) {
        _debugConsole.addLog('ERROR: $error');
        _debugConsole.addLog(stack.toString());
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, message) {
        if (enableDebugConsole) {
          _debugConsole.addLog(message);
        }
        parent.print(zone, message);
      },
    ),
  );
}

class PWAApp extends StatelessWidget {
  final bool enableDebugConsole;

  const PWAApp({super.key, required this.enableDebugConsole});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quze',
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
      builder: (context, child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) Positioned.fill(child: child),
            if (enableDebugConsole)
              DebugConsoleOverlay(controller: _debugConsole),
          ],
        );
      },
    );
  }
}

class DebugConsoleController {
  bool enabled = false;
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  void addLog(String message) {
    if (!enabled) return;
    final next = List<String>.from(logs.value)..add(message);
    const maxLines = 300;
    if (next.length > maxLines) {
      next.removeRange(0, next.length - maxLines);
    }
    logs.value = next;
  }

  void clear() {
    logs.value = [];
  }
}

class DebugConsoleOverlay extends StatefulWidget {
  final DebugConsoleController controller;

  const DebugConsoleOverlay({super.key, required this.controller});

  @override
  State<DebugConsoleOverlay> createState() => _DebugConsoleOverlayState();
}

class _DebugConsoleOverlayState extends State<DebugConsoleOverlay> {
  bool _expanded = true;

  Future<bool> _copyToClipboardWeb(String text) async {
    try {
      final clipboard = html.window.navigator.clipboard;
      if (clipboard != null) {
        await clipboard.writeText(text);
        return true;
      }
    } catch (_) {}
    try {
      final textarea = html.TextAreaElement()
        ..value = text
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.top = '0';
      html.document.body?.append(textarea);
      textarea.focus();
      textarea.select();
      textarea.setSelectionRange(0, text.length);
      final ok = html.document.execCommand('copy');
      textarea.remove();
      return ok;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      bottom: 12,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_expanded) _buildPanel(context),
            const SizedBox(height: 8),
            FloatingActionButton(
              onPressed: () {
                setState(() {
                  _expanded = !_expanded;
                });
              },
              backgroundColor: Colors.black87,
              child: Icon(
                _expanded ? Icons.bug_report_outlined : Icons.bug_report,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    return Container(
      width: 380,
      height: 240,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Debug Console',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: () {
                  widget.controller.clear();
                },
                child: const Text(
                  'Clear',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () async {
                  final text = widget.controller.logs.value.join('\n');
                  final ok = await _copyToClipboardWeb(text);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ok ? 'Logs copied to clipboard' : 'Copy failed - try selecting text manually',
                        ),
                      ),
                    );
                  }
                },
                child: const Text(
                  'Copy',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ValueListenableBuilder<List<String>>(
              valueListenable: widget.controller.logs,
              builder: (context, logs, _) {
                return ListView.builder(
                  itemCount: logs.length,
                  reverse: true,
                  itemBuilder: (context, index) {
                    final message = logs[logs.length - 1 - index];
                    return Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
} 