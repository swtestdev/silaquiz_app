import 'dart:async';

import 'package:flutter/material.dart';

import '../login_page.dart';
import 'admin_round_player_tracking_dialog.dart';

class AdminRoundAppTrackingPage extends StatefulWidget {
  final int activeGameId;
  final String gameName;
  final String roundName;

  const AdminRoundAppTrackingPage({
    super.key,
    required this.activeGameId,
    required this.gameName,
    required this.roundName,
  });

  @override
  State<AdminRoundAppTrackingPage> createState() =>
      _AdminRoundAppTrackingPageState();
}

class _AdminRoundAppTrackingPageState extends State<AdminRoundAppTrackingPage> {
  static const _bg = Color(0xFF000000);
  static const _bannerGreen = Color(0xFF2E7D32);
  static const _liveGreen = Color(0xFF2E7D32);
  static const _liveRed = Color(0xFFC62828);
  static const _teamBg = Color(0xFF1A1A1A);
  static const _textWhite = Colors.white;

  bool _loading = true;
  String? _error;
  String? _serverTime;
  List<Map<String, dynamic>> _teams = [];
  List<Map<String, dynamic>> _playerColumns = [];
  Map<String, dynamic>? _roundTimer;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _loadTracking(initial: true);
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadTracking(initial: false);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadTracking({required bool initial}) async {
    if (initial) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final data = await DatabaseService.getRoundAppTracking(
      widget.activeGameId,
      widget.roundName,
    );

    if (!mounted) return;

    if (data['success'] != true) {
      setState(() {
        _loading = false;
        _error = data['message']?.toString() ?? 'Failed to load tracking';
      });
      return;
    }

    setState(() {
      _teams = (data['teams'] as List? ?? []).cast<Map<String, dynamic>>();
      _playerColumns =
          (data['player_columns'] as List? ?? []).cast<Map<String, dynamic>>();
      _roundTimer = data['round_timer'] as Map<String, dynamic>?;
      _serverTime = data['server_time']?.toString();
      _loading = false;
      _error = null;
    });
  }

  void _openPlayerDialog(int userId, String displayName) {
    AdminRoundPlayerTrackingDialog.show(
      context,
      activeGameId: widget.activeGameId,
      roundName: widget.roundName,
      userId: userId,
      displayName: displayName,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('Tracking APP'),
        backgroundColor: _bannerGreen,
        foregroundColor: _textWhite,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh now',
            onPressed: () => _loadTracking(initial: false),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _textWhite))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: _bannerGreen,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.roundName,
                        style: const TextStyle(
                          color: _textWhite,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.gameName,
                        style: TextStyle(
                          color: _textWhite.withValues(alpha: 0.85),
                          fontSize: 13,
                        ),
                      ),
                      if (_serverTime != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Updated: $_serverTime · poll 5s',
                          style: TextStyle(
                            color: _textWhite.withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_roundTimer != null && _roundTimer!['is_active'] == true)
                  _buildTimerBar(),
                if (_error != null)
                  Container(
                    color: Colors.orange.shade900,
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: _textWhite, fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _buildMatrix(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildTimerBar() {
    final duration = int.tryParse('${_roundTimer!['duration_sec']}') ?? 0;
    final remaining = int.tryParse('${_roundTimer!['remaining_sec']}') ?? 0;
    final progress = duration > 0 ? (duration - remaining) / duration : 0.0;

    return Container(
      color: _teamBg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Round timer',
                style: TextStyle(color: _textWhite, fontWeight: FontWeight.w600),
              ),
              Text(
                '${remaining}s left',
                style: TextStyle(color: _textWhite.withValues(alpha: 0.85)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.grey.shade800,
              color: _bannerGreen,
            ),
          ),
        ],
      ),
    );
  }

  bool _hasTrackingCells() => _playerColumns.isNotEmpty;

  bool _cellIsVisible(Map<String, dynamic> cell) {
    return cell['is_visible'] == true ||
        cell['is_visible'] == 1 ||
        '${cell['is_visible']}'.toLowerCase() == 'true';
  }

  Widget _playerCell(Map<String, dynamic>? cell, {required double width}) {
    if (cell == null) {
      return SizedBox(
        width: width,
        height: 52,
        child: Center(
          child: Text(
            '—',
            style: TextStyle(color: _textWhite.withValues(alpha: 0.35)),
          ),
        ),
      );
    }

    final isVisible = _cellIsVisible(cell);
    final seconds = int.tryParse('${cell['invisible_seconds']}') ?? 0;
    final userId = int.tryParse('${cell['user_id']}') ?? 0;
    final name = cell['display_name']?.toString() ?? 'Player';
    final blockColor = isVisible ? _liveGreen : _liveRed;

    return SizedBox(
      width: width,
      child: Material(
        color: blockColor,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: userId > 0 ? () => _openPlayerDialog(userId, name) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isVisible ? '0' : '${seconds}s',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _textWhite,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic>? _teamPlayerCell(
    Map<String, dynamic> team,
    int userId,
  ) {
    final players = team['players'] as Map?;
    if (players != null) {
      final cell = players['$userId'];
      if (cell is Map<String, dynamic>) return cell;
    }
    for (final cell in (team['cells'] as List? ?? [])) {
      if (cell is Map && int.tryParse('${cell['user_id']}') == userId) {
        return cell.cast<String, dynamic>();
      }
    }
    return null;
  }

  Widget _buildMatrix() {
    const rankW = 44.0;
    const teamW = 180.0;
    const playerColW = 72.0;
    const headerH = 48.0;
    const rowH = 56.0;

    if (_teams.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No teams in this game.',
          style: TextStyle(color: _textWhite.withValues(alpha: 0.7)),
        ),
      );
    }

    if (!_hasTrackingCells()) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No player visibility events yet for this round.',
          style: TextStyle(color: _textWhite.withValues(alpha: 0.7)),
        ),
      );
    }

    Widget headerLabel(
      String label, {
      required double width,
      required Alignment align,
    }) {
      return SizedBox(
        width: width,
        height: headerH,
        child: Align(
          alignment: align,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: align == Alignment.center
                  ? TextAlign.center
                  : TextAlign.start,
              style: const TextStyle(
                color: _textWhite,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      );
    }

    final playerHeader = Row(
      children: [
        for (final col in _playerColumns)
          headerLabel(
            col['user_name']?.toString() ?? 'Player',
            width: playerColW,
            align: Alignment.center,
          ),
      ],
    );

    final playerRows = Column(
      children: [
        for (var i = 0; i < _teams.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                for (final col in _playerColumns)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _playerCell(
                      _teamPlayerCell(
                        _teams[i],
                        int.tryParse('${col['user_id']}') ?? 0,
                      ),
                      width: playerColW,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    final frozenColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            headerLabel('#', width: rankW, align: Alignment.center),
            headerLabel('КОМАНДЫ', width: teamW, align: Alignment.centerLeft),
          ],
        ),
        for (var i = 0; i < _teams.length; i++)
          SizedBox(
            height: rowH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: rankW,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _textWhite, fontSize: 14),
                  ),
                ),
                Container(
                  width: teamW,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: _teamBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _teams[i]['team_name']?.toString() ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _textWhite,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          frozenColumn,
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  playerHeader,
                  const SizedBox(height: 4),
                  playerRows,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
