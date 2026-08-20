# Zambian Curriculum Companion (Flutter)

An offline mobile app for teachers: pick a **Subject** and **Grade**, and the
matching syllabus template (terms → topics → sub-topics → learning objectives
→ competencies) loads instantly from local storage. No network required.

This was written before Flutter was installed on this machine, so only the
Dart application code exists yet (`lib/`, `assets/`, `pubspec.yaml`) — the
`android/`, `ios/`, etc. platform folders that `flutter create` normally
generates are missing. See **Setup** below to add them.

## How it works

- **Two parallel curricula** — the local schema has a `curricula` table, and
  subjects/grades/terms are each scoped to one curriculum (see
  `lib/services/database_helper.dart`), so the 2023 Competency-Based
  Curriculum and the 2013 Outcome-Based Curriculum can coexist without
  collisions even when they reuse a subject code or grade/form number. The
  Subject Selector shows a toggle between whichever curricula are actually
  present in `manifest.json` — not a fixed two-way switch, so a third
  curriculum would show up automatically once its templates are bundled —
  and the Subject/Grade dropdowns below it re-populate from the selected
  curriculum only. Note: whether a level is labeled "Grade N" or "Form N" is
  a property of the source document, not the curriculum — the real 2024 CDC
  History syllabus uses "Form 1-4" for Ordinary Level Secondary under the
  2023 CBC itself, so don't assume "Form" implies the 2013 curriculum.
- **Bundled templates** — `assets/syllabi/*.json`, one file per
  curriculum+subject+grade, listed in `assets/syllabi/manifest.json`.
  Shipped inside the app, so they're available with zero network access.
  `assets/syllabi/obc2013_english_form3_placeholder.json` is a clearly
  labeled **placeholder** — not transcribed from a real 2013 syllabus — kept
  only to prove the two-curriculum schema actually works end to end.
  `assets/syllabi/history_form1.json` (CBC 2023, Form 1, Term 1) is real,
  sourced content — see its `_source` field and the citation below.
- **Data import** — `TemplateRepository.importUserSuppliedTemplate()` accepts
  the same JSON shape as the bundled files, for loading real subject data
  supplied later without a code change.
- **Local storage** — on launch, every bundled template is imported into an
  on-device SQLite database (`sqflite`). Import is idempotent, so re-running
  it on every launch never duplicates rows.
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

- **Lesson plans (offline)** — a "Lesson plan" button on each scheme-of-work
  entry opens `lib/screens/lesson_plan_screen.dart`, a form for the official
  CDC lesson plan template (`lib/models/lesson_plan.dart`) — field structure
  sourced from a real worked example, cited in `defaultCdcLessonPlanTemplate`
  and shown in the screen itself. Subject/Topic/Sub-topic/competencies are
  auto-filled from the syllabus; everything else the teacher fills in,
  including the fixed-order "Lesson Progression" table (Introduction →
  Lesson Development → Exercise → Homework → Conclusion). "Export PDF" /
  "Export Word" (`lib/services/lesson_plan_document_service.dart`) render the
  filled-in template entirely on-device — PDF via the `pdf` package, DOCX via
  a small hand-built OOXML writer (no template file, no extra package) — then
  hand the file to the OS share sheet (`share_plus`), which is what actually
  surfaces WhatsApp, email, Bluetooth, and every other installed share
  target; the app doesn't integrate each channel separately.
- **Guided planning (Stage 5, offline, rule-based)** — a "Guided planning"
  button on each scheme-of-work entry opens
  `lib/screens/guided_planning_screen.dart`: the teacher answers a few
  structured questions (class size, whether teaching aids are available,
  prior mastery, preferred activity style — no AI model involved), and
  `GuidedPlanningEngine` (`lib/services/guided_planning_engine.dart`)
  adjusts the suggested activities and group size, checking every
  adjustment against a curriculum's CDC constraint rules
  (`assets/rules/cbc_2023_constraints.json`, design in
  `assets/rules/README.md`) so no answer can silently drop the topic's
  required competency or override a locked/foundational activity — blocked
  or flagged adjustments are shown to the teacher, not applied silently.
  "Use in Lesson Plan" carries the result into the Lesson Plan screen's
  Lesson Development stage. Only offers itself where a real, sourced
  activity bank exists (`assets/activity_banks/*.json`) — currently just
  History Form 1 → 1.1.1 Reasons for Learning History, transcribed from the
  CDC Teaching Module; every other topic falls back to the plain Lesson
  Plan screen rather than fabricating activities it doesn't have.
- **Resume Lesson (Stage 6)** — in the Lesson Plan screen, below the
  progression stages, the teacher can mark which stage they actually
  reached ("Resume Lesson" chips) and tap "Save progress here". The
  checkpoint (`lib/models/lesson_checkpoint.dart`, persisted on-device via
  `LessonCheckpointRepository`) captures the exact draft — every field and
  progression row typed in, not just the stage — keyed to that specific
  curriculum + subject + grade + topic + sub-topic. Opening the same
  lesson again (via "Lesson plan" or "Guided planning" on that same
  scheme-of-work entry) offers "Resume this lesson?" before showing the
  form, carrying forward the same topic/context exactly as it was left.
