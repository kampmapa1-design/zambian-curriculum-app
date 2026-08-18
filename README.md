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
4. Run on a connected device or emulator:
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
  screens/subject_selector_screen.dart  # the Subject Selector UI
  screens/scheme_of_work_screen.dart    # mark progress + generated scheme UI
assets/syllabi/
  manifest.json                   # list of bundled subject/grade templates
  math_grade8.json                # sample template (Term 1 + Term 2)
  english_grade8.json             # sample template (Term 1)
```
