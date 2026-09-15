import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

/// A teacher's role within a school's [School] network (Stage 3 of the
/// School Network brief, 2026-09-13). String values match exactly what the
/// Cloud Functions (`registerSchool`/`joinSchoolByCode`/
/// `updateSchoolMemberRole`) write server-side and what Firestore security
/// rules key off via the caller's `schoolRole` custom claim — never rename
/// these without updating firebase/functions/src/index.ts to match.
enum SchoolRole {
  teacher,
  gradeTeacher,
  headTeacher,
  deputy,
  administrator,
  observer;

  String get wireValue => switch (this) {
        SchoolRole.teacher => 'teacher',
        SchoolRole.gradeTeacher => 'grade_teacher',
        SchoolRole.headTeacher => 'head_teacher',
        SchoolRole.deputy => 'deputy',
        SchoolRole.administrator => 'administrator',
        SchoolRole.observer => 'observer',
      };

  String get label => switch (this) {
        SchoolRole.teacher => 'Teacher',
        SchoolRole.gradeTeacher => 'Grade Teacher',
        SchoolRole.headTeacher => 'Head Teacher',
        SchoolRole.deputy => 'Deputy Head Teacher',
        SchoolRole.administrator => 'Administrator',
        SchoolRole.observer => 'Observer',
      };

  bool get isLeadership => this == SchoolRole.headTeacher || this == SchoolRole.deputy;

  static SchoolRole fromWire(String? value) => switch (value) {
        'grade_teacher' => SchoolRole.gradeTeacher,
        'head_teacher' => SchoolRole.headTeacher,
        'deputy' => SchoolRole.deputy,
        'administrator' => SchoolRole.administrator,
        'observer' => SchoolRole.observer,
        _ => SchoolRole.teacher,
      };
}

/// Timetable Generation, Stage 9 — mirrors `callerCanManageTimetable` in
/// index.ts: leadership, administrator, or a co-opted Timetable Operator.
bool canManageTimetable(SchoolRole? role, bool isTimetableOperator) =>
    role?.isLeadership == true || role == SchoolRole.administrator || isTimetableOperator;

/// The real three-tier subscription structure decided 2026-09-14: Basic
/// (K70/month), Gold (K150/month), Institutional/Platinum (price not yet
/// set — see project memory). Ordered so `.index` comparison works for
/// "this tier or higher" gates like Timetable Generation's Gold+
/// requirement.
enum SubscriptionTier {
  basic,
  gold,
  institutional;

  String get wireValue => switch (this) {
        SubscriptionTier.basic => 'basic',
        SubscriptionTier.gold => 'gold',
        SubscriptionTier.institutional => 'institutional',
      };

  String get label => switch (this) {
        SubscriptionTier.basic => 'Basic',
        SubscriptionTier.gold => 'Gold',
        SubscriptionTier.institutional => 'Institutional',
      };

  static SubscriptionTier fromWire(String? value) => switch (value) {
        'gold' => SubscriptionTier.gold,
        'institutional' => SubscriptionTier.institutional,
        _ => SubscriptionTier.basic,
      };
}

/// A registered school (Firestore `schools/{schoolId}`) — see
/// `registerSchool` in firebase/functions/src/index.ts for how this is
/// created; clients never write this document directly.
class School {
  final String id;
  final String name;
  final String province;
  final String district;
  final String headTeacherName;
  final String code;
  final bool institutionalSubscription;

  /// The real subscription tier (added 2026-09-14, see
  /// project_smart_teacher_subscription_tiers memory) — set manually via
  /// Firebase Console for now, same pattern as [institutionalSubscription]
  /// itself. Backward-compatible with schools set up before this field
  /// existed: [School.fromMap] falls back to treating
  /// `institutionalSubscription: true` as [SubscriptionTier.institutional]
  /// when `subscriptionTier` isn't set, so an existing paid school doesn't
  /// lose Gold-gated access (Timetable Generation) just because this field
  /// is new.
  final SubscriptionTier subscriptionTier;

  bool get hasTimetableAccess => subscriptionTier.index >= SubscriptionTier.gold.index;

  /// Stage 5's Mid-Term Results Window (minimal version, added
  /// 2026-09-14) — null means no Head Teacher/Deputy has set one yet.
  /// Duration is fixed at the brief's own default (2 weeks) for now; see
  /// `setMidTermWindow` in index.ts for why an adjustable duration isn't
  /// built yet.
  final DateTime? midTermWindowStart;
  final int midTermWindowDurationDays;

