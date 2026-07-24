/// Whether an active_games row is usable for View Results / Analytics (anything except idle).
bool activeGameIsAvailable(String? status) {
  final s = (status ?? '').trim().toLowerCase();
  return s.isNotEmpty && s != 'idle';
}

int? parseActiveGameId(dynamic id) {
  if (id == null) return null;
  if (id is int) return id;
  if (id is num) return id.toInt();
  return int.tryParse(id.toString());
}

int _statusPriority(String status) {
  switch (status.toLowerCase()) {
    case 'running':
      return 0;
    case 'active':
      return 1;
    default:
      return 2;
  }
}

/// Pick the best current active game: non-idle only, prefer running → active → newest id.
Map<String, dynamic>? pickCurrentActiveGame(List<dynamic> games) {
  final candidates = games
      .whereType<Map<String, dynamic>>()
      .where((g) => activeGameIsAvailable(g['is_started']?.toString()))
      .toList();
  if (candidates.isEmpty) return null;

  candidates.sort((a, b) {
    final pa = _statusPriority(a['is_started']?.toString() ?? '');
    final pb = _statusPriority(b['is_started']?.toString() ?? '');
    if (pa != pb) return pa.compareTo(pb);
    final ia = parseActiveGameId(a['id']) ?? 0;
    final ib = parseActiveGameId(b['id']) ?? 0;
    return ib.compareTo(ia);
  });
  return candidates.first;
}
