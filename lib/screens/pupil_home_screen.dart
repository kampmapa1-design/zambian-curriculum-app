import 'package:flutter/material.dart';

import '../models/national_exam_timetable.dart';
import '../models/zambian_term_calendar.dart';
import '../services/national_exam_timetable_service.dart';
import '../services/pupil_ad_gate_service.dart';
import '../services/term_countdown.dart';
import '../widgets/firebase_unavailable_banner.dart';
import '../widgets/function_button.dart';
import 'account_settings_screen.dart';
import 'assignment_submission_screen.dart';
import 'cdc_resources_screen.dart';
import 'countdown_result_screen.dart';
import 'home_assignment_pupil_screen.dart';
import 'join_class_pupil_screen.dart';
import 'sugo_library_screen.dart';
import 'syllabus_inspection_screen.dart';
import 'test_submission_screen.dart';

/// Home Assignment epic, Stage 2 (added 2026-09-14) — the distinct home
/// screen a Pupil-role account sees instead of [HomeScreen]. Per the
/// brief: "Hide teacher-only tools... from this view entirely, rather
/// than just disabling them" — so this is its own screen with its own
/// short tile list, not [HomeScreen] with things greyed out.
///
/// Learner-side ad gate (added 2026-09-17, per explicit request): every
/// tile here requires watching two 60-second video ads to open, except
/// "Join a Class" — the one action that connects a pupil to their
/// teacher in the first place, so it can never sit behind anything — and
/// "Countdown", "Syllabus Inspection" and "Sugo Library" (all added
/// 2026-09-29), which cost the app nothing to READ: Countdown/Syllabus
/// Inspection are pure on-device/bundled-data, and Sugo Library's notes
/// are pre-generated once offline (see SugoLibraryService) — every read
/// here is an ordinary Firestore get, not a live AI call, so gating it
/// behind an ad would cost the pupil something for a feature that costs
/// the app nothing at read time. See [PupilAdGateService] for the
/// session-wide unlock this wraps every gated tile's tap with.
class PupilHomeScreen extends StatelessWidget {
  const PupilHomeScreen({super.key});

  Future<void> _openGated(BuildContext context, WidgetBuilder builder) async {
    final unlocked = await PupilAdGateService.instance.ensureUnlocked(context);
    if (!unlocked || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: builder));
  }

  /// "Countdown" (owner request, 2026-09-29) — free: pure on-device date
  /// arithmetic against the real Ministry term calendar already bundled
  /// for the Scheme of Work engine, no AI/network call, so it's never
  /// behind the ad gate — same treatment as "Join a Class".
  ///
  /// "Countdown to National Exams" stays disabled until the owner has set
  /// a real national exam start date (see NationalExamTimetableAdminScreen)
  /// — checked fresh every time this menu opens, via the same shared
  /// Firestore doc every learner reads, so it's never stale.
  Future<void> _showCountdownMenu(BuildContext context) async {
    final examTimetable = await NationalExamTimetableService().fetch();
    if (!context.mounted) return;
    final year = examTimetable?.year ?? DateTime.now().year;

    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Countdown'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('term'),
            child: const ListTile(
              leading: Icon(Icons.school_outlined),
              title: Text('Countdown Term?'),
              subtitle: Text('Days left until the current term ends'),
            ),
          ),
          SimpleDialogOption(
            onPressed: examTimetable == null ? null : () => Navigator.of(dialogContext).pop('exams'),
            child: ListTile(
              enabled: examTimetable != null,
              leading: const Icon(Icons.event_note_outlined),
              title: Text('Countdown to $year National Exams?'),
              subtitle: Text(
                examTimetable == null
                    ? 'Not available yet — needs a national exam timetable added first'
                    : 'Starts ${examTimetable.startDate.day}/${examTimetable.startDate.month}/${examTimetable.startDate.year}',
              ),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == 'term') _showTermCountdown(context);
    if (choice == 'exams' && examTimetable != null) _showExamCountdown(context, examTimetable);
  }

  void _showTermCountdown(BuildContext context) {
    final countdown = currentTermCountdown(DateTime.now());
    final d = countdown.referenceDate;
    final target = DateTime(d.year, d.month, d.day, 23, 59, 59);
    final subtitle = countdown.isCurrentlyInTerm
        ? 'Term ${countdown.termNumber} ends ${d.day}/${d.month}/${d.year}'
        : "You're on holiday — Term ${countdown.termNumber} of ${countdown.year} starts ${d.day}/${d.month}/${d.year}";
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CountdownResultScreen(
        title: 'Term Countdown',
        daysRemaining: countdown.daysRemaining,
        targetDate: target,
        subtitle: subtitle,
      ),
    ));
  }

  void _showExamCountdown(BuildContext context, NationalExamTimetable timetable) {
    final days = daysUntilExcludingPublicHolidays(DateTime.now(), timetable.startDate);
    final d = timetable.startDate;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CountdownResultScreen(
        title: '${timetable.year} National Exams',
        daysRemaining: days,
        targetDate: DateTime(d.year, d.month, d.day),
        subtitle: 'Exams start ${d.day}/${d.month}/${d.year}',
        isExamCountdown: true,
        examEndDate: timetable.endDate,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // "Smart Learner" here only — the pupil-facing side of the SAME
        // app, per explicit request 2026-09-28. Nothing else about this
        // screen (functions, navigation, the app's own package/launcher
        // name) changes; this is purely the in-app title shown while a
        // learner is using it.
        title: const Text('Smart Learner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountSettingsScreen())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const FirebaseUnavailableBanner(),
          FunctionButton(
            icon: Icons.assignment_turned_in_outlined,
            label: 'Assignment Submission',
            subtitle: 'Photograph a handwritten assignment and send it to your teacher, with proof of submission',
            onTap: () => _openGated(context, (_) => const AssignmentSubmissionScreen()),
          ),
          FunctionButton(
            icon: Icons.quiz_outlined,
            label: 'Test Submission',
            subtitle: 'Photograph a handwritten test and send it to your teacher/lecturer, with proof of submission',
            onTap: () => _openGated(context, (_) => const TestSubmissionScreen()),
          ),
          FunctionButton(
            icon: Icons.home_work_outlined,
            label: 'Home Assignment',
            subtitle: "Assignments your subject teachers have sent you",
            onTap: () => _openGated(context, (_) => const HomeAssignmentPupilScreen()),
          ),
          FunctionButton(
            icon: Icons.description_outlined,
            label: 'ECZ Past Papers',
            subtitle: 'Download real past examination papers from the Examinations Council of Zambia',
            onTap: () => _openGated(
              context,
              (_) => const CdcResourcesScreen(resourceType: 'past_paper', title: 'ECZ Past Papers', showDatabaseOption: false),
            ),
          ),
          FunctionButton(
            icon: Icons.group_add_outlined,
            label: 'Join a Class',
            subtitle: 'Link your account to your school and class, so assignments reach you here',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const JoinClassPupilScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.hourglass_bottom_outlined,
            label: 'Countdown',
            subtitle: 'See how many days are left before the final examinations and how many days to go before the term ends',
            onTap: () => _showCountdownMenu(context),
          ),
          FunctionButton(
            icon: Icons.list_alt_outlined,
            label: 'Syllabus Inspection',
            subtitle: "See your subject's planned topic order — needs a joined class",
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SyllabusInspectionScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.menu_book_outlined,
            label: 'Sugo Library',
            subtitle: 'Bite-sized study notes and quick recall questions, downloadable for offline reading',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SugoLibraryScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
