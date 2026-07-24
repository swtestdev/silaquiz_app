/// Format earned points for matrix cells and grading UI.
String formatScoreDisplay(num v) {
  final d = v.toDouble();
  if ((d - d.round()).abs() < 1e-9) {
    return d.round().toString();
  }
  return d.toString();
}

num coerceScore(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v;
  return num.tryParse(v.toString()) ?? 0;
}

/// Admin matrix / scoreboard: final_score already includes lucky_bonus.
num answerRowDisplayPoints(Map<String, dynamic>? row) {
  if (row == null) return 0;
  final fs = row['final_score'];
  if (fs != null) {
    return coerceScore(fs);
  }
  return coerceScore(row['points']);
}

/// Sum per-question display points for a round total column.
num sumAnswerRowPoints(Map<String, dynamic>? cells) {
  if (cells == null || cells.isEmpty) return 0;
  var total = 0.0;
  for (final cell in cells.values) {
    if (cell is Map<String, dynamic>) {
      total += answerRowDisplayPoints(cell).toDouble();
    } else if (cell is Map) {
      total += answerRowDisplayPoints(Map<String, dynamic>.from(cell)).toDouble();
    }
  }
  return total;
}
