import 'package:flutter/material.dart';
import '../services/user_data_service.dart';
import '../services/api_config_service.dart';
import 'login_page.dart' show DatabaseService;

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    print('=== SPLASH PAGE _checkLoginStatus START ===');
    // Load API config and apply to DatabaseService
    final apiUrl = await ApiConfigService.getApiBaseUrl();
    DatabaseService.setBaseUrl(apiUrl);
    print('API base URL loaded: $apiUrl');
    // Add a minimal delay for splash screen effect (reduced from 2 seconds)
    print('Waiting 0.5 seconds for splash screen effect...');
    await Future.delayed(const Duration(milliseconds: 500));
    
    print('Checking login status...');
    final isLoggedIn = await UserDataService.isLoggedIn();
    print('Splash page - isLoggedIn: $isLoggedIn');
    
    if (mounted) {
      if (isLoggedIn) {
        print('User is logged in, navigating to main page');
        Navigator.pushReplacementNamed(context, '/main');
      } else {
        print('User not logged in, navigating to login page');
        Navigator.pushReplacementNamed(context, '/login');
      }
    } else {
      print('Widget not mounted, cannot navigate');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.blue, Colors.purple],
          ),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.quiz,
                size: 80,
                color: Colors.white,
              ),
              SizedBox(height: 24),
              Text(
                'Quze',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 16),
              Text(
                'Loading...',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white70,
                ),
              ),
              SizedBox(height: 32),
              CircularProgressIndicator(
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
