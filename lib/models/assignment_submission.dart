/// The referencing/citation system a student's assignment uses — asked
/// once (Stage 3), passed into reference-page transcription so in-text
/// and bibliography formatting is preserved accurately rather than
/// guessed generically. [none] deliberately skips all reference-
/// formatting-aware processing rather than forcing a choice that isn't
/// true.
enum ReferenceSystem {
  apa,
  mla,
  harvard,
  chicago,
  endnoteFootnote,
  other,
  none;

  String get dbValue => name;

  static ReferenceSystem fromDb(String value) =>
      ReferenceSystem.values.firstWhere((r) => r.dbValue == value, orElse: () => ReferenceSystem.none);

  String get label => switch (this) {
        ReferenceSystem.apa => 'APA',
        ReferenceSystem.mla => 'MLA',
        ReferenceSystem.harvard => 'Harvard',
        ReferenceSystem.chicago => 'Chicago',
        ReferenceSystem.endnoteFootnote => 'Endnote/Footnote style',
        ReferenceSystem.other => 'Other',
        ReferenceSystem.none => 'No reference system used',
      };
}

/// Where one submission sits in the capture → consolidate → send pipeline.
enum AssignmentSubmissionStatus {
  draft,
  consolidated,
  sent;

  String get dbValue => name;

  static AssignmentSubmissionStatus fromDb(String value) => AssignmentSubmissionStatus.values
      .firstWhere((s) => s.dbValue == value, orElse: () => AssignmentSubmissionStatus.draft);
}

/// Mirrors `DocumentBlockType` from the existing handwriting-transcription
/// service (heading/subheading/paragraph/bullet/numbered) — Stage 2 asks
/// for exactly what `transcribeHandwrittenDocument` already provides, so
/// the client service maps its response onto this same shape rather than
/// this model layer depending on a service's own type.
enum AssignmentBodyBlockType { heading, subheading, paragraph, bullet, numbered }

/// One block of the transcribed main body (Stage 2), in reading order.
class AssignmentBodyBlock {
  final AssignmentBodyBlockType type;
  final String text;

  const AssignmentBodyBlock({required this.type, required this.text});

  Map<String, dynamic> toJson() => {'type': type.name, 'text': text};

  factory AssignmentBodyBlock.fromJson(Map<String, dynamic> json) => AssignmentBodyBlock(
        type: AssignmentBodyBlockType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => AssignmentBodyBlockType.paragraph,
        ),
        text: json['text'] as String? ?? '',
      );
}

/// One assignment submission, end to end: cover page (Stage 1), main body
/// (Stage 2), reference system choice (Stage 3), reference/bibliography
/// page (Stage 4), the consolidated PDF + image bundle + integrity record
/// (Stages 5-7), and transmission details (Stage 8-9). Stored fully
/// offline (see [AssignmentSubmissionRepository]) — every stage up to
/// transmission works with no connection at all.
class AssignmentSubmission {
  final String id;
  final DateTime createdAt;
  final AssignmentSubmissionStatus status;

  // Stage 1 — cover page, OCR-extracted then always student-editable.
  final String studentName;
  final String idNumber;
  final String course;
  final String subject;
  final String assignmentTitle;
  final String teacherName;
  final String date;
  final String institution;

  /// The original handwritten cover page photo's file name (relative to
  /// this submission's own subdirectory) — kept as-is (compressed but
  /// clear), never redrawn, alongside the templated fields above. Null
  /// until Stage 1's capture completes.
  final String? coverPhotoFileName;

  // Stage 2 — main body pages, and their AI transcription.
  final List<String> bodyPageFileNames;
  final List<AssignmentBodyBlock> transcribedBody;

  // Stage 3 — reference system choice.
  final ReferenceSystem referenceSystem;

  // Stage 4 — reference/bibliography page(s), and their transcription.
  final List<String> referencePageFileNames;

  /// Each transcribed reference/bibliography entry, in the order written
  /// — one string per entry, formatting (indentation, italics markers,
  /// punctuation) preserved exactly as the student wrote it, never
  /// corrected or completed. Empty when [referenceSystem] is
  /// [ReferenceSystem.none].
  final List<String> transcribedReferences;

  // Stage 5-6 — consolidation + integrity, set once the student reviews
  // and confirms.
  final String? pdfFileName;
  final String? imageBundleFileName;
  final String? sha256Hash;
  final DateTime? submittedAt;

  // Stage 8 — transmission.
  final String? teacherEmail;
  final String? teacherWhatsApp;
  final bool emailSent;
  final bool whatsAppShared;

  const AssignmentSubmission({
    required this.id,
    required this.createdAt,
    this.status = AssignmentSubmissionStatus.draft,
    this.studentName = '',
    this.idNumber = '',
    this.course = '',
    this.subject = '',
    this.assignmentTitle = '',
    this.teacherName = '',
    this.date = '',
    this.institution = '',
    this.coverPhotoFileName,
    this.bodyPageFileNames = const [],
    this.transcribedBody = const [],
    this.referenceSystem = ReferenceSystem.none,
    this.referencePageFileNames = const [],
    this.transcribedReferences = const [],
    this.pdfFileName,
    this.imageBundleFileName,
    this.sha256Hash,
    this.submittedAt,
    this.teacherEmail,
    this.teacherWhatsApp,
    this.emailSent = false,
    this.whatsAppShared = false,
  });

