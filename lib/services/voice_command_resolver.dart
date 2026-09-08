import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'scheme_of_work_calendar_pacing.dart';
import 'template_repository.dart';
import 'voice_command_service.dart';

/// What a voice command resolved to against this app's REAL bundled data —
/// see [VoiceCommandResolver.resolve]'s own doc comment for exactly how.
/// [entry]/[term] are best-effort: a command that named a subject/grade
/// but no topic/week still resolves [template] alone, letting the caller
/// fall back to its own normal topic picker for the one thing voice
/// didn't specify, rather than failing the whole command.
class ResolvedVoiceCommand {
  final ParsedVoiceCommand parsed;
  final SyllabusTemplate template;
  final Term? term;
  final SchemeOfWorkEntry? entry;

  const ResolvedVoiceCommand({required this.parsed, required this.template, this.term, this.entry});
}

/// Why a command couldn't be resolved at all — shown back to the teacher
/// so a mic misfire is diagnosable rather than a silent no-op.
class VoiceCommandResolutionError implements Exception {
  final String message;
  const VoiceCommandResolutionError(this.message);
  @override
  String toString() => message;
}

/// Turns a [ParsedVoiceCommand] (the Cloud Function's free-text
/// understanding of what was said) into a real, loaded [SyllabusTemplate]
/// — and, best-effort, a specific [Term]/[SchemeOfWorkEntry] — by matching
/// against this app's own bundled manifest. Never guesses a subject/grade
/// that wasn't named: an unmatched subject is a real
/// [VoiceCommandResolutionError], not a silent default to "whatever's
/// first."
class VoiceCommandResolver {
  VoiceCommandResolver({TemplateRepository? repository}) : _repository = repository ?? TemplateRepository();

  final TemplateRepository _repository;

  Future<ResolvedVoiceCommand> resolve(ParsedVoiceCommand parsed) async {
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

    final placement = _resolveEntry(template, weekNumber: parsed.weekNumber, topicNumber: parsed.topicNumber);
    return ResolvedVoiceCommand(parsed: parsed, template: template, term: placement?.term, entry: placement?.entry);
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
