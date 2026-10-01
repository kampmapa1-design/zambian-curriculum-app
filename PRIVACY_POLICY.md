# Privacy Policy — Smart Teacher

**Effective date:** September 17, 2026

Smart Teacher ("the app") is developed by Kampamba Mashabe ("we", "us"). This policy explains what data the app collects, why, and how it is handled. It applies to the Android app distributed under the package name `com.kampmapa1design.smartteacher`, used by two kinds of accounts: **teachers/school staff** and **pupils/learners** (secondary-school students).

## Summary

Smart Teacher is used by teachers to plan lessons, mark work, and run their school's timetable and communication, and by pupils to submit work and download study material. Some data — lesson plans, schemes of work, and locally-generated reports — stays on your device only. Other data — accounts, school/class rosters, marking records, and messages sent to guardians — is stored in our cloud database (Google Firebase) so it can sync across a school's devices and reach the right people. This policy describes both.

## Who uses this app, and what we collect from each

### Teachers and school staff

- **Sign-in**: every install starts with an anonymous session. A teacher may later sign in with a **phone number** (verified by SMS code) or an **email address and password**. Whichever you choose becomes part of your account; we don't collect both.
- **Profile**: your name, chosen sign-in method, and (if applicable) phone number or email are stored in our database against your account.
- **School and class setup**: if you register or join a school, we store the school's name, province/district, your role, and — if you set up a class — the class's grade/term, subject list, and a plaintext roster of **your pupils' full names** that you type in yourself.
- **Guardian/parent contact details**: if you choose to enter them, we store each pupil's guardian's **phone number and/or email address**, used only to send that guardian messages you send through the app (see "Guardian communication" below).
- **Marking and scores**: photographs of scripts/tests you capture for AI-assisted marking are sent to Google's Gemini AI for one-time processing (see "AI processing" below) and the resulting scores/comments, tied to a pupil's name, are stored against that class.
- **Voice commands**: if you use tap-to-talk voice commands, your speech is transcribed to text on your device by Android's own speech recognizer — the audio itself is never recorded to a file or uploaded; only the resulting text is sent to Gemini to interpret the command.

### Pupils/learners

- **Sign-in**: pupils also use an anonymous Firebase account — no phone number or email is collected directly from a pupil to create their account.
- **Joining a class**: to link your account to your class, you tell the app which class and the name you go by; your teacher confirms the match against the roster they already entered.
- **Submitted work**: photographs of your assignment/test answers that you submit are sent to Google's Gemini AI for processing and, for Home Assignments specifically, the photographed pages are also kept in our cloud storage so your teacher can review them.
- **Your own feedback contact details**: when you submit an Assignment or a Test through the app, you're asked for your own email address and/or WhatsApp number — at least one is required — used only so your teacher can send your marked/graded feedback directly back to you once it's ready. Never used for any other purpose, and never shared beyond your own teacher.
- **A pupil may also have work submitted on their behalf** by a teacher (e.g. importing a paper or emailed submission) without ever having opened the app themselves — this is teacher-entered data about that pupil, not data the pupil provided.

### Content that stays on your device only

Lesson plans, schemes of work, record-of-work documents, locally captured report-card data, and generated analysis documents are stored in a local database on your device and are not part of our cloud database. Uninstalling the app deletes this local content.

## AI processing (Google Gemini)

Features such as AI-assisted marking, marking-key generation, handwritten-text transcription, lesson/assignment content generation, and reading a photographed paper timetable send the relevant photographed page(s) and/or text to our backend (Google Cloud Functions), which forwards them to **Google's Gemini AI** for one-time processing and returns the result. For most of these features, the image data is passed through for processing and is not separately retained by our backend afterward. Google's own handling of data sent to its AI services is governed by [Google's Privacy Policy](https://policies.google.com/privacy) and the Gemini API terms.

## Where photos and documents are actually kept

Most photographed content (marking scripts, tests, timetables, cover/reference pages) is sent for AI processing and not separately stored by us afterward. A smaller number of specific features do keep uploaded files in our cloud storage, only for the purpose named:

- Files you explicitly file to your own **Teacher Submissions Dashboard**, for your later access only.
- **Scan Marker** batch PDFs of captured script pages, kept so you can revisit a marking batch.
- **Pupils' Home Assignment answer photos**, kept so the assigning teacher can review and mark them.
- Your **school's logo**, if you upload one for branding.

## Guardian communication

If a teacher enters a guardian's phone/email against a pupil, that contact information is used only to:

- send that guardian an email (via our email provider, Brevo) — for example, a broadcast message, a Home Assignment being issued, results, or a reminder to submit; and
- let the teacher open a pre-filled WhatsApp chat to that number — **the app never sends anything to WhatsApp itself**; it only builds a link that opens WhatsApp on the teacher's own phone, for the teacher to review and send manually.

If a guardian replies by email to a Home Assignment notice, our backend reads that reply (from a dedicated inbox set up for this purpose) to route the attached photos to the right pupil's submission. If the reply can't be matched to a real pupil/class, the sender's email address and message details are kept temporarily so school staff can resolve it by hand.

## Third parties we share data with

- **Google Gemini AI** — processes photographed documents and text as described above.
- **Brevo** — a third-party email service we use to send the guardian/staff emails described above.
- **Google/Firebase** — our entire backend (accounts, database, file storage, and processing functions) runs on Google Cloud/Firebase infrastructure.

We do not sell your data, and we do not share it with anyone for their own advertising or marketing purposes.

## Advertising, analytics, and tracking

As of this policy's effective date, **the app does not run any advertising SDK, and does not use any analytics or crash-reporting SDK.** Some features are designed to eventually require watching a short video ad to unlock (in place of a paid subscription); until a real ad SDK is integrated and enabled, these unlock immediately with no ad shown and no ad-related data collected. If and when real advertising goes live, we will update this policy first, and the update will be reflected in the app's Play Store listing before that version is released.

## Device permissions

- **Camera** — to photograph scripts, tests, assignments, and paper timetables for the features described above.
- **Microphone** — only for tap-to-talk voice commands; audio is transcribed on-device and never recorded to a file or uploaded.
- **Internet** — required for any feature described above; the app otherwise works fully offline.

We do not request location, contacts, or storage-wide permissions.

## Pupils, schools, and guardians

This app is used in a school setting and is designed to be set up and administered by teachers and school staff, with pupils using it under their school's guidance. Some pupils using the app will be minors. We rely on the school/teacher to obtain any parental/guardian consent their own policies require before entering a pupil's name or a guardian's contact details into the app. Beyond the class-joining name, the only personal information collected directly from a pupil is the feedback contact detail(s) (email and/or WhatsApp number) described above, entered only when submitting an Assignment or Test and used only to deliver that submission's own feedback. If you are a parent or guardian and have questions about your child's data, contact us using the details below.

## Data retention and deletion

Cloud-stored data (accounts, school/class rosters, scores, submissions, messages) is retained until deleted by the account holder, the school, or on request to us. On-device content is deleted when the app is uninstalled. To request deletion of your account or a specific record, contact us using the details below.

## Changes to this policy

We may update this policy as the app's features change. The effective date above reflects the most recent update.

## Contact

Questions about this policy or your data can be sent to: **kampmapa1@gmail.com**
