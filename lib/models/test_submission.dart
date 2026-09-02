/// Where one submission sits in the capture → consolidate → send pipeline
/// — mirrors [AssignmentSubmissionStatus] exactly (same 3 states).
enum TestSubmissionStatus {
  draft,
  consolidated,
  sent;

  String get dbValue => name;

  static TestSubmissionStatus fromDb(String value) =>
      TestSubmissionStatus.values.firstWhere((s) => s.dbValue == value, orElse: () => TestSubmissionStatus.draft);
}

/// One AI-transcribed answer segment (Stage 3), tagged with its detected
/// question-number marker — or the literal string `'Unlabeled'` when no
/// clear marker was found. Order matters: segments are kept in the order
/// they were transcribed (page order), never regrouped by question
/// number, so the consolidated PDF (Stage 4) preserves both at once.
class TestAnswerSegment {
  final String questionNumber;
  final String text;

  const TestAnswerSegment({required this.questionNumber, required this.text});

  Map<String, dynamic> toJson() => {'questionNumber': questionNumber, 'text': text};

  factory TestAnswerSegment.fromJson(Map<String, dynamic> json) => TestAnswerSegment(
        questionNumber: json['questionNumber'] as String? ?? 'Unlabeled',
        text: json['text'] as String? ?? '',
      );
}

/// One test submission, end to end: who it's for (Stage 1's home-screen
/// entry point leads here), capture (Stage 2, capped at 5 pages),
/// question-tagged transcription (Stage 3), the consolidated PDF + image
/// bundle + integrity record (Stages 4-6), and transmission (Stage 7-8).
/// Stored fully offline (see [TestSubmissionRepository]) — every stage up
/// to transmission works with no connection at all.
class TestSubmission {
  final String id;
  final DateTime createdAt;
  final TestSubmissionStatus status;

  // Collected up front — no cover-page OCR source for this feature (unlike
  // Assignment Submission), so these are always plain student-typed/picked
  // fields, never AI-extracted.
  final String studentName;
  final String subjectName;
  final String gradeName;

  /// The student's school/institution, plain free text — added 2026-09-02
  /// alongside dropping the curriculum subject/grade picker screen in
  /// favor of plain text fields on the same page as the student's name.
  final String institution;

  final List<String> pageFileNames;
  final List<TestAnswerSegment> segments;

  final String? pdfFileName;
  final String? imageBundleFileName;
  final String? sha256Hash;
  final DateTime? submittedAt;

  final String? teacherEmail;
  final String? teacherWhatsApp;
  final bool emailSent;
  final bool whatsAppShared;
  final String? emailMessageId;

  /// Stage 10 — set once "Send to Marking" creates a linked
  /// [MarkingScript] from this submission's own images, so the receipt
  /// screen can show "Already added to Marking queue" instead of
  /// offering to create a duplicate.
  final String? markingScriptId;

  const TestSubmission({
    required this.id,
    required this.createdAt,
    this.status = TestSubmissionStatus.draft,
    this.studentName = '',
    this.subjectName = '',
    this.gradeName = '',
    this.institution = '',
    this.pageFileNames = const [],
    this.segments = const [],
    this.pdfFileName,
    this.imageBundleFileName,
    this.sha256Hash,
    this.submittedAt,
    this.teacherEmail,
    this.teacherWhatsApp,
    this.emailSent = false,
    this.whatsAppShared = false,
    this.emailMessageId,
    this.markingScriptId,
  });

  TestSubmission copyWith({
    TestSubmissionStatus? status,
    String? studentName,
    String? subjectName,
    String? gradeName,
    String? institution,
    List<String>? pageFileNames,
    List<TestAnswerSegment>? segments,
    String? pdfFileName,
    String? imageBundleFileName,
    String? sha256Hash,
    DateTime? submittedAt,
    String? teacherEmail,
    String? teacherWhatsApp,
    bool? emailSent,
    bool? whatsAppShared,
    String? emailMessageId,
    String? markingScriptId,
  }) =>
      TestSubmission(
        id: id,
        createdAt: createdAt,
        status: status ?? this.status,
        studentName: studentName ?? this.studentName,
        subjectName: subjectName ?? this.subjectName,
        gradeName: gradeName ?? this.gradeName,
        institution: institution ?? this.institution,
        pageFileNames: pageFileNames ?? this.pageFileNames,
        segments: segments ?? this.segments,
        pdfFileName: pdfFileName ?? this.pdfFileName,
        imageBundleFileName: imageBundleFileName ?? this.imageBundleFileName,
        sha256Hash: sha256Hash ?? this.sha256Hash,
        submittedAt: submittedAt ?? this.submittedAt,
        teacherEmail: teacherEmail ?? this.teacherEmail,
        teacherWhatsApp: teacherWhatsApp ?? this.teacherWhatsApp,
        emailSent: emailSent ?? this.emailSent,
        whatsAppShared: whatsAppShared ?? this.whatsAppShared,
        emailMessageId: emailMessageId ?? this.emailMessageId,
        markingScriptId: markingScriptId ?? this.markingScriptId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'status': status.dbValue,
        'studentName': studentName,
        'subjectName': subjectName,
        'gradeName': gradeName,
        'institution': institution,
        'pageFileNames': pageFileNames,
        'segments': segments.map((s) => s.toJson()).toList(),
        'pdfFileName': pdfFileName,
        'imageBundleFileName': imageBundleFileName,
        'sha256Hash': sha256Hash,
        'submittedAt': submittedAt?.toIso8601String(),
        'teacherEmail': teacherEmail,
        'teacherWhatsApp': teacherWhatsApp,
        'emailSent': emailSent,
        'whatsAppShared': whatsAppShared,
        'emailMessageId': emailMessageId,
        'markingScriptId': markingScriptId,
      };

  factory TestSubmission.fromJson(Map<String, dynamic> json) => TestSubmission(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        status: TestSubmissionStatus.fromDb(json['status'] as String? ?? 'draft'),
        studentName: json['studentName'] as String? ?? '',
        subjectName: json['subjectName'] as String? ?? '',
        gradeName: json['gradeName'] as String? ?? '',
        institution: json['institution'] as String? ?? '',
        pageFileNames: (json['pageFileNames'] as List?)?.cast<String>() ?? const [],
        segments:
            (json['segments'] as List?)?.cast<Map<String, dynamic>>().map(TestAnswerSegment.fromJson).toList() ??
                const [],
        pdfFileName: json['pdfFileName'] as String?,
        imageBundleFileName: json['imageBundleFileName'] as String?,
        sha256Hash: json['sha256Hash'] as String?,
        submittedAt: json['submittedAt'] != null ? DateTime.parse(json['submittedAt'] as String) : null,
        teacherEmail: json['teacherEmail'] as String?,
        teacherWhatsApp: json['teacherWhatsApp'] as String?,
        emailSent: json['emailSent'] as bool? ?? false,
        whatsAppShared: json['whatsAppShared'] as bool? ?? false,
        emailMessageId: json['emailMessageId'] as String?,
        markingScriptId: json['markingScriptId'] as String?,
      );
}

class TestSubmissionCatalog {
  final List<TestSubmission> submissions;

  const TestSubmissionCatalog({required this.submissions});

  factory TestSubmissionCatalog.empty() => const TestSubmissionCatalog(submissions: []);

  factory TestSubmissionCatalog.fromJson(Map<String, dynamic> json) => TestSubmissionCatalog(
        submissions: (json['submissions'] as List).cast<Map<String, dynamic>>().map(TestSubmission.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'submissions': [for (final s in submissions) s.toJson()]};
}
