/// One learner's generated report form Word document — Report Form
/// Pipeline Stage 10 onward. [signed] flips true only through
/// [GeneratedReportFormRepository.markSigned] (Stage 12's password-gated
/// Head Teacher approval); [docFileName]'s own bytes are re-embedded with
/// the signature image at that point, so the file on disk always reflects
/// whether it's actually signed — never just a flag with a stale document.
class GeneratedReportForm {
  final String id;
  final int classId;
  final int learnerId;
  final String learnerName;
  final String docFileName;
  final DateTime generatedAt;
  final String submissionHash;
  final bool signed;
  final DateTime? signedAt;
  final String? signedByName;

  const GeneratedReportForm({
    required this.id,
    required this.classId,
    required this.learnerId,
    required this.learnerName,
    required this.docFileName,
    required this.generatedAt,
    required this.submissionHash,
    this.signed = false,
    this.signedAt,
    this.signedByName,
  });

  GeneratedReportForm copyWith({
    String? docFileName,
    String? submissionHash,
    bool? signed,
    DateTime? signedAt,
    String? signedByName,
  }) =>
      GeneratedReportForm(
        id: id,
        classId: classId,
        learnerId: learnerId,
        learnerName: learnerName,
        docFileName: docFileName ?? this.docFileName,
        generatedAt: generatedAt,
        submissionHash: submissionHash ?? this.submissionHash,
        signed: signed ?? this.signed,
        signedAt: signedAt ?? this.signedAt,
        signedByName: signedByName ?? this.signedByName,
      );

  factory GeneratedReportForm.fromJson(Map<String, dynamic> json) => GeneratedReportForm(
        id: json['id'] as String,
        classId: json['classId'] as int,
        learnerId: json['learnerId'] as int,
        learnerName: json['learnerName'] as String,
        docFileName: json['docFileName'] as String,
        generatedAt: DateTime.parse(json['generatedAt'] as String),
        submissionHash: json['submissionHash'] as String,
        signed: json['signed'] as bool? ?? false,
        signedAt: json['signedAt'] == null ? null : DateTime.parse(json['signedAt'] as String),
        signedByName: json['signedByName'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'classId': classId,
        'learnerId': learnerId,
        'learnerName': learnerName,
        'docFileName': docFileName,
        'generatedAt': generatedAt.toIso8601String(),
        'submissionHash': submissionHash,
        'signed': signed,
        if (signedAt != null) 'signedAt': signedAt!.toIso8601String(),
        if (signedByName != null) 'signedByName': signedByName,
      };
}

class GeneratedReportFormCatalog {
  final List<GeneratedReportForm> reports;

  const GeneratedReportFormCatalog({required this.reports});

  factory GeneratedReportFormCatalog.empty() => const GeneratedReportFormCatalog(reports: []);

  factory GeneratedReportFormCatalog.fromJson(Map<String, dynamic> json) => GeneratedReportFormCatalog(
        reports: (json['reports'] as List).cast<Map<String, dynamic>>().map(GeneratedReportForm.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'reports': [for (final r in reports) r.toJson()]};
}
