# Google Play — Content Rating & Data Safety

Both drafted from the same code-verified data-flow audit behind the privacy policy rewrite (not guessed). Google's exact question wording shifts between Play Console updates, so treat these as the *true answer* to whatever the actual question is asking, not a literal script — read each real question and match it to the relevant point below.

---

## Content Rating (IARC questionnaire)

Smart Teacher is a pure education/productivity app with no authored violent, sexual, drug-related, or gambling content anywhere in it. Expect this questionnaire to land the app at the lowest rating tier (Google's "PEGI 3" / "Everyone" equivalent). Answer key by category:

| Category | Answer | Why |
|---|---|---|
| Violence (any form — cartoon, fantasy, realistic) | **No** | Nothing in the app depicts violence. |
| Blood/gore | **No** | — |
| Sexual content / nudity | **No** | — |
| Profanity / crude humor (authored by the app) | **No** | The app itself contains no profanity. |
| References to alcohol, tobacco, drugs | **No** | — |
| Gambling (simulated or real-money) | **No** | — |
| Horror / fear themes | **No** | — |
| **User-generated text** (Staffroom posts, marking comments, Minutes Maker notes, broadcast messages) | **Yes, user-generated content exists** — but flag it as **not public**: every place free text can be typed is scoped to one school's own staff/pupils (Staffroom is per-school, marking comments are private between teacher and pupil), never a public feed visible to strangers. If the questionnaire distinguishes "shared publicly" from "shared within a private group," answer the latter. | Confirmed via `firestore.rules` — every collection holding free text is gated by school/class membership, nothing is world-readable. |
| Shares user location with other users | **No** | App collects no location data at all (confirmed: no GPS permission, no location code anywhere). |
| Digital purchases (real-money in-app purchases) | **No, currently** | `EntitlementService.verifySubscription()` is a stub — no real payment/store integration exists yet. Revisit this answer the moment real subscription billing goes live. |

## Target audience and content (separate section from the rating itself)

This is the one place I'd flag for your own judgment rather than assert an answer outright — it's a real compliance decision, and I'm not a lawyer:

- The app has **two real audiences**: adult teachers/school staff (the primary, feature-richest side) and **secondary-school pupils** (CBC Form 1–2 is roughly ages 13–15, OBC Grade 10–12 is roughly ages 15–18) — so the pupil side is used predominantly by **early-to-late teens, not children under 13**.
- Play's stricter "primarily child-directed" rules (and the separate "Designed for Families" program) exist specifically for apps aimed at **under-13s**. Based on the real age range of CBC/OBC secondary pupils, this app does not appear to fit that category — but the honest, defensible declaration is something like **"13 and older, plus adults"** rather than "designed for children" or "not for children at all" (the old, now-replaced privacy policy's blanket claim).
- If you want a second opinion before locking this in, Play Console's own in-flow guidance (it asks a short series of questions to help you land on the right answer) is a reasonable next step — I'd rather you go through that directly than have me assert a final legal position.

---

## Data Safety section

Play Console's own definition of "shared" specifically **excludes** data sent to a service provider that processes it *on your behalf and under your instruction* (this is stated in Play Console's own Data Safety help documentation) — which is exactly what Google Gemini (AI processing) and Brevo (sending emails you compose) are here: neither uses the data for their own independent purposes. So most rows below are **Collected: Yes, Shared: No** — that's the accurate answer per Google's own definition, not a shortcut.

| Data type | Collected? | Shared? | Purpose | Optional/Required | Notes |
|---|---|---|---|---|---|
| **Name** | Yes | No | App functionality, Account management | Required (teacher's own name); pupil roster names entered by teacher are required for class features | |
| **Email address** | Yes | No | App functionality, Account management | Optional (only if signing in by email, or a guardian email is entered) | |
| **Phone number** | Yes | No | App functionality, Account management | Optional (only if signing in by phone, or a guardian phone is entered) | |
| **User IDs** | Yes | No | App functionality | Required | Firebase Auth UID |
| **Other personal info** (role, school/class assignment) | Yes | No | App functionality | Required for School Network features | |
| **Photos** | Yes | No | App functionality | Required for AI-marking/submission features | Most photos are processed by Gemini and not separately retained; a specific few (Home Assignment answer photos, Scan Marker batches, Teacher Submissions Dashboard files, school logo) are kept in cloud storage for the feature's own purpose — see privacy policy for the exact list |
| **Audio files** | **No** | — | — | — | Voice commands are transcribed **on-device**; audio is never recorded to a file or uploaded — confirmed in code, this is a real "No," not an oversight |
| **Messages** (Staffroom posts, broadcasts, guardian emails) | Yes | No | App functionality | Required for those features | Not shared publicly — see content-rating note above |
| **Files and docs** | No | — | — | — | Word/PDF conversion happens on-device; no server-side file storage for this feature |
| **App activity, App info & performance** | **No** | — | — | — | No analytics or crash-reporting SDK is present anywhere in the app — confirmed absent from `pubspec.yaml` |
| **Device or other IDs** | **No** | — | — | — | Confirmed via grep: `firebase_messaging`/`FirebaseMessaging` appears nowhere in the codebase — the "FCM Registration API" showing enabled on the Google Cloud project is just a default Firebase project API, never actually called by any real feature |
| **Financial info** | No | — | — | — | No payment/billing integration exists yet |
| **Location** | No | — | — | — | No GPS/location permission or code anywhere |
| **Health and fitness, Web browsing, Contacts, Calendar** | No | — | — | — | None of these are collected |

**Data deletion**: declare "Yes, users can request their data be deleted" — handled via the contact email in the privacy policy (a manual/support-request process, not an in-app self-service delete button, which Play Console's form explicitly allows as a valid method).

**Data encryption in transit**: declare "Yes" — every real data flow goes through Firebase/Google Cloud endpoints (Firestore, Cloud Functions, Cloud Storage, Firebase Auth), which are HTTPS/TLS-only by default.

Every row in this table is now traceable to a specific, confirmed real code path — nothing left to verify before filling in either form.
