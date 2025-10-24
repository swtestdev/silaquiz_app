import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'team_provider.dart';
import 'team_model.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class AddTeamPage extends StatefulWidget {
  @override
  _AddTeamPageState createState() => _AddTeamPageState();
}

class _AddTeamPageState extends State<AddTeamPage> {
  final _formKey = GlobalKey<FormState>();
  final _teamNameController = TextEditingController();
  final _qrCodeController = TextEditingController();
  String? _newTeamName;
  String? _newTeamQr;

  @override
  void dispose() {
    _teamNameController.dispose();
    _qrCodeController.dispose();
    super.dispose();
  }

  void _showQrScanner(Function(String) onScanned) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QrScannerPage()),
    );
    if (result != null && result is String) {
      onScanned(result);
    }
  }

  void _showEditDialog(int index, Team team) {
    String name = team.name;
    String qr = team.qrCode;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Edit Team'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: name,
                decoration: InputDecoration(labelText: 'Team Name'),
                onChanged: (val) => name = val,
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(qr.isEmpty ? 'No QR' : qr),
                  ),
                  IconButton(
                    icon: Icon(Icons.qr_code_scanner),
                    onPressed: () {
                      _showQrScanner((scanned) {
                        setState(() {
                          qr = scanned;
                        });
                        Navigator.of(context).pop();
                        _showEditDialog(index, Team(name: name, qrCode: qr, count: team.count));
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Provider.of<TeamProvider>(context, listen: false)
                    .updateTeam(index, Team(name: name, qrCode: qr, count: team.count));
                Navigator.pop(context);
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteConfirmation(int index) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Confirm Deletion'),
          content: Text('Are you sure you want to delete this team?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Provider.of<TeamProvider>(context, listen: false).removeTeam(index);
                Navigator.pop(context);
              },
              child: Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('OK'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final teamProvider = Provider.of<TeamProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Add Team'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Form(
              key: _formKey,
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _teamNameController,
                      decoration: InputDecoration(labelText: 'Team Name'),
                      onChanged: (val) => _newTeamName = val,
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _qrCodeController,
                      decoration: InputDecoration(labelText: 'QR Code'),
                      readOnly: true,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.qr_code_scanner),
                    onPressed: () {
                      _showQrScanner((scanned) {
                        setState(() {
                          _newTeamQr = scanned;
                          _qrCodeController.text = scanned;
                        });
                      });
                    },
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final teamName = _teamNameController.text.trim();
                      final teamQr = _qrCodeController.text.trim();
                      
                      if (teamName.isNotEmpty && teamQr.isNotEmpty) {
                        final teamProvider = Provider.of<TeamProvider>(context, listen: false);
                        
                        // Check for duplicate team name
                        if (teamProvider.hasTeamWithName(teamName)) {
                          _showErrorDialog('Duplicate Team Name', 'A team with this name already exists.');
                          return;
                        }
                        
                        // Check for duplicate QR code
                        if (teamProvider.hasTeamWithQr(teamQr)) {
                          _showErrorDialog('Duplicate QR Code', 'A team with this QR code already exists.');
                          return;
                        }
                        
                        teamProvider.addTeam(Team(name: teamName, qrCode: teamQr));
                        
                        // Clear the form
                        _teamNameController.clear();
                        _qrCodeController.clear();
                        setState(() {
                          _newTeamName = null;
                          _newTeamQr = null;
                        });
                      } else {
                        _showErrorDialog('Validation Error', 'Please enter both team name and QR code.');
                      }
                    },
                    child: Text('Add'),
                  ),
                ],
              ),
            ),
          ),
          if (_newTeamQr != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text('Scanned QR: $_newTeamQr'),
            ),
          Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: teamProvider.teams.length,
              itemBuilder: (context, index) {
                final team = teamProvider.teams[index];
                return ListTile(
                  title: Text(team.name),
                  subtitle: Text(team.qrCode.isEmpty ? 'No QR' : team.qrCode),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => _showEditDialog(index, team),
                        child: Text('Edit', style: TextStyle(color: Colors.blue)),
                      ),
                      TextButton(
                        onPressed: () {
                          _showDeleteConfirmation(index);
                        },
                        child: Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class QrScannerPage extends StatefulWidget {
  @override
  _QrScannerPageState createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  MobileScannerController? controller;
  bool _scanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Scan QR Code'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () {
            controller?.dispose();
            Navigator.pop(context);
          },
        ),
        automaticallyImplyLeading: false,
      ),
      body: MobileScanner(
        controller: MobileScannerController(),
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            if (!_scanned && barcode.rawValue != null && barcode.rawValue!.isNotEmpty) {
              setState(() {
                _scanned = true;
              });
              controller?.stop();
              Navigator.of(context).pop(barcode.rawValue);
              break;
            }
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