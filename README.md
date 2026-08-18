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
  services/database_helper.dart   # sqflite schema + import + queries
  services/template_repository.dart  # asset loading + seeding + in-memory cache
  screens/subject_selector_screen.dart  # the Subject Selector UI
assets/syllabi/
  manifest.json                   # list of bundled subject/grade templates
  math_grade8.json                # sample template
  english_grade8.json             # sample template
```