  const School({
    required this.id,
    required this.name,
    required this.province,
    required this.district,
    required this.headTeacherName,
    required this.code,
    required this.institutionalSubscription,
    this.subscriptionTier = SubscriptionTier.basic,
    this.midTermWindowStart,
    this.midTermWindowDurationDays = 14,
  });

  DateTime? get midTermWindowEnd =>
      midTermWindowStart?.add(Duration(days: midTermWindowDurationDays));

  factory School.fromMap(String id, Map<String, dynamic> data) => School(
        id: id,
        name: data['name'] as String? ?? '',
        province: data['province'] as String? ?? '',
        district: data['district'] as String? ?? '',
        headTeacherName: data['headTeacherName'] as String? ?? '',
        code: data['code'] as String? ?? '',
        institutionalSubscription: data['institutionalSubscription'] as bool? ?? false,
        subscriptionTier: data['subscriptionTier'] != null
            ? SubscriptionTier.fromWire(data['subscriptionTier'] as String?)
            : ((data['institutionalSubscription'] as bool? ?? false) ? SubscriptionTier.institutional : SubscriptionTier.basic),
        midTermWindowStart: (data['midTermWindowStart'] as Timestamp?)?.toDate(),
        midTermWindowDurationDays: (data['midTermWindowDurationDays'] as num?)?.toInt() ?? 14,
      );
}

/// One teacher's membership record within a school (Firestore
/// `schools/{schoolId}/members/{uid}`).
class SchoolMember {
  final String uid;
  final String name;
  final SchoolRole role;
  final List<String> classIds;

  /// Timetable Generation, Stage 9 — a co-opted "Timetable Operator":
  /// granted the same timetable-management rights as leadership, without
  /// any other leadership power. Set only via `setTimetableOperator`.
  final bool timetableOperator;

  const SchoolMember({
    required this.uid,
    required this.name,
    required this.role,
    required this.classIds,
    this.timetableOperator = false,
  });

  factory SchoolMember.fromMap(String uid, Map<String, dynamic> data) => SchoolMember(
        uid: uid,
        name: data['name'] as String? ?? '',
        role: SchoolRole.fromWire(data['role'] as String?),
        classIds: (data['classIds'] as List?)?.whereType<String>().toList() ?? const [],
        timetableOperator: data['timetableOperator'] as bool? ?? false,
      );
}

/// A class connected to the School Network's shared registry
/// (`schools/{schoolId}/classes/{classId}`) — Milestone B1, added
/// 2026-09-13. This is the real, cross-device identity the Report Form
/// Pipeline's purely-local `ReportClass` links to (see
/// `ReportClass.firestoreClassId`) so a subject teacher's own device can
/// write into the right class/subject without needing to already know
/// the Grade Teacher's local SQLite row id (which means nothing off that
/// one device).
class SchoolClass {
  final String id;
  final String classGrade;
  final String term;
  final String gradeTeacherUid;
  final String gradeTeacherName;
  final List<String> learnerNames;
  final List<String> subjectNames;
  final Map<String, String> subjectTeacherUids; // subjectName -> uid

  /// Home Assignment epic, Stage 1/7/8 (added 2026-09-14) — a real link
  /// between a pupil's own signed-in account and one slot in
  /// [learnerNames], keyed by that same name (mirrors
  /// [subjectTeacherUids]'s own "parallel map keyed by an existing list's
  /// entry" shape). Set only by `respondToPupilClassLink` once a teacher
  /// confirms a pupil's join request — see that Cloud Function's own
  /// comment. Empty for a class with no linked pupils yet (every class
  /// before this field existed, or one nobody has joined in-app).
  final Map<String, String> learnerUids; // learnerName -> pupil uid

  const SchoolClass({
    required this.id,
    required this.classGrade,
    required this.term,
    required this.gradeTeacherUid,
    required this.gradeTeacherName,
    required this.learnerNames,
    required this.subjectNames,
    required this.subjectTeacherUids,
    this.learnerUids = const {},
  });

  factory SchoolClass.fromMap(String id, Map<String, dynamic> data) => SchoolClass(
        id: id,
        classGrade: data['classGrade'] as String? ?? '',
        term: data['term'] as String? ?? '',
        gradeTeacherUid: data['gradeTeacherUid'] as String? ?? '',
        gradeTeacherName: data['gradeTeacherName'] as String? ?? '',
        learnerNames: (data['learnerNames'] as List?)?.whereType<String>().toList() ?? const [],
        subjectNames: (data['subjectNames'] as List?)?.whereType<String>().toList() ?? const [],
        subjectTeacherUids: (data['subjectTeacherUids'] as Map?)?.cast<String, String>() ?? const {},
        learnerUids: (data['learnerUids'] as Map?)?.cast<String, String>() ?? const {},
      );

