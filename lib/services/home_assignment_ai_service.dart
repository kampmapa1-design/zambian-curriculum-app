import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/home_assignment.dart';
import 'auth_service.dart';
import 'metered_call.dart';

class HomeAssignmentAiUnavailable implements Exception {
  final String message;
  const HomeAssignmentAiUnavailable(this.message);
  @override
  String toString() => message;
}

/// Home Assignment epic, Stage 5 — calls `generateHomeAssignment`. Same
/// online-required/sign-in pattern as [LessonPlanAiService], same
/// required-subject discipline (a generic topic name alone isn't enough
/// to disambiguate against the model's own general knowledge).
class HomeAssignmentAiService {
  HomeAssignmentAiService({FirebaseFunctions? functions}) : _providedFunctions = functions;

  // Lazy: resolving FirebaseFunctions.instance needs Firebase.initializeApp() to have
  // succeeded; constructing this service must never throw just because it hasn't.
  final FirebaseFunctions? _providedFunctions;
  FirebaseFunctions get _functions => _providedFunctions ?? FirebaseFunctions.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<HomeAssignmentResult> generate({
    required String topic,
    String? subtopic,
    required String subject,
    String? grade,
    required List<String> competencies,
    required List<String> objectives,
    String? references,
    String? subjectContentExcerpt,
    required HomeAssignmentPageLength pageLength,
    required HomeAssignmentQuestionType questionType,
  }) async {
    if (!await isOnline) {
      throw const HomeAssignmentAiUnavailable("You're offline. Connect to the internet to generate a home assignment.");
    }
    await AuthService.instance.ensureSignedIn();

    final callable = meteredCallable(_functions, 'generateHomeAssignment');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'topic': topic,
        if (subtopic != null) 'subtopic': subtopic,
        'subject': subject,
        if (grade != null) 'grade': grade,
        'competencies': competencies,
        'objectives': objectives,
        if (references != null) 'references': references,
        if (subjectContentExcerpt != null && subjectContentExcerpt.trim().isNotEmpty) 'subjectContentExcerpt': subjectContentExcerpt,
        'pageLength': pageLength.wireValue,
        'questionType': questionType.wireValue,
      });
      return HomeAssignmentResult.fromMap(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw HomeAssignmentAiUnavailable(e.message ?? 'Failed to generate this home assignment.');
    }
  }
}
