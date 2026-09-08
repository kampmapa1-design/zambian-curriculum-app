import '../models/lesson_checkpoint.dart';
import '../models/report_class.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'cdc_resources_service.dart';
import 'lesson_checkpoint_repository.dart';
import 'report_class_repository.dart';
import 'scheme_of_work_calendar_pacing.dart';
import 'template_repository.dart';
import 'topic_search_service.dart';
import 'voice_command_service.dart';

/// Why a command couldn't be resolved at all — shown back to the teacher
/// so a mic misfire is diagnosable rather than a silent no-op.
class VoiceCommandResolutionError implements Exception {
  final String message;
  const VoiceCommandResolutionError(this.message);
  @override
  String toString() => message;
}

/// What a voice command resolved to against this app's REAL data — a
/// sealed hierarchy (2026-09-08) because the growing set of real actions
/// no longer share one shape: a syllabus topic, a class roster, a CDC
/// catalog count, and a marking-assistant launch are genuinely different
/// things, and forcing them into one shared class was starting to hide
/// which fields actually apply to which action.
sealed class VoiceCommandOutcome {
  final ParsedVoiceCommand parsed;
  const VoiceCommandOutcome({required this.parsed});
}

/// Every real syllabus-topic action resolves to this: [VoiceCommandAction
/// .generateLessonPlan], [.generateSchemeOfWork], [.generateRecordOfWork],
/// [.generateTeachingNotes], and [.findTopic] (a pure lookup). [term]/
/// [entry] are best-effort — a command that named a subject/grade but no
/// topic/week/keyword still resolves [template] alone, letting the caller
/// fall back to its own normal topic picker for the one thing voice
/// didn't specify, rather than failing the whole command.
class TopicOutcome extends VoiceCommandOutcome {
  final SyllabusTemplate template;
  final Term? term;
  final SchemeOfWorkEntry? entry;

  /// Non-null only when a [ParsedVoiceCommand.topicKeyword] search came
  /// back ambiguous — more than one real topic plausibly matches, and none
  /// of them was confident enough to pick automatically (see
  /// [TopicSearchService.searchWithinTemplate]'s own "precise" rule). The
  /// UI shows these as an activatable short list; picking one produces a
  /// fresh [TopicOutcome] with [entry]/[term] set and [candidates] null.
  final List<TopicSearchResult>? candidates;

  const TopicOutcome({required super.parsed, required this.template, this.term, this.entry, this.candidates});
}

/// [VoiceCommandAction.openClassRoster] — resolves [ParsedVoiceCommand
/// .className] against the teacher's real classes in the Grade
/// Teacher/Report Form pipeline. [matchedClass] is null when nothing
/// matched (or no class name was even said and more than one class
/// exists) — [allClasses] lets the caller show what IS available instead
/// of a dead end.
class ClassRosterOutcome extends VoiceCommandOutcome {
  final ReportClass? matchedClass;
  final List<ReportClass> allClasses;
  const ClassRosterOutcome({required super.parsed, this.matchedClass, required this.allClasses});
}

/// [VoiceCommandAction.checkCdcMaterials] — a real count from
/// [CdcResourcesService.unseenCount], already scoped to
/// [ParsedVoiceCommand.subjectName] when one was said.
class CdcCheckOutcome extends VoiceCommandOutcome {
  final int unseenCount;
  const CdcCheckOutcome({required super.parsed, required this.unseenCount});
}

/// [VoiceCommandAction.resumeLesson] — the single most recently paused
/// lesson across every subject (see [LessonCheckpointRepository
/// .findMostRecentOverall]), already resolved to a real, loaded
/// [template]/[term]/[entry] so the caller can jump straight into the
/// lesson plan screen's own "Resume this lesson?" flow. [checkpoint] null
/// means nothing is paused anywhere right now.
class ResumeLessonOutcome extends VoiceCommandOutcome {
  final LessonCheckpoint? checkpoint;
  final SyllabusTemplate? template;
  final Term? term;
  final SchemeOfWorkEntry? entry;
  const ResumeLessonOutcome({required super.parsed, this.checkpoint, this.template, this.term, this.entry});
}