  AssignmentSubmission copyWith({
    AssignmentSubmissionStatus? status,
    String? studentName,
    String? idNumber,
    String? course,
    String? subject,
    String? assignmentTitle,
    String? teacherName,
    String? date,
    String? institution,
    String? coverPhotoFileName,
    List<String>? bodyPageFileNames,
    List<AssignmentBodyBlock>? transcribedBody,
    ReferenceSystem? referenceSystem,
    List<String>? referencePageFileNames,
    List<String>? transcribedReferences,
    String? pdfFileName,
    String? imageBundleFileName,
    String? sha256Hash,
    DateTime? submittedAt,
    String? teacherEmail,
    String? teacherWhatsApp,
    bool? emailSent,
    bool? whatsAppShared,
  }) =>
      AssignmentSubmission(
        id: id,
        createdAt: createdAt,
        status: status ?? this.status,
        studentName: studentName ?? this.studentName,
        idNumber: idNumber ?? this.idNumber,
        course: course ?? this.course,
        subject: subject ?? this.subject,
        assignmentTitle: assignmentTitle ?? this.assignmentTitle,
        teacherName: teacherName ?? this.teacherName,
        date: date ?? this.date,
        institution: institution ?? this.institution,
        coverPhotoFileName: coverPhotoFileName ?? this.coverPhotoFileName,
        bodyPageFileNames: bodyPageFileNames ?? this.bodyPageFileNames,
        transcribedBody: transcribedBody ?? this.transcribedBody,
        referenceSystem: referenceSystem ?? this.referenceSystem,
        referencePageFileNames: referencePageFileNames ?? this.referencePageFileNames,
        transcribedReferences: transcribedReferences ?? this.transcribedReferences,
        pdfFileName: pdfFileName ?? this.pdfFileName,
        imageBundleFileName: imageBundleFileName ?? this.imageBundleFileName,
        sha256Hash: sha256Hash ?? this.sha256Hash,
        submittedAt: submittedAt ?? this.submittedAt,
        teacherEmail: teacherEmail ?? this.teacherEmail,
        teacherWhatsApp: teacherWhatsApp ?? this.teacherWhatsApp,
        emailSent: emailSent ?? this.emailSent,
        whatsAppShared: whatsAppShared ?? this.whatsAppShared,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'status': status.dbValue,
        'studentName': studentName,
        'idNumber': idNumber,
        'course': course,
        'subject': subject,
        'assignmentTitle': assignmentTitle,
        'teacherName': teacherName,
        'date': date,
        'institution': institution,
        'coverPhotoFileName': coverPhotoFileName,
        'bodyPageFileNames': bodyPageFileNames,
        'transcribedBody': transcribedBody.map((b) => b.toJson()).toList(),
        'referenceSystem': referenceSystem.dbValue,
        'referencePageFileNames': referencePageFileNames,
        'transcribedReferences': transcribedReferences,
        'pdfFileName': pdfFileName,
        'imageBundleFileName': imageBundleFileName,
        'sha256Hash': sha256Hash,
        'submittedAt': submittedAt?.toIso8601String(),
        'teacherEmail': teacherEmail,
        'teacherWhatsApp': teacherWhatsApp,
        'emailSent': emailSent,
        'whatsAppShared': whatsAppShared,
      };

  factory AssignmentSubmission.fromJson(Map<String, dynamic> json) => AssignmentSubmission(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        status: AssignmentSubmissionStatus.fromDb(json['status'] as String? ?? 'draft'),
        studentName: json['studentName'] as String? ?? '',
        idNumber: json['idNumber'] as String? ?? '',
        course: json['course'] as String? ?? '',
        subject: json['subject'] as String? ?? '',
        assignmentTitle: json['assignmentTitle'] as String? ?? '',
        teacherName: json['teacherName'] as String? ?? '',
        date: json['date'] as String? ?? '',
        institution: json['institution'] as String? ?? '',
        coverPhotoFileName: json['coverPhotoFileName'] as String?,
        bodyPageFileNames: (json['bodyPageFileNames'] as List?)?.cast<String>() ?? const [],
        transcribedBody: (json['transcribedBody'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map(AssignmentBodyBlock.fromJson)
                .toList() ??
            const [],
        referenceSystem: ReferenceSystem.fromDb(json['referenceSystem'] as String? ?? 'none'),
        referencePageFileNames: (json['referencePageFileNames'] as List?)?.cast<String>() ?? const [],
        transcribedReferences: (json['transcribedReferences'] as List?)?.cast<String>() ?? const [],
        pdfFileName: json['pdfFileName'] as String?,
        imageBundleFileName: json['imageBundleFileName'] as String?,
        sha256Hash: json['sha256Hash'] as String?,
        submittedAt: json['submittedAt'] != null ? DateTime.parse(json['submittedAt'] as String) : null,
        teacherEmail: json['teacherEmail'] as String?,
        teacherWhatsApp: json['teacherWhatsApp'] as String?,
        emailSent: json['emailSent'] as bool? ?? false,
        whatsAppShared: json['whatsAppShared'] as bool? ?? false,
      );
}

class AssignmentSubmissionCatalog {
  final List<AssignmentSubmission> submissions;

  const AssignmentSubmissionCatalog({required this.submissions});

  factory AssignmentSubmissionCatalog.empty() => const AssignmentSubmissionCatalog(submissions: []);

  factory AssignmentSubmissionCatalog.fromJson(Map<String, dynamic> json) => AssignmentSubmissionCatalog(
        submissions:
            (json['submissions'] as List).cast<Map<String, dynamic>>().map(AssignmentSubmission.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'submissions': [for (final s in submissions) s.toJson()]};
}
