# Zambian Curriculum Companion (Flutter)

An offline mobile app for teachers: pick a **Subject** and **Grade**, and the
matching syllabus template (terms → topics → sub-topics → learning objectives
→ competencies) loads instantly from local storage. No network required.

This was written before Flutter was installed on this machine, so only the
Dart application code exists yet (`lib/`, `assets/`, `pubspec.yaml`) — the
`android/`, `ios/`, etc. platform folders that `flutter create` normally
generates are missing. See **Setup** below to add them.

## How it works

- **Bundled templates** — `assets/syllabi/*.json`, one file per subject+grade,
  listed in `assets/syllabi/manifest.json`. Shipped inside the app, so they're
  available with zero network access.
- **Local storage** — on launch, every bundled template is imported into an
  on-device SQLite database (`sqflite`) with the same schema as the
  [`zambian-curriculum-db`](../zambian-curriculum-db) desktop project:
  subjects → grades → terms → topics → sub_topics → learning_objectives /
  competencies. Import is idempotent, so re-running it on every launch never
  duplicates rows.
- **Subject Selector screen** (`lib/screens/subject_selector_screen.dart`) —
  two dropdowns (Subject, Grade), populated from the manifest. Once both are
  picked, the matching syllabus is fetched from the local database (one
  indexed query) and cached in memory, so switching between already-viewed
  templates is instant.
- **Scheme of work screen** (`lib/screens/scheme_of_work_screen.dart`),
  reachable via "Plan next term" once a syllabus is loaded — the teacher taps
  the topic they concluded last term from the same topic list, and the app
  generates a week-by-week scheme starting at the *next* topic in sequence
  (crossing into the next term automatically once the current term's topics
  run out), pulling each entry's objectives and competencies straight from
  local storage. The mark is saved on-device (`topic_progress` table) and the
  scheme regenerates instantly whenever it changes — see
  `lib/models/scheme_of_work.dart` for the generation logic.
- **Entitlement gate** (`lib/services/entitlement_service.dart`) — generating
  the scheme of work requires a subscription still within its grace period,
  or an ad-unlock already granted this session. Marking progress stays free;
  only the generated output is gated. Offline, a still-valid grace period or
  session unlock lets generation proceed with no connection at all; if
  neither applies, the screen shows why and offers "Subscribe" / "Watch ad to
  unlock" buttons that are disabled while offline (both need a connection),
  with a message explaining that. The actual subscription verification and
  ad-watching calls are stubs — wire a real store/ad SDK
  (`in_app_purchase`, `google_mobile_ads`) in behind `verifySubscription()`
  and `watchRewardedAd()` when ready; the grace-period and offline-gating
  logic around them is real and doesn't need to change.
- **Teaching notes generation (online-only)** — a "Teaching notes" button on
  each scheme-of-work entry opens a sheet (`lib/screens/teaching_notes_sheet.dart`)
  that calls a Firebase Cloud Function (`generateTeachingNotes`, in
  [`firebase/functions`](firebase/functions)), which calls the Anthropic API
  server-side — the API key never reaches the app. `TeachingNotesService`
  checks connectivity before calling and fails fast with a clear message if
  offline, rather than hanging; a loading spinner covers the wait otherwise.
  The app signs in anonymously via Firebase Auth
  (`lib/services/auth_service.dart`) so the callable function can verify
  requests actually come from this app before spending API budget on them —
  see [`firebase/README.md`](firebase/README.md) for the full setup
  (project creation, Blaze billing, the API key secret) and what anonymous
  auth does and doesn't protect against.

- **CI build** (`codemagic.yaml`) — builds an unsigned debug and release APK
  on [Codemagic](https://codemagic.io) for sideloading onto a test device,
  no Play Store signing setup required. Sign up, connect this GitHub repo,
  and Codemagic picks up `codemagic.yaml` automatically; each build's
  results page gives a direct APK download link.

Adding a new bundled template later means: drop a new `assets/syllabi/*.json`
file (same shape as the existing ones), add an entry to `manifest.json`, and
list the file under `flutter.assets` in `pubspec.yaml`.

## Setup

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install) and
   an Android toolchain (Android Studio, or just the command-line SDK + an
   emulator/device).
2. From this folder, generate the missing platform scaffolding without
   touching the existing `lib/`/`pubspec.yaml`:
   ```bash
   flutter create --project-name zambian_curriculum_app .
   ```
3. Fetch dependencies:
   ```bash
   flutter pub get
   ```
4. **Only needed for the "Teaching notes" feature** — everything else works
   without this step. Set up the Firebase backend per
   [`firebase/README.md`](firebase/README.md), then connect this app to it:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```
   This generates `lib/firebase_options.dart` and the platform config files
   (`google-services.json` / `GoogleService-Info.plist`) — none of which
   exist yet in this checkout. `main.dart` calls `Firebase.initializeApp()`
   and catches failures, so the app still runs fully offline without this
   step; only teaching-notes generation needs it.
5. Run on a connected device or emulator:
   ```bash
   flutter run
   ```

## Project layout

```
lib/
  main.dart                       # app entry point
  models/syllabus_models.dart     # Subject, Grade, Term, Topic, SubTopic, ...
  models/scheme_of_work.dart      # SchemeOfWorkEntry + generateSchemeOfWork()
  services/database_helper.dart   # sqflite schema + import + queries + progress
  services/template_repository.dart  # asset loading + seeding + in-memory cache
  services/progress_repository.dart  # persists the last-concluded-topic mark
  services/entitlement_service.dart  # subscription grace period + ad-unlock + offline gating
  services/auth_service.dart      # anonymous Firebase Auth sign-in
  services/teaching_notes_service.dart  # calls the generateTeachingNotes Cloud Function
  screens/subject_selector_screen.dart  # the Subject Selector UI
  screens/scheme_of_work_screen.dart    # mark progress + generated scheme UI
  screens/teaching_notes_sheet.dart     # the "Teaching notes" generation UI
assets/syllabi/
  manifest.json                   # list of bundled subject/grade templates
  math_grade8.json                # sample template (Term 1 + Term 2)
  english_grade8.json             # sample template (Term 1)
firebase/
  functions/src/index.ts          # generateTeachingNotes Cloud Function
  README.md                       # Firebase project setup, secrets, deploy
```
