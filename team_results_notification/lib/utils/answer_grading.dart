import 'package:flutter/material.dart';

class ParsedQuestionKind {
  final String kind; // none, equals, radio, list
  final List<String> options;

  const ParsedQuestionKind(this.kind, this.options);
}

ParsedQuestionKind parseAnswersForSelection(String? raw) {
  final t = (raw ?? '').trim();
  if (t.isEmpty) return const ParsedQuestionKind('none', []);
  if (t == '=') return const ParsedQuestionKind('equals', []);
  if (t.startsWith('Radio:')) {
    final opts = t.substring(6).split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return ParsedQuestionKind('radio', opts);
  }
  if (t.startsWith('List:')) {
    final opts = t.substring(5).split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return ParsedQuestionKind('list', opts);
  }
  return const ParsedQuestionKind('none', []);
}

List<int> orderedAnswerCols(Map<String, dynamic> question) {
  final cols = question['ordered_cols'];
  if (cols is List) {
    return cols.map((e) => int.tryParse(e.toString()) ?? 0).where((e) => e > 0).toList();
  }
  final out = <int>[];
  for (var i = 1; i <= 4; i++) {
    final v = question['answer$i'];
    if (v != null && v.toString().trim().isNotEmpty) out.add(i);
  }
  return out;
}

String answerCellText(Map<String, dynamic> question, int col) {
  return (question['answer$col'] ?? '').toString();
}

List<String> splitSynonyms(String cell) {
  if (cell.trim().isEmpty) return [];
  return cell.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

String slotGradeLabel(int? grade) {
  if (grade == null) return '—';
  if (grade == 1) return 'Correct';
  if (grade == -1) return 'Wrong';
  if (grade == 0) return 'No answer';
  return '?';
}

String autoCheckEmoji(int? grade) {
  if (grade == null) return '—';
  if (grade == 1) return '✓';
  if (grade == -1) return '✗';
  if (grade == 0) return '○';
  return '?';
}

/// Sum slot grades using per-team correct/wrong point values.
double computeFinalScore(
  Iterable<int?> slotGrades,
  double correctScore,
  double wrongScore,
) {
  var total = 0.0;
  for (final grade in slotGrades) {
    if (grade == 1) {
      total += correctScore;
    } else if (grade == -1) {
      total += wrongScore;
    }
  }
  return total;
}

Color verdictChipColor(int? grade) {
  if (grade == 1) return const Color(0xFF2E7D32);
  if (grade == -1) return const Color(0xFFC62828);
  return const Color(0xFF616161);
}

Color verdictChipTextColor(int? grade) {
  return Colors.white;
}

/// Parse API grade values (int, double, string) for chip / DB line display.
int? parseStoredGrade(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse(v.toString());
}

/// Persisted DB grade line: green = correct, red = wrong, none = unset/zero.
Color? storedGradeLineColor(int? storedGrade) {
  if (storedGrade == 1) return const Color(0xFF2E7D32);
  if (storedGrade == -1) return const Color(0xFFC62828);
  return null;
}

/// Answer chip with optional vertical DB-status bar on the left.
Widget verdictChipWithStoredLine({required int? storedGrade, required Widget chip}) {
  final lineColor = storedGradeLineColor(storedGrade);
  if (lineColor == null) return chip;
  return Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        width: 3,
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: lineColor,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
      Flexible(child: chip),
    ],
  );
}
