/// Where one captured set of meeting-note photos sits in the Minutes Maker
/// pipeline. [captured] means photographed and saved locally, nothing sent
/// anywhere yet; [processing]/[ready] track the AI-reconstruction call
/// (Stage 5); [needsRetry] mirrors AutoGrade's same-named status for a
/// failed processing attempt.
enum MinutesSessionStatus {
  captured,
  processing,
  ready,
  needsRetry;

  String get dbValue => name;

  static MinutesSessionStatus fromDb(String value) =>
      MinutesSessionStatus.values.firstWhere((s) => s.dbValue == value, orElse: () => MinutesSessionStatus.captured);

  String get label => switch (this) {
        MinutesSessionStatus.captured => 'Captured — not yet processed',
        MinutesSessionStatus.processing => 'Processing…',
        MinutesSessionStatus.ready => 'Minutes ready',
        MinutesSessionStatus.needsRetry => 'Needs retry',
      };
}

/// One block of the AI-reconstructed minutes document (Stage 5's output) —
/// see MinutesReconstructionService. Kept deliberately generic (a heading
/// plus a list of lines) rather than separate typed fields per section, so
/// a meeting missing a section (no formal agenda, say) doesn't force an
/// empty field into the model or the exported document.
class MinutesSection {
  final String heading;
  final List<String> lines;

  const MinutesSection({required this.heading, required this.lines});

  factory MinutesSection.fromJson(Map<String, dynamic> json) => MinutesSection(
        heading: json['heading'] as String,
        lines: (json['lines'] as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {'heading': heading, 'lines': lines};
}

/// One meeting's captured note photos, and — once Stage 5 has run — the
/// AI-reconstructed minutes. Stored fully offline at capture time; only
/// processing (Stage 5) needs a connection. See [MinutesSessionRepository].
class MinutesSession {
  final String id;
  final String meetingTitle;
  final DateTime meetingDate;

  /// File names only (relative to this session's own subdirectory), in
  /// page order — same convention as MarkingScript.pageFileNames.
  final List<String> pageFileNames;

  final DateTime capturedAt;
  final MinutesSessionStatus status;

  /// Stage 5's output, once processing completes — null until then.
  final List<MinutesSection>? sections;

  /// Set when [status] is [MinutesSessionStatus.needsRetry].
  final String? lastError;

  const MinutesSession({
    required this.id,
    required this.meetingTitle,
    required this.meetingDate,
    required this.pageFileNames,
    required this.capturedAt,
    this.status = MinutesSessionStatus.captured,
    this.sections,
    this.lastError,
  });

  int get pageCount => pageFileNames.length;

  MinutesSession copyWith({
    List<String>? pageFileNames,
    MinutesSessionStatus? status,
    List<MinutesSection>? sections,
    String? lastError,
    bool clearLastError = false,
  }) =>
      MinutesSession(
        id: id,
        meetingTitle: meetingTitle,
        meetingDate: meetingDate,
        pageFileNames: pageFileNames ?? this.pageFileNames,
        capturedAt: capturedAt,
        status: status ?? this.status,
        sections: sections ?? this.sections,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
      );

  factory MinutesSession.fromJson(Map<String, dynamic> json) => MinutesSession(
        id: json['id'] as String,
        meetingTitle: json['meetingTitle'] as String,
        meetingDate: DateTime.parse(json['meetingDate'] as String),
        pageFileNames: (json['pageFileNames'] as List).cast<String>(),
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        status: MinutesSessionStatus.fromDb(json['status'] as String? ?? 'captured'),
        sections: (json['sections'] as List?)?.cast<Map<String, dynamic>>().map(MinutesSection.fromJson).toList(),
        lastError: json['lastError'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'meetingTitle': meetingTitle,
        'meetingDate': meetingDate.toIso8601String(),
        'pageFileNames': pageFileNames,
        'capturedAt': capturedAt.toIso8601String(),
        'status': status.dbValue,
        'sections': sections?.map((s) => s.toJson()).toList(),
        'lastError': lastError,
      };
}

class MinutesSessionCatalog {
  final List<MinutesSession> sessions;

  const MinutesSessionCatalog({required this.sessions});

  factory MinutesSessionCatalog.empty() => const MinutesSessionCatalog(sessions: []);

  factory MinutesSessionCatalog.fromJson(Map<String, dynamic> json) => MinutesSessionCatalog(
        sessions: (json['sessions'] as List).cast<Map<String, dynamic>>().map(MinutesSession.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'sessions': [for (final s in sessions) s.toJson()]};
}
