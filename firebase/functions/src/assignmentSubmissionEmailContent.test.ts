// Feedback return-path (owner request, 2026-09-28): "feedback" is a THIRD
// submissionKind, alongside the existing "assignment"/"test" — the only one
// where the email's own recipient is the STUDENT, not the teacher. Real bug
// this guards against: reusing the teacher-facing "X has submitted a
// test..." copy for an email that's actually telling the student their
// marked work is ready would be confusing/wrong for the recipient.
import { buildAssignmentSubmissionEmailContent } from "./index";

describe("buildAssignmentSubmissionEmailContent", () => {
  it('"feedback" kind tells the STUDENT their work is marked, never the teacher-facing framing', () => {
    const { subject, html } = buildAssignmentSubmissionEmailContent({
      kind: "feedback",
      studentName: "Chanda Mwape",
      title: "Mid-Term Test",
      hash: "abc123",
      submittedAt: "2026-09-28T10:00:00.000Z",
      attachmentCount: 2,
    });
    expect(subject).toBe("Your feedback is ready: Mid-Term Test");
    expect(html).toContain("Your marked work is ready");
    expect(html).not.toContain("has submitted");
  });

  it('"assignment" and "test" kinds keep the original teacher-facing submission-notification framing, unchanged', () => {
    const assignment = buildAssignmentSubmissionEmailContent({
      kind: "assignment",
      studentName: "Chanda Mwape",
      title: "Essay One",
      attachmentCount: 2,
    });
    expect(assignment.subject).toBe("Assignment submission: Essay One - Chanda Mwape");
    expect(assignment.html).toContain("Chanda Mwape has submitted an assignment via Smart Teacher.");

    const test = buildAssignmentSubmissionEmailContent({
      kind: "test",
      studentName: "Chanda Mwape",
      title: "Mid-Term Test",
      attachmentCount: 1,
    });
    expect(test.subject).toBe("Test submission: Mid-Term Test - Chanda Mwape");
    expect(test.html).toContain("Chanda Mwape has submitted a test via Smart Teacher.");
  });

  it("missing optional fields fall back to safe defaults, never throwing, for any kind", () => {
    for (const kind of ["assignment", "test", "feedback"]) {
      const { subject, html } = buildAssignmentSubmissionEmailContent({ kind, attachmentCount: 1 });
      expect(subject.length).toBeGreaterThan(0);
      expect(html.length).toBeGreaterThan(0);
    }
  });

  it("the submission hash is only shown when one is actually given", () => {
    const withHash = buildAssignmentSubmissionEmailContent({ kind: "feedback", hash: "deadbeef", attachmentCount: 1 });
    expect(withHash.html).toContain("deadbeef");
    const withoutHash = buildAssignmentSubmissionEmailContent({ kind: "feedback", attachmentCount: 1 });
    expect(withoutHash.html).not.toContain("SHA-256");
  });
});