  String get label => '$classGrade ($term)';
}

/// One subject teacher's score entry for one learner (Firestore
/// `schools/{schoolId}/classes/{classId}/scoreEntries/{entryId}`) —
/// School Network Milestone B2, added 2026-09-13. [editHistory] is the
/// real audit trail Stage 6 requires: every edit by someone OTHER than
/// the entry's own creator appends here (see `submitClassScoreEntry` in
/// index.ts) — the entry's own creator editing their own number does not.
class ScoreEntryEdit {
  final String editedByName;
  final DateTime? editedAt;
  final double previousScore;
  final String previousComment;

  const ScoreEntryEdit({
    required this.editedByName,
    required this.editedAt,
    required this.previousScore,
    required this.previousComment,
  });

  factory ScoreEntryEdit.fromMap(Map<String, dynamic> data) => ScoreEntryEdit(
        editedByName: data['editedByName'] as String? ?? '',
        editedAt: (data['editedAt'] as Timestamp?)?.toDate(),
        previousScore: (data['previousScore'] as num?)?.toDouble() ?? 0,
        previousComment: data['previousComment'] as String? ?? '',
      );
}

class ScoreEntry {
  final String id;
  final int learnerIndex;
  final String learnerName;
  final String subjectName;
  final double score;
  final String comment;
  final String submittedByUid;
  final String submittedByName;
  final String lastEditedByName;
  final DateTime? submittedAt;
  final List<ScoreEntryEdit> editHistory;

  const ScoreEntry({
    required this.id,
    required this.learnerIndex,
    required this.learnerName,
    required this.subjectName,
    required this.score,
    required this.comment,
    required this.submittedByUid,
    required this.submittedByName,
    required this.lastEditedByName,
    required this.submittedAt,
    required this.editHistory,
  });

  factory ScoreEntry.fromMap(String id, Map<String, dynamic> data) => ScoreEntry(
        id: id,
        learnerIndex: (data['learnerIndex'] as num?)?.toInt() ?? 0,
        learnerName: data['learnerName'] as String? ?? '',
        subjectName: data['subjectName'] as String? ?? '',
        score: (data['score'] as num?)?.toDouble() ?? 0,
        comment: data['comment'] as String? ?? '',
        submittedByUid: data['submittedByUid'] as String? ?? '',
        submittedByName: data['submittedByName'] as String? ?? '',
        lastEditedByName: data['lastEditedByName'] as String? ?? '',
        submittedAt: (data['submittedAt'] as Timestamp?)?.toDate(),
        editHistory:
            (data['editHistory'] as List?)?.map((e) => ScoreEntryEdit.fromMap((e as Map).cast<String, dynamic>())).toList() ??
                const [],
      );
}

/// One Staffroom post (Stage 10 of School Network, added 2026-09-13) —
/// `schools/{schoolId}/staffroom/{postId}`. Unlike the rest of School
/// Network, clients write these directly (see firestore.rules) — there's
/// no real business-rule enforcement a post needs beyond "are you a
/// member" and "is this your own post, or are you leadership".
class StaffroomPost {
  final String id;
  final String authorUid;
  final String authorName;
  final String text;
  final String topic;
  final bool pinned;
  final DateTime? createdAt;

  const StaffroomPost({
    required this.id,
    required this.authorUid,
    required this.authorName,
    required this.text,
    required this.topic,
    required this.pinned,
    required this.createdAt,
  });

  factory StaffroomPost.fromMap(String id, Map<String, dynamic> data) => StaffroomPost(
        id: id,
        authorUid: data['authorUid'] as String? ?? '',
        authorName: data['authorName'] as String? ?? '',
        text: data['text'] as String? ?? '',
        topic: data['topic'] as String? ?? 'General',
        pinned: data['pinned'] as bool? ?? false,
        createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      );
}

/// The real Zambian provinces — used for the Register School form's
/// dropdown rather than a free-text field, per the "never fabricate data"
/// rule: this is real geography, not a guessed list.
const List<String> kZambianProvinces = [
  'Central',
  'Copperbelt',
  'Eastern',
  'Luapula',
  'Lusaka',
  'Muchinga',
  'Northern',
  'North-Western',
  'Southern',
  'Western',
];
