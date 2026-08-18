# Firebase backend — Zambian Curriculum Companion

A Cloud Function (`generateTeachingNotes`) that calls the Anthropic API to
generate teaching notes for a topic/sub-topic, grounded in syllabus context
already stored on-device. It's the one part of this app that needs a
connection and a backend — everything else is offline-first (see the main
app's [README](../README.md)).

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

## What it returns

```json
{
  "notes": "600-750 words of teaching notes...",
  "topic": "Whole Numbers",
  "subtopic": "Place value",
  "format": "bullet"
}
```

Errors come back as standard `HttpsError`s: `unauthenticated` (no signed-in
user), `invalid-argument` (missing/bad request fields),
`failed-precondition` (the model declined the request), or `internal`
(the Anthropic call itself failed).
