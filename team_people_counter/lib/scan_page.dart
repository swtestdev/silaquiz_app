import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'team_provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanPage extends StatefulWidget {
  @override
  _ScanPageState createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  MobileScannerController? controller;
  bool _scanned = false;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _initializeScanner();
  }

  void _initializeScanner() {
    try {
      print('Initializing scanner...');
      controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
        torchEnabled: false,
      );
      setState(() {
        _isInitialized = true;
        _hasError = false;
      });
      print('Scanner initialized successfully');
    } catch (e) {
      print('Error initializing scanner: $e');
      setState(() {
        _isInitialized = false;
        _hasError = true;
        _errorMessage = e.toString();
      });
      
      // Show error immediately on screen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scanner Error: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      });
    }
  }

  void _handleScan(String code) {
    try {
      print('_handleScan called with code: $code');
      
      if (code.isEmpty) {
        print('Empty QR code detected in _handleScan');
        _showErrorDialog('QR Code Error', 'Empty QR code detected');
        return;
      }
      
      // Debug: Show what QR code was detected
      print('QR Code detected: $code');
      
      final teamProvider = Provider.of<TeamProvider>(context, listen: false);
      print('Number of teams available: ${teamProvider.teams.length}');
      
      final index = teamProvider.findTeamIndexByQr(code);
      print('Team index found: $index');
      
      if (index != -1) {
        print('Team found, incrementing count');
        teamProvider.incrementCount(index!);
        _showResultDialog('Success', 'Scan counted for team: ${teamProvider.teams[index!].name}');
      } else {
        print('No team found for QR code: $code');
        final availableTeams = teamProvider.teams.map((t) => '${t.name}: ${t.qrCode}').join(', ');
        print('Available teams: $availableTeams');
        _showErrorDialog('QR Code Error', 'No team found for this QR code: $code\n\nAvailable teams: $availableTeams');
      }
    } catch (e) {
      print('Error in _handleScan: $e');
      _showErrorDialog('Scan Error', 'Error processing QR code: $e');
    }
  }

  void _showResultDialog(String title, String message) {
    print('Showing result dialog: $title - $message');
    showDialog(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              print('Result dialog OK pressed');
              Navigator.pop(context);
              // Reset scanned state and restart scanner
              setState(() {
                _scanned = false;
              });
              // Give a small delay before restarting
              Future.delayed(Duration(milliseconds: 300), () {
                print('Restarting scanner after success');
                controller?.start();
              });
            },
            child: Text('Continue Scanning'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    print('Showing error dialog: $title - $message');
    // Only show the dialog, do not show a SnackBar
    showDialog(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (context) => AlertDialog(
        title: Text(title, style: TextStyle(color: Colors.red)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              print('Error dialog OK pressed');
              Navigator.pop(context);
              // Reset scanned state and restart scanner
              setState(() {
                _scanned = false;
              });
              // Give a small delay before restarting
              Future.delayed(Duration(milliseconds: 300), () {
                print('Restarting scanner after error');
                controller?.start();
              });
            },
            child: Text('Continue Scanning'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Scan QR Code'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () {
            print('Back button pressed');
            controller?.dispose();
            Navigator.pop(context);
          },
        ),
        automaticallyImplyLeading: false, // Prevent automatic back button
      ),
      body: Builder(
        builder: (context) {
          try {
            if (_hasError) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error, size: 64, color: Colors.red),
                    SizedBox(height: 16),
                    Text('Scanner Error', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    Text('Error: $_errorMessage'),
                    SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        _initializeScanner();
                      },
                      child: Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            
            if (!_isInitialized || controller == null) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Initializing Camera...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }
            
            return MobileScanner(
              controller: controller,
              onDetect: (capture) {
                try {
                  print('=== QR Detection triggered ===');
                  print('Number of barcodes detected: ${capture.barcodes.length}');
                  print('Current _scanned state: $_scanned');
                  
                  if (_scanned) {
                    print('Already scanned, ignoring detection');
                    return;
                  }
                  
                  final List<Barcode> barcodes = capture.barcodes;
                  if (barcodes.isEmpty) {
                    print('No barcodes found in capture');
                    // Show feedback to user
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('No QR code detected'),
                        backgroundColor: Colors.orange,
                        duration: Duration(seconds: 2),
                      ),
                    );
                    return;
                  }
                  
                  for (final barcode in barcodes) {
                    print('Barcode type: ${barcode.type}');
                    print('Barcode raw value: ${barcode.rawValue}');
                    print('Barcode display value: ${barcode.displayValue}');
                    
                    if (barcode.rawValue != null && barcode.rawValue!.isNotEmpty) {
                      print('Valid QR code found: ${barcode.rawValue}');
                      // Set scanned state immediately to prevent multiple detections
                      setState(() {
                        _scanned = true;
                      });
                      _handleScan(barcode.rawValue!);
                      break;
                    } else {
                      print('Empty or null QR code detected');
                      if (!_scanned) {
                        setState(() {
                          _scanned = true;
                        });
                        _showErrorDialog('QR Code Error', 'Empty or invalid QR code detected');
                      }
                    }
                  }
                } catch (e) {
                  print('Error in onDetect: $e');
                  // Show error immediately on screen
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Scan Error: $e'),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 5),
                    ),
                  );
                  if (!_scanned) {
                    setState(() {
                      _scanned = true;
                    });
                    _showErrorDialog('Scan Error', 'Error processing scan: $e');
                  }
                }
              },
            );
          } catch (e) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: Colors.red),
                  SizedBox(height: 16),
                  Text('Scanner Error', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('Failed to initialize camera: $e'),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {});
                    },
                    child: Text('Retry'),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }
} 