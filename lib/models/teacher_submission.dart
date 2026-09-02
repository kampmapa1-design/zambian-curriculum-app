import 'package:cloud_firestore/cloud_firestore.dart';

enum SubmissionKind {
  assignment,
  test;

  static SubmissionKind fromDb(String value) =>
      SubmissionKind.values.firstWhere((k) => k.name == value, orElse: () => SubmissionKind.assignment);

  String get label => switch (this) {
        SubmissionKind.assignment => 'Assignment',
        SubmissionKind.test => 'Test',
      };
}

/// One file attached to a dashboard submission — [storagePath] is opaque
/// to the client; it's only ever handed back to `getSubmissionFileUrl`
/// (never used to construct a URL directly, since Cloud Storage access
/// is locked down to that one function — see storage.rules).
class SubmissionFile {
  final String filename;
  final String storagePath;

  const SubmissionFile({required this.filename, required this.storagePath});

  factory SubmissionFile.fromMap(Map<String, dynamic> map) => SubmissionFile(
        filename: map['filename'] as String? ?? '',
        storagePath: map['storagePath'] as String? ?? '',
      );
}

/// One row in the Teacher Submissions Dashboard (Stage 11) — mirrors the
/// `submissions` Firestore collection written by `submitToTeacherDashboard`.
/// Read-only from the client's side; nothing here is ever written back to
/// Firestore directly (see firestore.rules — client writes are refused
/// entirely, everything goes through Cloud Functions).
class TeacherSubmission {
  final String id;
  final SubmissionKind kind;
  final String studentName;
  final String className;
  final String subjectName;
  final String title;
  final DateTime submittedAt;
  final String sha256Hash;
  final String referenceInfo;
  final List<SubmissionFile> files;

  const TeacherSubmission({
    required this.id,
    required this.kind,
    required this.studentName,
    required this.className,
    required this.subjectName,
    required this.title,
    required this.submittedAt,
    required this.sha256Hash,
    required this.referenceInfo,
    required this.files,
  });

  factory TeacherSubmission.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final submittedAtRaw = data['submittedAt'];
    return TeacherSubmission(
      id: doc.id,
      kind: SubmissionKind.fromDb(data['kind'] as String? ?? 'assignment'),
      studentName: data['studentName'] as String? ?? '',
      className: data['className'] as String? ?? '',
      subjectName: data['subjectName'] as String? ?? '',
      title: data['title'] as String? ?? '',
      submittedAt: submittedAtRaw is String
          ? (DateTime.tryParse(submittedAtRaw) ?? DateTime.fromMillisecondsSinceEpoch(0))
          : DateTime.fromMillisecondsSinceEpoch(0),
      sha256Hash: data['sha256Hash'] as String? ?? '',
      referenceInfo: data['referenceInfo'] as String? ?? '',
      files: ((data['files'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SubmissionFile.fromMap)
          .toList(),
    );
  }
}
