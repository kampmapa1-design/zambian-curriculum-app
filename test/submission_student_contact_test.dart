import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/assignment_submission.dart';
import 'package:zambian_curriculum_app/models/test_submission.dart';

/// Feedback return-path (owner request, 2026-09-28): the student's own
/// contact details are only useful if they actually survive a save/reload
/// round trip and a copyWith update — a silent JSON-serialization gap here
/// would mean feedback quietly has nowhere to go, discovered only much
/// later when a teacher tries to send it.
void main() {
  group('AssignmentSubmission.studentEmail/studentWhatsApp', () {
    test('round-trips through toJson/fromJson', () {
      final submission = AssignmentSubmission(
        id: 's1',
        createdAt: DateTime(2026, 9, 28),
        studentEmail: 'chanda@example.com',
        studentWhatsApp: '+260977000000',
      );
      final restored = AssignmentSubmission.fromJson(submission.toJson());
      expect(restored.studentEmail, 'chanda@example.com');
      expect(restored.studentWhatsApp, '+260977000000');
    });

    test('null by default, and null survives the round trip (neither ever provided)', () {
      final submission = AssignmentSubmission(id: 's1', createdAt: DateTime(2026, 9, 28));
      expect(submission.studentEmail, isNull);
      expect(submission.studentWhatsApp, isNull);
      final restored = AssignmentSubmission.fromJson(submission.toJson());
      expect(restored.studentEmail, isNull);
      expect(restored.studentWhatsApp, isNull);
    });

    test('copyWith updates one field without disturbing the other', () {
      final submission = AssignmentSubmission(id: 's1', createdAt: DateTime(2026, 9, 28), studentEmail: 'a@b.com');
      final updated = submission.copyWith(studentWhatsApp: '+260977000000');
      expect(updated.studentEmail, 'a@b.com');
      expect(updated.studentWhatsApp, '+260977000000');
    });
  });

  group('TestSubmission.studentEmail/studentWhatsApp', () {
    test('round-trips through toJson/fromJson, alongside the pre-existing markingScriptId', () {
      final submission = TestSubmission(
        id: 't1',
        createdAt: DateTime(2026, 9, 28),
        markingScriptId: 'script-123',
        studentEmail: 'chanda@example.com',
        studentWhatsApp: '+260977000000',
      );
      final restored = TestSubmission.fromJson(submission.toJson());
      expect(restored.studentEmail, 'chanda@example.com');
      expect(restored.studentWhatsApp, '+260977000000');
      expect(restored.markingScriptId, 'script-123');
    });

    test('null by default, and null survives the round trip', () {
      final submission = TestSubmission(id: 't1', createdAt: DateTime(2026, 9, 28));
      final restored = TestSubmission.fromJson(submission.toJson());
      expect(restored.studentEmail, isNull);
      expect(restored.studentWhatsApp, isNull);
    });
  });
}
