import 'package:cloud_firestore/cloud_firestore.dart';

/// The single, shared national exam timetable date every learner reads —
/// "Fix 6" (owner request, 2026-09-29). Only ever set by the app owner,
/// via [NationalExamTimetableService.save], after AI-extracting it from a
/// real uploaded document and a human confirming it. See that service's
/// own doc comment for the full flow.
class NationalExamTimetable {
  final int year;
  final DateTime startDate;

  /// The exam period's own last day — added 2026-09-29 so the learner
  /// countdown knows when to stop showing "Examinations In Progress".
  /// Null for a timetable saved before this field existed, or when the
  /// uploaded document genuinely didn't show a legible end date.
  final DateTime? endDate;

  final DateTime updatedAt;

  const NationalExamTimetable({
    required this.year,
    required this.startDate,
    this.endDate,
    required this.updatedAt,
  });

  factory NationalExamTimetable.fromMap(Map<String, dynamic> map) => NationalExamTimetable(
        year: (map['year'] as num).toInt(),
        startDate: DateTime.parse(map['startDateIso'] as String),
        endDate: (map['endDateIso'] is String && (map['endDateIso'] as String).isNotEmpty)
            ? DateTime.tryParse(map['endDateIso'] as String)
            : null,
        updatedAt: map['updatedAt'] is Timestamp ? (map['updatedAt'] as Timestamp).toDate() : DateTime.now(),
      );
}
