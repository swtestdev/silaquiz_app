import 'package:flutter/material.dart';

/// Team disconnection summary for a round (DISCON column).
class AdminTeamDisconDialog extends StatelessWidget {
  final List<Map<String, dynamic>> teams;

  const AdminTeamDisconDialog({super.key, required this.teams});

  static Future<void> show(
    BuildContext context, {
    required List<Map<String, dynamic>> teams,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AdminTeamDisconDialog(teams: teams),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Disconnections by team'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Table(
            columnWidths: const {
              0: FixedColumnWidth(36),
              1: FlexColumnWidth(2),
              2: FlexColumnWidth(3),
            },
            border: TableBorder.all(color: Colors.grey.shade400),
            children: [
              TableRow(
                decoration: BoxDecoration(color: Colors.grey.shade200),
                children: const [
                  Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('#', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('КОМАНДЫ', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('DISCON', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              for (var i = 0; i < teams.length; i++)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('${i + 1}'),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        teams[i]['team_name']?.toString() ?? '',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        teams[i]['discon']?.toString().trim().isNotEmpty == true
                            ? teams[i]['discon'].toString()
                            : '',
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