/// [VoiceCommandAction.openMarking] — purely a launcher: the marking
/// assistant (`MarkingQueueScreen`) takes no subject/grade parameters to
/// pre-scope to (it's a shared queue across every subject), so there's
/// nothing to resolve beyond confirming the command was understood —
/// [ParsedVoiceCommand.subjectName]/[gradeName] are shown back to the
/// teacher as a reminder of which marking key to pick once inside, not
/// used to filter anything.
class MarkingOutcome extends VoiceCommandOutcome {
  const MarkingOutcome({required super.parsed});
}

/// Turns a [ParsedVoiceCommand] (the Cloud Function's free-text
/// understanding of what was said) into a real [VoiceCommandOutcome] by
/// matching against this app's own bundled/on-device data. Never guesses a
/// subject/grade/class that wasn't named: an unmatched one is a real
/// [VoiceCommandResolutionError], not a silent default to "whatever's
/// first" — except where an action's own real semantics make that
/// unambiguous (e.g. only one class exists, or only one grade is bundled
/// for a matched subject).
class VoiceCommandResolver {
  VoiceCommandResolver({
    TemplateRepository? repository,
    TopicSearchService? topicSearchService,
    ReportClassRepository? classRepository,
    CdcResourcesService? cdcService,
    LessonCheckpointRepository? checkpointRepository,
  })  : _repository = repository ?? TemplateRepository(),
        _topicSearchService = topicSearchService ?? TopicSearchService(),
        _classRepository = classRepository ?? ReportClassRepository(),
        _cdcService = cdcService ?? CdcResourcesService(),
        _checkpointRepository = checkpointRepository ?? LessonCheckpointRepository();

  final TemplateRepository _repository;
  final TopicSearchService _topicSearchService;
  final ReportClassRepository _classRepository;
  final CdcResourcesService _cdcService;
  final LessonCheckpointRepository _checkpointRepository;

  Future<VoiceCommandOutcome> resolve(ParsedVoiceCommand parsed) async {
    switch (parsed.action) {
      case VoiceCommandAction.resumeLesson:
        return _resolveResumeLesson(parsed);
      case VoiceCommandAction.openClassRoster:
        return _resolveClassRoster(parsed);
      case VoiceCommandAction.checkCdcMaterials:
        return _resolveCdcCheck(parsed);
      case VoiceCommandAction.openMarking:
        return MarkingOutcome(parsed: parsed);
      case VoiceCommandAction.generateLessonPlan:
      case VoiceCommandAction.generateSchemeOfWork:
      case VoiceCommandAction.generateRecordOfWork:
      case VoiceCommandAction.generateTeachingNotes:
      case VoiceCommandAction.findTopic:
        return _resolveTopic(parsed);
      case VoiceCommandAction.unrecognized:
        throw VoiceCommandResolutionError(parsed.summary);
    }
  }

  Future<TopicOutcome> _resolveTopic(ParsedVoiceCommand parsed) async {
    final subjectName = parsed.subjectName?.trim();
    if (subjectName == null || subjectName.isEmpty) {
      throw const VoiceCommandResolutionError(
        "I didn't catch which subject that was for — please try again and name the subject.",
      );
    }

    await _repository.ensureAllSeeded();
    final manifest = await _repository.loadManifest();
    final readiness = await Future.wait(manifest.map((e) => _repository.hasRealSource(e.file)));
    final readyEntries = [
      for (var i = 0; i < manifest.length; i++)
        if (readiness[i]) manifest[i],
    ];

    final matchesBySubject = _matchSubject(readyEntries, subjectName);
    if (matchesBySubject.isEmpty) {
      throw VoiceCommandResolutionError('No bundled subject matches "$subjectName".');
    }

    final gradeName = parsed.gradeName?.trim();
    final entry = _matchGrade(matchesBySubject, gradeName) ??
        // Only one grade bundled for this subject — safe to use it even
        // if the spoken grade didn't parse cleanly (or wasn't said at all
        // and there's genuinely nothing to disambiguate between).
        (matchesBySubject.length == 1 ? matchesBySubject.first : null);
    if (entry == null) {
      final gradeList = matchesBySubject.map((e) => e.gradeName).join(', ');
      throw VoiceCommandResolutionError(
        gradeName == null || gradeName.isEmpty
            ? 'Which grade/form? "$subjectName" has: $gradeList.'
            : 'No bundled "$gradeName" for "$subjectName" — available: $gradeList.',
      );
    }

    final template = await _repository.loadSyllabus(
      curriculumCode: entry.curriculumCode,
      subjectCode: entry.subjectCode,
      gradeLevel: entry.gradeLevel,
    );
    if (template == null) {
      throw VoiceCommandResolutionError('Could not load "${entry.subjectName} — ${entry.gradeName}".');
    }

    // A content phrase (2026-09-08) takes priority over a bare topic
    // number when both are somehow present — the teacher described WHAT
    // they want, which is more specific than an ordinal position.
    final keyword = parsed.topicKeyword?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      final search = _topicSearchService.searchWithinTemplate(template, keyword);
      if (search.results.isEmpty) {
        throw VoiceCommandResolutionError(
          'Nothing in "${template.subject.name} — ${template.grade.name}" mentions "$keyword" — try '
          'different wording, or browse Topics in the Scheme instead.',
        );
      }
      if (search.precise) {
        final best = search.results.first;
        return TopicOutcome(parsed: parsed, template: template, term: best.term, entry: best.entry);
      }
      return TopicOutcome(parsed: parsed, template: template, candidates: search.results);
    }

