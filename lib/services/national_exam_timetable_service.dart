import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/national_exam_timetable.dart';
import '../models/school.dart';
import 'auth_service.dart';
import 'school_service.dart';

class NationalExamTimetableUnavailable implements Exception {
  final String message;
  const NationalExamTimetableUnavailable(this.message);
  @override
  String toString() => message;
}

/// One AI-read attempt at a national exam timetable's own start date —
/// never trusted until [NationalExamTimetableAdminScreen]'s review step
/// confirms it. [found] false means the date genuinely wasn't legible on
/// the page; never a guessed fallback.
class ExtractedExamStartDate {
  final bool found;
  final DateTime? startDate;
  final bool foundEnd;
  final DateTime? endDate;
  final String examName;
  final String notes;

  const ExtractedExamStartDate({
    required this.found,
    this.startDate,
    this.foundEnd = false,
    this.endDate,
    required this.examName,
    required this.notes,
  });
}

/// Who may open the admin screen and save — resolved once at bootstrap.
/// [schoolId] is only ever non-null for the institutional-admin path (the
/// owner path needs no schoolId at all, see `saveNationalExamTimetable`'s
/// own server-side gate for why).
class NationalExamTimetableAccess {
  final bool isOwner;
  final bool isInstitutionalAdmin;
  final String? schoolId;

  const NationalExamTimetableAccess({required this.isOwner, required this.isInstitutionalAdmin, this.schoolId});

  bool get allowed => isOwner || isInstitutionalAdmin;
}

/// "Fix 6" (owner request, 2026-09-29) — the national exam timetable
/// that gates the learner-facing "Countdown to [year] National Exams?"
/// option. Three real steps, never skipped: (1) [extractStartDate] reads a
/// real uploaded soft copy via the same one-time, low-cost AI-extraction
/// pattern as every other document-reading feature in this app — never
/// authoritative on its own; (2) the admin screen shows that extracted
/// date for a human to actually look at; (3) only on explicit confirmation
/// does [save] write it. Widened 2026-09-29 (owner request): the app owner
/// can always save, and so can a school's own leadership/administrator once
/// that school carries a real Institutional subscription — see
/// `saveNationalExamTimetable`'s own `requireOwnerOrInstitutionalAdmin`
/// gate server-side, since this is one shared date every learner
/// nationwide would see, not a per-account setting. [fetch] needs no
/// callable at all: the saved document is readable directly by any
/// signed-in user (see firestore.rules), same as `appConfig/markingCredits`.
class NationalExamTimetableService {
  NationalExamTimetableService({FirebaseFunctions? functions, FirebaseFirestore? firestore, SchoolService? schoolService})
      : _functions = functions,
        _firestore = firestore,
        _schoolService = schoolService;

  final FirebaseFunctions? _functions;
  final FirebaseFirestore? _firestore;
  final SchoolService? _schoolService;
  SchoolService get _schools => _schoolService ?? SchoolService();

  FirebaseFunctions get _fn => _functions ?? FirebaseFunctions.instance;
  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  Future<NationalExamTimetable?> fetch() async {
    await AuthService.instance.ensureSignedIn();
    final doc = await _db.collection('appConfig').doc('nationalExamTimetable').get();
    final data = doc.data();
    if (data == null) return null;
    try {
      return NationalExamTimetable.fromMap(data);
    } catch (_) {
      return null;
    }
  }

  Future<ExtractedExamStartDate> extractStartDate(File file) async {
    await AuthService.instance.ensureSignedIn();
    final ext = file.path.split('.').last.toLowerCase();
    final mimeType = switch (ext) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      _ => 'image/jpeg',
    };
    final callable = _fn.httpsCallable(
      'extractNationalExamStartDate',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );
    try {
      final bytes = await file.readAsBytes();
      final result = await callable.call<Map<Object?, Object?>>({
        'fileBase64': base64Encode(bytes),
        'mimeType': mimeType,
      });
      final data = result.data;
      final found = data['found'] as bool? ?? false;
      final startDateIso = data['startDateIso'] as String?;
      final foundEnd = data['foundEnd'] as bool? ?? false;
      final endDateIso = data['endDateIso'] as String?;
      return ExtractedExamStartDate(
        found: found,
        startDate: found && startDateIso != null && startDateIso.isNotEmpty ? DateTime.tryParse(startDateIso) : null,
        foundEnd: foundEnd,
        endDate: foundEnd && endDateIso != null && endDateIso.isNotEmpty ? DateTime.tryParse(endDateIso) : null,
        examName: data['examName'] as String? ?? '',
        notes: data['notes'] as String? ?? '',
      );
    } on FirebaseFunctionsException catch (e) {
      throw NationalExamTimetableUnavailable(e.message ?? 'Could not read the timetable.');
    }
  }

  Future<void> save({required int year, required DateTime startDate, DateTime? endDate, String? schoolId}) async {
    await AuthService.instance.ensureSignedIn();
    final callable = _fn.httpsCallable('saveNationalExamTimetable');
    try {
      await callable.call<Map<Object?, Object?>>({
        'year': year,
        'startDateIso': startDate.toIso8601String().split('T').first,
        if (endDate != null) 'endDateIso': endDate.toIso8601String().split('T').first,
        if (schoolId != null) 'schoolId': schoolId,
      });
    } on FirebaseFunctionsException catch (e) {
      throw NationalExamTimetableUnavailable(e.message ?? 'Could not save the timetable.');
    }
  }

  /// Whether this signed-in account is the app owner — same `amIOwner`
  /// callable the web dashboard already uses, reused here so the admin
  /// screen never has to guess or duplicate that check.
  Future<bool> isOwner() async {
    await AuthService.instance.ensureSignedIn();
    try {
      final result = await _fn.httpsCallable('amIOwner').call<Object?>();
      final data = result.data;
      return data is Map && data['isOwner'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Widened access (owner request, 2026-09-29): owner OR a school's own
  /// leadership/administrator with an Institutional subscription. This is
  /// only a CLIENT-SIDE convenience for deciding what to show — the real
  /// permission decision is always re-checked server-side against
  /// Firestore's own school membership/tier data, never trusted from this
  /// account's own (possibly stale) custom-claims token — see
  /// `requireOwnerOrInstitutionalAdmin` in index.ts.
  Future<NationalExamTimetableAccess> checkAccess() async {
    await AuthService.instance.ensureSignedIn();
    if (await isOwner()) {
      return const NationalExamTimetableAccess(isOwner: true, isInstitutionalAdmin: false);
    }
    final claim = await _schools.currentSchoolClaim();
    final schoolId = claim.schoolId;
    final role = claim.role;
    if (schoolId == null || role == null) {
      return const NationalExamTimetableAccess(isOwner: false, isInstitutionalAdmin: false);
    }
    final isSchoolAdminRole = role.isLeadership || role == SchoolRole.administrator;
    if (!isSchoolAdminRole) {
      return NationalExamTimetableAccess(isOwner: false, isInstitutionalAdmin: false, schoolId: schoolId);
    }
    final school = await _schools.getSchool(schoolId);
    final institutional = school != null &&
        (school.subscriptionTier == SubscriptionTier.institutional || school.institutionalSubscription);
    return NationalExamTimetableAccess(isOwner: false, isInstitutionalAdmin: institutional, schoolId: schoolId);
  }
}
