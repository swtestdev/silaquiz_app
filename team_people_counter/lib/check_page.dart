import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'team_provider.dart';

class CheckPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final teamProvider = Provider.of<TeamProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Check Teams'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        automaticallyImplyLeading: false,
      ),
      body: ListView.builder(
        itemCount: teamProvider.teams.length,
        itemBuilder: (context, index) {
          final team = teamProvider.teams[index];
          return ListTile(
            title: Text(team.name),
            subtitle: Text('Scans: ${team.count}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: IconButton(
                    icon: Text('-', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      teamProvider.decrementCount(index);
                    },
                  ),
                ),
                SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: IconButton(
                    icon: Text('+', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      teamProvider.incrementCount(index);
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
} 