    final placement = _resolveEntry(template, weekNumber: parsed.weekNumber, topicNumber: parsed.topicNumber);
    return TopicOutcome(parsed: parsed, template: template, term: placement?.term, entry: placement?.entry);
  }

  Future<ClassRosterOutcome> _resolveClassRoster(ParsedVoiceCommand parsed) async {
    final classes = await _classRepository.listClasses();
    final spoken = parsed.className?.trim();
    if (spoken == null || spoken.isEmpty) {
      // No class named — only safe to proceed alone if there's exactly
      // one real class to go to; otherwise the caller shows the full list
      // to pick from rather than guessing which one was meant.
      return ClassRosterOutcome(
        parsed: parsed,
        matchedClass: classes.length == 1 ? classes.first : null,
        allClasses: classes,
      );
    }

    final normalizedSpoken = _normalizeClassName(spoken);
    ReportClass? exact;
    ReportClass? partial;
    for (final c in classes) {
      final normalizedGrade = _normalizeClassName(c.classGrade);
      if (normalizedGrade == normalizedSpoken) {
        exact = c;
        break;
      }
      if (partial == null &&
          (normalizedGrade.contains(normalizedSpoken) || normalizedSpoken.contains(normalizedGrade))) {
        partial = c;
      }
    }
    return ClassRosterOutcome(parsed: parsed, matchedClass: exact ?? partial, allClasses: classes);
  }

  String _normalizeClassName(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  Future<CdcCheckOutcome> _resolveCdcCheck(ParsedVoiceCommand parsed) async {
    // Opportunistic — same throttled refresh every other CDC-catalog entry
    // point already does; never blocks the voice command on it failing
    // (offline is a completely normal state to check materials from a
    // stale-but-still-useful local cache in).
    try {
      await _cdcService.refreshIfDue();
    } catch (_) {
      // Cached catalog still answers the question below.
    }
    final count = await _cdcService.unseenCount(subjectName: parsed.subjectName?.trim());
    return CdcCheckOutcome(parsed: parsed, unseenCount: count);
  }

  Future<ResumeLessonOutcome> _resolveResumeLesson(ParsedVoiceCommand parsed) async {
    final checkpoint = await _checkpointRepository.findMostRecentOverall();
    if (checkpoint == null) {
      return ResumeLessonOutcome(parsed: parsed, checkpoint: null);
    }
    final template = await _repository.loadSyllabus(
      curriculumCode: checkpoint.curriculumCode,
      subjectCode: checkpoint.subjectCode,
      gradeLevel: checkpoint.gradeLevel,
    );
    if (template == null) {
      return ResumeLessonOutcome(parsed: parsed, checkpoint: checkpoint);
    }
    final placement = _entryForCheckpoint(template, checkpoint);
    return ResumeLessonOutcome(
      parsed: parsed,
      checkpoint: checkpoint,
      template: template,
      term: placement?.term,
      entry: placement?.entry,
    );
  }

  /// Rebuilds a [SchemeOfWorkEntry] (and its owning [Term]) for whichever
  /// topic/sub-topic a saved checkpoint points at, by id-matching against
  /// the current template — mirrors generate_lesson_plan_flow.dart's own
  /// private `_entryForCheckpoint`, duplicated here (not shared) since
  /// that one intentionally stays private to its own file and this is a
  /// small, stable piece of logic unlikely to drift.
  ({Term term, SchemeOfWorkEntry entry})? _entryForCheckpoint(SyllabusTemplate template, LessonCheckpoint checkpoint) {
    for (final term in template.terms) {
      for (final topic in term.topics) {
        if (topic.id != checkpoint.topicId) continue;
        if (checkpoint.subTopicId == null) {
          return (
            term: term,
            entry: SchemeOfWorkEntry(
              weekNumber: 1,
              topic: topic,
              objectives: topic.objectives,
              competencies: topic.competencies,
            ),
          );
        }
        for (final subTopic in topic.subTopics) {
          if (subTopic.id == checkpoint.subTopicId) {
            return (
              term: term,
              entry: SchemeOfWorkEntry(
                weekNumber: 1,
                topic: topic,
                subTopic: subTopic,
                objectives: subTopic.objectives,
                competencies: subTopic.competencies,
              ),
            );
          }
        }
      }
    }
    return null;
  }

  List<TemplateManifestEntry> _matchSubject(List<TemplateManifestEntry> entries, String spoken) {
    final normalizedSpoken = spoken.toLowerCase().trim();
    final exact = entries.where((e) => e.subjectName.toLowerCase().trim() == normalizedSpoken).toList();
    if (exact.isNotEmpty) return exact;
    return entries
        .where((e) =>
            normalizedSpoken.contains(e.subjectName.toLowerCase().trim()) ||
            e.subjectName.toLowerCase().trim().contains(normalizedSpoken))
        .toList();
  }

  TemplateManifestEntry? _matchGrade(List<TemplateManifestEntry> entries, String? spoken) {
    if (spoken == null || spoken.isEmpty) return null;
    final normalizedSpoken = spoken.toLowerCase().trim();
    for (final e in entries) {
      if (e.gradeName.toLowerCase().trim() == normalizedSpoken) return e;
    }
    // Fall back to whatever number was spoken (e.g. "grade 10" / "form 2"
    // both reduce to comparing against gradeLevel) — still a real match,
    // just tolerant of "10" alone or an ASR mishearing "Form" as "form".
    final spokenNumber = RegExp(r'\d+').firstMatch(normalizedSpoken)?.group(0);
    if (spokenNumber != null) {
      for (final e in entries) {
        if (e.gradeLevel == int.parse(spokenNumber)) return e;
      }
    }
    return null;
  }

  /// Best-effort: finds the specific topic/sub-topic a spoken week+topic
  /// number points at, using the exact same fresh-class week placement
  /// [TermTopicPickerScreen] already shows a teacher browsing manually —
  /// so a voice command's result always matches what tapping through the
  /// same term/week would have found. [topicNumber] is that week's own
  /// ordinal position (1st/2nd/3rd topic taught that week) when more than
  /// one topic shares a week; with no [weekNumber] at all, [topicNumber]
  /// instead indexes the WHOLE subject's own topic/sub-topic order.
  ({Term term, SchemeOfWorkEntry entry})? _resolveEntry(
    SyllabusTemplate template, {
    required int? weekNumber,
    required int? topicNumber,
  }) {
    if (weekNumber == null) {
      if (topicNumber == null) return null;
      final all = allSchemeOfWorkEntries(template);
      if (topicNumber < 1 || topicNumber > all.length) return null;
      final entry = all[topicNumber - 1];
      for (final term in template.terms) {
        if (term.topics.any((t) => t.id == entry.topic.id)) return (term: term, entry: entry);
      }
      return null;
    }

    for (final term in template.terms) {
      final windowEntries = entriesForOwnTerm(template, term);
      if (windowEntries.isEmpty) continue;
      final paced = applyCalendarPacing(windowEntries);
      final byWeek = groupEntriesByEffectiveWeek(paced);
      final weekEntries = byWeek[weekNumber];
      if (weekEntries == null || weekEntries.isEmpty) continue;
      final index = (topicNumber == null || topicNumber < 1 || topicNumber > weekEntries.length) ? 0 : topicNumber - 1;
      return (term: term, entry: weekEntries[index]);
    }
    return null;
  }
}
