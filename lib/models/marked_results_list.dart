/// A teacher-curated, manually-selected group of already-marked scripts
/// (added 2026-09-02, Chief Marker) — distinct from a marking "cohort"
/// (everything queued and processed together in one session): a script
/// only ever joins one of these by the teacher explicitly ticking it on
/// [MarkedScriptsScreen] and choosing "Create New List" (or "Add to
/// List"). Once a script belongs to a list, it stops appearing on that
/// screen's general list — it lives here instead, matching the requested
/// "gets moved to the new list" behavior.
///
/// [exported] is the integrity gate: every score on every script in this
/// list stays fully editable until the list is exported/shared for the
/// first time (see [MarkedResultsListDetailScreen]._export), at which
/// point it flips true and stays true — [MarkingReviewScreen] then opens
/// every script here read-only. This is the literal "all scores remain
/// editable until exported or shared" requirement.
class MarkedResultsList {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<String> scriptIds;
  final bool exported;
  final DateTime? exportedAt;

  const MarkedResultsList({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.scriptIds,
    this.exported = false,
    this.exportedAt,
  });

  MarkedResultsList copyWith({
    String? name,
    List<String>? scriptIds,
    bool? exported,
    DateTime? exportedAt,
  }) =>
      MarkedResultsList(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        scriptIds: scriptIds ?? this.scriptIds,
        exported: exported ?? this.exported,
        exportedAt: exportedAt ?? this.exportedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'scriptIds': scriptIds,
        'exported': exported,
        'exportedAt': exportedAt?.toIso8601String(),
      };

  factory MarkedResultsList.fromJson(Map<String, dynamic> json) => MarkedResultsList(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Untitled list',
        createdAt: DateTime.parse(json['createdAt'] as String),
        scriptIds: (json['scriptIds'] as List?)?.cast<String>() ?? const [],
        exported: json['exported'] as bool? ?? false,
        exportedAt: json['exportedAt'] != null ? DateTime.parse(json['exportedAt'] as String) : null,
      );
}

class MarkedResultsListCatalog {
  final List<MarkedResultsList> lists;

  const MarkedResultsListCatalog({required this.lists});

  factory MarkedResultsListCatalog.empty() => const MarkedResultsListCatalog(lists: []);

  factory MarkedResultsListCatalog.fromJson(Map<String, dynamic> json) => MarkedResultsListCatalog(
        lists: (json['lists'] as List).cast<Map<String, dynamic>>().map(MarkedResultsList.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'lists': [for (final l in lists) l.toJson()]};

  /// Every script id already claimed by some list — [MarkedScriptsScreen]
  /// filters its general list against this.
  Set<String> get allScriptIds => {for (final l in lists) ...l.scriptIds};

  /// Whether [scriptId] belongs to a list that's already been exported —
  /// [MarkingReviewScreen] opens read-only when true.
  bool isLocked(String scriptId) => lists.any((l) => l.exported && l.scriptIds.contains(scriptId));
}
