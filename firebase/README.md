# Firebase backend — Zambian Curriculum Companion

Two Cloud Functions, both calling the Anthropic API and both gated behind
Firebase Auth (see "How it's protected" below):

- **`generateTeachingNotes`** — generates teaching notes for a topic/
  sub-topic, grounded in syllabus context already stored on-device.
- **`listCdcResources`** — catalogs Teaching Modules and other documents
  published on the [CDC Digital Library](https://library.cdcrepository.info/)
  by having Claude browse the site with the web search/web fetch server
  tools and return a structured list (title, subject, level, term, URL).

These are the only parts of this app that need a connection — everything
else is offline-first (see the main app's [README](../README.md)).

## Why `listCdcResources` returns a catalog, not the files

The CDC Digital Library lists 300+ resources across 85 subjects; individual
Teaching Module PDFs run 1–8+ MB each, so bundling the whole library would
put the app bundle well into the hundreds of megabytes — impractical for a
sideloaded APK aimed at teachers on limited storage/data. Instead:

- The app fetches and locally caches a **catalog** (metadata only) via this
  function, refreshed at most once a week (`CdcResourcesService` in the
  Flutter app enforces the throttle) — the catalog itself is then viewable
  offline.
- Downloading an actual file happens **on demand**, per resource the teacher
  actually wants, straight from the CDC site — this does require a
  connection, same as the catalog refresh.
- Each call is a best-effort partial crawl (bounded by a tool-call budget,
  not exhaustive), and the app **merges** newly found resources into what
  it already knows rather than replacing the list — so the known catalog
  grows across successive weekly refreshes instead of shrinking back to
  whatever one call happened to find.

## How it's protected

`generateTeachingNotes` is a **callable function** (`onCall`, not a plain
HTTPS endpoint), which is the standard Firebase pattern for "only my app can
call this": the Flutter app authenticates anonymously with Firebase Auth
(see the app README), and the `cloud_functions` SDK automatically attaches
that user's ID token to every call. The function checks `request.auth` and
rejects anything without a valid token — so a request has to come from a
client actually signed in to *this* Firebase project.

**What this does and doesn't protect against:** anonymous auth stops
anonymous/unauthenticated abuse of your Anthropic API key and Firebase
budget, which is what was asked for a prototype. It does **not** stop
someone who extracts your app's Firebase config (client-side config is not
secret) from writing their own client that signs in anonymously and calls
the function directly — that requires
[App Check](https://firebase.google.com/docs/app-check), which attests the
request is coming from your actual compiled app binary. Worth adding before
a real launch; out of scope for this prototype pass.

The Anthropic API key itself never touches the app or the client — it's a
[Firebase secret](https://firebase.google.com/docs/functions/config-env#secret-manager)
read only inside the function, at request time.

## One-time setup

1. **Install the Firebase CLI** (already done if you're reading this after
   the assistant set it up): `npm install -g firebase-tools`.
2. **Log in**: `firebase login` (opens a browser).
3. **Create or select a Firebase project.** New project:
   ```bash
   firebase projects:create zambian-curriculum-app --display-name "Zambian Curriculum Companion"
   ```
   Cloud Functions that call an external API (Anthropic's) require the
   **Blaze (pay-as-you-go) plan** — the free Spark plan blocks outbound
   network calls from functions. Enable it in the
   [Firebase console](https://console.firebase.google.com) → your project →
   Usage and billing → Modify plan. This needs a payment method on file;
   that's a billing action you'll need to do yourself in the console.
4. **Point this folder at your project**:
   ```bash
   cd firebase
   firebase use --add
   ```
5. **Set the Anthropic API key as a secret** (run this yourself — typing a
   secret into a chat session isn't a safe way to hand it over):
   ```bash
   firebase functions:secrets:set ANTHROPIC_API_KEY
   ```
   It'll prompt for the value with hidden input.
6. **Install function dependencies and deploy**:
   ```bash
   cd functions
   npm install
   cd ..
   firebase deploy --only functions
   ```

## Local testing

```bash
cd functions
npm run build
firebase emulators:start --only functions
```

The emulator prints a local URL for `generateTeachingNotes`. Point the
Flutter app at it during development with
`FirebaseFunctions.instance.useFunctionsEmulator('localhost', 5001)` (see
`lib/services/teaching_notes_service.dart` in the app).

## What each function returns

`generateTeachingNotes`:

```json
{
  "notes": "600-750 words of teaching notes...",
  "topic": "Whole Numbers",
  "subtopic": "Place value",
  "format": "bullet"
}
```

`listCdcResources` (takes no arguments):

```json
{
  "resources": [
    {
      "title": "English Language Teaching Module Form 1 - Term 2",
      "subjectName": "English Language",
      "level": "Form 1",
      "term": "Term 2",
      "url": "https://library.cdcrepository.info/resource.php?id=309"
    }
  ],
  "fetchedAt": "2026-08-19T12:00:00.000Z"
}
```

Errors from both come back as standard `HttpsError`s: `unauthenticated`
(no signed-in user), `invalid-argument` (missing/bad request fields, on
`generateTeachingNotes`), `failed-precondition` (the model declined the
request), or `internal` (the Anthropic call itself failed, or —
`listCdcResources` only — its response wasn't valid JSON).
