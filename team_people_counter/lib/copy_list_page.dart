import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'team_provider.dart';
import 'package:clipboard/clipboard.dart';

class CopyListPage extends StatelessWidget {
  String formatList(TeamProvider teamProvider) {
    return teamProvider.teams
        .map((team) => '${team.name}###${team.count}')
        .join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final teamProvider = Provider.of<TeamProvider>(context);
    final formatted = formatList(teamProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('Copy List'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.copy),
            tooltip: 'Copy to Clipboard',
            onPressed: () async {
              await FlutterClipboard.copy(formatted);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('List copied to clipboard!')),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(formatted, style: TextStyle(fontSize: 18)),
              ),
            ),
            // Remove the bottom Copy to Clipboard button
            // ElevatedButton(
            //   onPressed: () async {
            //     await FlutterClipboard.copy(formatted);
            //     ScaffoldMessenger.of(context).showSnackBar(
            //       SnackBar(content: Text('List copied to clipboard!')),
            //     );
            //   },
            //   child: Text('Copy to Clipboard'),
            // ),
          ],
        ),
      ),
    );
  }
} 