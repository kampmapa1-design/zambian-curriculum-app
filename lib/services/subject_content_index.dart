import 'dart:io';

import '../models/embedded_lesson_plan.dart';
import '../models/marking_scheme.dart';
import '../models/subject_content_item.dart';
import 'embedded_lesson_plan_repository.dart';
import 'related_marking_key_finder.dart';
import 'subject_content_repository.dart';

/// Everything this app already knows on-device about one topic/sub-topic,
/// resolved in a single call — see [SubjectContentIndex.resolve].
class SubjectContentResolution {
  const SubjectContentResolution({
    this.embeddedLessonPlans = const [],
    this.relatedMaterials = const [],
    this.contentExcerpt,
    this.relatedMarkingKeys = const [],
  });

  /// Real, sanitized lesson plans matching this exact topic/sub-topic —
  /// see [EmbeddedLessonPlanRepository].
  final List<EmbeddedLessonPlan> embeddedLessonPlans;

  /// Every Subject Content Database item saved under this subject —
  /// offered as reference material to open/share.
  final List<SubjectContentItem> relatedMaterials;

  /// The best-matching real-content excerpt for this topic/sub-topic, drawn
  /// from [relatedMaterials]'s extracted text — see
  /// [SubjectContentRepository.findRelevantExcerpt]. Null when nothing
  /// stored mentions the topic.
  final String? contentExcerpt;

  /// Marking keys uploaded through AI-Assisted Marking for this subject —
  /// see [RelatedMarkingKeyFinder].
  final List<MarkingScheme> relatedMarkingKeys;
}

/// The single canonical entry point for "what does this app already have
/// on-device about subject X" — unifies three previously separate,
/// independently-instantiated lookups (`EmbeddedLessonPlanRepository`,
/// `SubjectContentRepository`, `RelatedMarkingKeyFinder`) behind one call.
///
/// Before this existed, `LessonPlanScreen` alone ran all three (plus its own
/// custom-template load) as five separate uncoordinated `initState` futures;
/// `SchemeOfWorkDocumentScreen` separately instantiated its own
/// `RelatedMarkingKeyFinder` for the same lookup. This gives every caller —
/// including generators added later — one coordinated, reusable path instead
/// of each re-wiring the same three repositories itself.
///
/// Entirely on-device/offline — no network, no AI call here. AI-based text
/// extraction into the Subject Content Database happens earlier, when a
/// document is first saved (see `SubjectContentExtractionService` and
/// `OnDevicePdfTextExtractionService`); this facade only reads what's
/// already been extracted and cached, so it's safe to call on every screen
/// open regardless of connectivity.
class SubjectContentIndex {
  SubjectContentIndex({
    EmbeddedLessonPlanRepository? embeddedLessonPlanRepository,
    SubjectContentRepository? subjectContentRepository,
    RelatedMarkingKeyFinder? markingKeyFinder,
  })  : _embedded = embeddedLessonPlanRepository ?? EmbeddedLessonPlanRepository(),
        _subjectContent = subjectContentRepository ?? SubjectContentRepository(),
        _markingKeys = markingKeyFinder ?? RelatedMarkingKeyFinder();

  final EmbeddedLessonPlanRepository _embedded;
  final SubjectContentRepository _subjectContent;
  final RelatedMarkingKeyFinder _markingKeys;

  /// Full topic-scoped resolution — everything a lesson/notes generator for
  /// one specific topic/sub-topic can draw on. Runs all four underlying
  /// lookups concurrently.
  Future<SubjectContentResolution> resolve({
    required String subjectName,
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
    required String topicName,
    String? subTopicName,
  }) async {
    final embeddedFuture = _embedded.find(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
      topicName: topicName,
      subtopicName: subTopicName,
    );
    final catalogFuture = _subjectContent.loadCatalog();
    final excerptFuture = _subjectContent.findRelevantExcerpt(
      subjectName: subjectName,
      topicName: topicName,
      subTopicName: subTopicName,
    );
    final markingKeyFuture = _markingKeys.find(subjectName);

    final embeddedMatches = await embeddedFuture;
    final catalog = await catalogFuture;
    final excerpt = await excerptFuture;
    final markingKeys = await markingKeyFuture;

    final relatedMaterials =
        catalog.items.where((i) => i.subjectName.toLowerCase() == subjectName.toLowerCase()).toList();

    return SubjectContentResolution(
      embeddedLessonPlans: embeddedMatches,
      relatedMaterials: relatedMaterials,
      contentExcerpt: excerpt,
      relatedMarkingKeys: markingKeys,
    );
  }

  /// Subject-only lookup, for callers with no single topic to scope to
  /// (e.g. a whole Scheme of Work spanning a term) — just the marking-key
  /// enrichment, without the topic-specific pieces of [resolve].
  Future<List<MarkingScheme>> relatedMarkingKeys(String subjectName) => _markingKeys.find(subjectName);

  /// The full local path to a stored Subject Content item's file — for
  /// opening/sharing it. Delegates to [SubjectContentRepository.fileFor] so
  /// callers only need to hold this one facade.
  Future<File> fileFor(SubjectContentItem item) => _subjectContent.fileFor(item);
}
