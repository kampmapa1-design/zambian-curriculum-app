import 'marking_rubric.dart';

/// One answer's mark location on the real script, as Concise Marking's AI
/// placed it — persisted so the ticked/crossed marked script can be
/// regenerated at any time from the saved photos, with NO new AI call.
class ScriptAnnotationRecord {
  final String questionLabel;
  final int? pageIndex;
  final int? yMin;
  final int? xMin;
  final int? yMax;
  final int? xMax;

  const ScriptAnnotationRecord({
    required this.questionLabel,
    this.pageIndex,
    this.yMin,
    this.xMin,
    this.yMax,
    this.xMax,
  });

  bool get hasLocation =>
      pageIndex != null && yMin != null && xMin != null && yMax != null && xMax != null;

  Map<String, dynamic> toJson() => {
        'questionLabel': questionLabel,
        if (pageIndex != null) 'pageIndex': pageIndex,
        if (yMin != null) 'yMin': yMin,
        if (xMin != null) 'xMin': xMin,
        if (yMax != null) 'yMax': yMax,
        if (xMax != null) 'xMax': xMax,
      };

  factory ScriptAnnotationRecord.fromJson(Map<String, dynamic> json) => ScriptAnnotationRecord(
        questionLabel: json['questionLabel'] as String? ?? '',
        pageIndex: (json['pageIndex'] as num?)?.toInt(),
        yMin: (json['yMin'] as num?)?.toInt(),
        xMin: (json['xMin'] as num?)?.toInt(),
        yMax: (json['yMax'] as num?)?.toInt(),
        xMax: (json['xMax'] as num?)?.toInt(),
      );
}

/// Everything a [MarkingScript] needs to re-produce its Concise Marking /
/// Stable Marker artefacts — the timestamped marked script image (Concise
/// only), the performance report, and the score — WITHOUT calling the AI
/// again (2026-09-10 fix: the marked script used to be reachable only
/// during the live session and was stranded once the teacher left it).
///
/// [scoreJson] is a serialised `ConciseScore` — reconstruct it with
/// `ConciseScore.fromJson` (kept opaque here so this model stays in
/// lib/models with no service dependency).
class ConciseMarkingRecord {
  final DateTime markedAt;

  /// 'concise' or 'stable'.
  final String engine;

  final List<ScriptAnnotationRecord> annotations;
  final Map<String, dynamic> scoreJson;

  /// Which section each answer belongs to (label -> section, or null) —
  /// kept so a regenerated report can still show the section breakdown.
  final Map<String, String?> sectionByLabel;

  /// The exact rubric that was actually used to compute [scoreJson] — added
  /// 2026-09-22 (Marking Reliability Stage 10) so a mark can be corrected
  /// later (from the review comparison screen) with the score genuinely
  /// RECOMPUTED against the same section rules, instead of either losing
  /// section-allocation scaling entirely or guessing. Null for a record
  /// saved before this field existed, or for a script with no section
  /// structure at all (a plain-sum score) — both are real, honest states,
  /// not an error.
  final MarkingRubric? rubric;

  const ConciseMarkingRecord({
    required this.markedAt,
    required this.engine,
    required this.annotations,
    required this.scoreJson,
    this.sectionByLabel = const {},
    this.rubric,
  });

  bool get isStable => engine == 'stable';

  Map<String, dynamic> toJson() => {
        'markedAt': markedAt.toIso8601String(),
        'engine': engine,
        'annotations': [for (final a in annotations) a.toJson()],
        'score': scoreJson,
        'sectionByLabel': sectionByLabel,
        if (rubric != null) 'rubric': rubric!.toJson(),
      };

  factory ConciseMarkingRecord.fromJson(Map<String, dynamic> json) => ConciseMarkingRecord(
        markedAt: DateTime.tryParse(json['markedAt'] as String? ?? '') ?? DateTime.now(),
        engine: json['engine'] as String? ?? 'concise',
        annotations: (json['annotations'] as List?)
                ?.whereType<Map>()
                .map((m) => ScriptAnnotationRecord.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
        scoreJson: (json['score'] as Map?)?.cast<String, dynamic>() ?? const {},
        sectionByLabel: (json['sectionByLabel'] as Map?)
                ?.map((k, v) => MapEntry(k as String, v as String?)) ??
            const {},
        rubric: (json['rubric'] as Map?) == null ? null : MarkingRubric.fromJson((json['rubric'] as Map).cast<String, dynamic>()),
      );
}