- **Upload My Own Template (Settings)** — `lib/screens/settings_screen.dart`,
  reachable from the Subject Selector's app bar. "Upload My Own Template"
  opens `lib/screens/template_upload_screen.dart`: pick a `.docx` file,
  `DocxHeadingExtractor` (`lib/services/docx_heading_extractor.dart`) reads
  its section headings straight from the OOXML (unzips it with the same
  `archive` dependency the document services already use — no PDF support
  yet, that needs a heavier dependency this app doesn't take on). Map each
  heading to an app field that auto-fills from the syllabus (Subject,
  Topic, Sub-topic, competences) or keep it as a plain field you fill in
  yourself; the result saves as an ordinary `LessonPlanTemplate`
  (`CustomTemplateRepository`, on-device via `shared_preferences`) and
  shows up as a selectable alternative — alongside the bundled CDC one —
  the next time you open a lesson plan.
- **CDC Resources (catalog online, downloads on demand)** —
  `lib/screens/cdc_resources_screen.dart`, reachable from the Subject
  Selector's app bar. Lists Teaching Modules and other documents from the
  [CDC Digital Library](https://library.cdcrepository.info/), cached
  locally (`lib/services/cdc_resources_service.dart`) so the list is
  browsable offline. On first launch it seeds from
  `assets/cdc_resources/seed_catalog.json` — 84 real resources (title,
  subject, level, term, direct link) read directly off the CDC site's own
  listing pages, not generated; see that file's `_source` field for exactly
  which pages. A live refresh via the `listCdcResources` Cloud Function is
  throttled to at most once a week and merges newly found resources into
  what's already cached rather than replacing it — that part needs the paid
  Firebase plan (see the "Postponed" section below), but browsing the seed
  catalog and downloading an individual file (plain HTTP) don't. See
  [`firebase/README.md`](firebase/README.md) for why the full library isn't
  bundled (hundreds of MB across 300+ resources).
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
  models/syllabus_models.dart     # Curriculum, Subject, Grade, Term, Topic, SubTopic, ...
  models/scheme_of_work.dart      # SchemeOfWorkEntry + generateSchemeOfWork()
  models/lesson_plan.dart         # CDC lesson plan template field defs + draft model
  models/cdc_resource.dart        # CDC Digital Library catalog entry + cached-catalog model
  services/database_helper.dart   # sqflite schema (curricula → subjects/grades/terms → ...) + import + queries + progress
  services/template_repository.dart  # asset loading + seeding + in-memory cache
  services/progress_repository.dart  # persists the last-concluded-topic mark
  services/entitlement_service.dart  # subscription grace period + ad-unlock + offline gating
  services/auth_service.dart      # anonymous Firebase Auth sign-in
  services/teaching_notes_service.dart  # calls the generateTeachingNotes Cloud Function
  services/lesson_plan_document_service.dart  # renders a lesson plan draft to PDF / DOCX
  services/cdc_resources_service.dart   # CDC catalog fetch/cache/throttle + file download
  services/docx_heading_extractor.dart  # reads section headings from an uploaded .docx
  services/custom_template_repository.dart  # persists uploaded lesson plan templates
  services/offline_teaching_notes_service.dart  # free, on-device teaching notes (no API)
  services/guided_planning_engine.dart  # Stage 5: rule-checked activity/group-size adjustments
  services/guided_planning_repository.dart  # loads activity banks + CDC constraint rules
  services/lesson_checkpoint_repository.dart  # Stage 6: persists mid-lesson checkpoints
  screens/subject_selector_screen.dart  # the Subject Selector UI
  screens/scheme_of_work_screen.dart    # mark progress + generated scheme UI
  screens/scheme_of_work_document_screen.dart  # scheme-of-work PDF/Word export + share
  screens/guided_planning_screen.dart   # Stage 5 guided Q&A UI
  screens/teaching_notes_sheet.dart     # the "Teaching notes" generation UI
  screens/lesson_plan_screen.dart       # lesson plan form + PDF/Word export + share
  screens/cdc_resources_screen.dart     # CDC catalog list + download UI
  screens/settings_screen.dart          # Settings — manage uploaded templates
  screens/template_upload_screen.dart   # "Upload My Own Template" flow
assets/syllabi/
  manifest.json                   # list of bundled curriculum/subject/grade templates
  math_grade8.json                # sample template, 2023 CBC (Term 1 + Term 2)
  english_grade8.json             # sample template, 2023 CBC (Term 1)
  obc2013_english_form3_placeholder.json  # PLACEHOLDER 2013 OBC sample — not real content
  history_form1.json              # REAL content: CBC 2023, Form 1, Term 1 — see its _source field
assets/activity_banks/
  manifest.json                   # list of bundled sub-topic activity banks
  hist_f1_1_1_1.json               # REAL activity bank: History F1, 1.1.1 (from the CDC Teaching Module)
assets/rules/
  README.md                       # Stage 5 CDC-constraint rules-file design
  cbc_2023_constraints.json       # the rules actually used for the 2023 CBC
  cdc_constraints.example.json    # original worked example, used as a fallback
assets/cdc_resources/
  seed_catalog.json               # REAL catalog snapshot from library.cdcrepository.info
firebase/
  functions/src/index.ts          # generateTeachingNotes + listCdcResources Cloud Functions
  README.md                       # Firebase project setup, secrets, deploy
```
