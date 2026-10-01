# Smart Teacher — Play Store Publishing Status & Handoff Brief

**Date:** 2026-09-17
**Purpose:** Full status snapshot for a second Claude session to review independently — what's done, what's missing, and a detailed diagnostic of one blocked item (Data Safety) so a fresh perspective can attack it differently. Self-assessment of this report's own blind spots is at the bottom — read that before trusting the "confirmed" claims below.

---

## 1. App identity (for context)

- **App:** Smart Teacher — Flutter app for Zambian CBC/OBC curriculum: lesson planning, AI-assisted marking (Gemini), Home Assignment, School Network (multi-school), Timetable Generation (real + build-for-another-school), Admin Tools (Word↔PDF, Minutes Maker, handwriting transcription, Broad Mark Sheet), ECZ past papers, pupil assignment/test submission.
- **Package:** `com.kampmapa1design.smartteacher`
- **Play Console App ID:** `4972056899856168134`
- **Developer account:** "SONIC LABS", Account ID `8366833523358349859`
- **Firebase project:** `zambian-curriculum-app`
- **Repo:** local clone at `C:\Users\user\Documents\zambian-curriculum-app` (GitHub: `kampmapa1-design/zambian-curriculum-app`)
- **Monetization:** none live yet. `EntitlementService.verifySubscription()` is a stub. No ad SDK integrated (deliberately deferred). Real decision (ads / subscription / hybrid) still open.
- **Auth:** anonymous session for all core features (no sign-in required); phone-based verification only for the optional "School Network" feature; email/password and Google sign-in also supported as account-creation methods.

## 2. Current Play Console status — full checklist

**App status:** Draft, never sent to production review.

**Internal Testing track:** ✅ **Active.** Release `8 (0.1.0)` live, "Available to internal testers." Tester list "Internal testers" contains `kampmapa1@gmail.com`. The uploaded `.aab` is real (`build/app/outputs/bundle/release/app-release.aab`, 169.5 MB source, ~38.5 MB delivered).

**App content declarations (11 items):**

| Declaration | Status | Notes |
|---|---|---|
| Privacy policy | ✅ Done | Live at `https://zambian-curriculum-app.web.app/privacy-policy.html`, rewritten to match real code behavior (not the stale original). |
| Ads | ✅ Done | Declared "No ads" — accurate, no ad SDK present. |
| Content rating (IARC) | ✅ Done | Submitted, completed. |
| Advertising ID | ✅ Done | Declared "No." |
| Government apps | ✅ Done | Declared "No." |
| Financial features | ✅ Done | Declared "My app doesn't provide any financial features." |
| Health apps | ✅ Done | Declared "My app does not have any health features." |
| Sign-in details | ✅ Done | Declared "Yes, restricted" (School Network gated by phone verification). Reviewer credentials provided: Firebase test phone number `+260962260778` / OTP `123456` (a real Firebase "test phone number," always accepts that fixed code, no real SMS sent — verified working by surviving a page reload in Firebase Console). Checked "these credentials provide full access" since nothing else in the app is gated. |
| Target audience and content | ✅ Done | Declared age groups 13–15, 16–17, 18+ (no under-13 brackets — matches the app's real audience of secondary-school teachers and pupils). Because no child age bracket is selected, the wizard's "App details / Ads / Store presence" sub-steps auto-skip straight to Summary — confirmed this is expected/correct behavior for this age combination, not a bug (see §3 for the contrast with Data Safety's *incorrect* skip). |
| **Data safety** | ❌ **Blocked** | Saved as a **draft** with the correct "Yes, we collect data" top-level answer, but the actual per-type disclosures (Personal info, Photos, Messages, etc.) have never been enterable. Full diagnostic in §3. **Not submitted** — submitting as-is would falsely declare "No data collection," which I would not do. |

**Store listing (default, en-GB) — Assets step:**

| Field | Status |
|---|---|
| App name | ✅ "Smart Teacher" (auto-filled from app registration) |
| Short description | ✅ "AI lesson planning, marking, and school tools for Zambian CBC/OBC teachers" (74/80 chars) |
| Full description | ✅ 3187/4000 chars, covers every real feature (see `PLAY_STORE_LISTING.md` for the source draft) |
| Category | ✅ Education |
| Contact email | ✅ `kampmapa1@gmail.com` (published) |
| Website | Not set (optional, no real website exists) |
| Phone screenshots | ✅ **5 of 8** uploaded — real device screenshots from the user, cropped from 574×1280 to exact 574×1020 (9:16 ratio, Play Console requires *exactly* 16:9 or 9:16, not "close to"). Show: lesson-plan subject picker, topic-selection checklist, home menu (with real app icon/branding visible), home-assignment picker, document-scanner capture screen. |
| **App icon** (512×512 PNG/JPEG, ≤1MB) | ❌ **Missing — blocking.** Existing app only has mipmap icons up to 192×192 (`android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`); upscaling that to 512×512 would look visibly blurry, so it was deliberately not done. The real icon design (blue rounded-square, open-book-with-orange-pencil motif) is visible small in screenshot #3 but at too low a resolution to extract cleanly. |
| **Feature graphic** (1024×500 PNG/JPEG, ≤15MB) | ❌ **Missing — blocking.** Doesn't exist in any form yet; needs to be designed from scratch. |
| Promo video | Not provided (optional) |
| Tablet / Chromebook / Android XR assets | Not provided (optional, separate collapsible sections on the same page) |

**This is the #1 thing the other Claude session should help with:** generating (a) a crisp 512×512 app icon consistent with the existing blue/book/pencil branding, and (b) a 1024×500 feature graphic. Real brand reference: screenshot #3 in the uploaded zip (`WhatsApp Image 2026-09-17 at 11.59.38 AM.jpeg`, also `cropped/screenshot_3.jpg` in this session's scratchpad) shows the actual icon and app name lockup on a blue gradient background — that's the one visual source of truth available.

## 3. Data Safety — full diagnostic (the part that needs a fresh angle)

### What's being declared (the intended, correct answers)

Per the code-verified audit behind the privacy policy rewrite (see `PLAY_STORE_CONTENT_RATING_AND_DATA_SAFETY.md` in the repo root for the full table):

- Does the app collect/share required data types? **Yes**
- Encrypted in transit? **Yes** (all traffic goes through Firebase/Google Cloud, HTTPS/TLS-only)
- Account creation methods: **Username and password** + **Username and other authentication** (not OAuth, not "username+password+other")
- Can users log in with accounts created outside the app? **No**
- Self-service data-deletion link (without deleting account)? **No** (deletion is handled manually via the contact email — a valid method Play Console's own form explicitly allows, just not via this specific "optional link" field)
- Data types collected (never actually reachable — see below): Name, Email, Phone, User IDs, Other personal info, Photos, Messages — all **Collected: Yes, Shared: No** (per Play's own definition, sending data to Gemini/Brevo as a processor acting "on your behalf" does not count as "sharing" with a third party)
- Data deletion (overall): **Yes**, via contact-email request
- Encryption in transit (overall): **Yes**

### The actual, reproducible bug

The Data Safety form is a 5-step wizard: **Overview → Data collection and security → Data types → Data usage and handling → Preview**.

1. On step 2 ("Data collection and security"), every field above is filled in correctly and the "Next" button becomes enabled (confirmed via screenshot each time).
2. Clicking "Next" **always** jumps straight to step 5 ("Preview"), with steps 3 and 4 shown with checkmarks (implying completion) despite never having been shown or interacted with.
3. The Preview then reads: **"No data collection declared — The developer says that this app doesn't collect user data"** and **"No data shared with third parties"** — directly contradicting the "Yes" just entered on step 2.
4. This happened **identically** across:
   - Multiple fresh attempts in the same browser tab
   - A brand-new browser tab (ruling out tab-local state corruption)
   - Full page reloads between attempts
   - Re-entering all answers from scratch each time (ruling out a one-off typo/misclick)
   - Both possible answers (Yes/No) to "Can users log in with accounts created outside the app?" tested as a diagnostic — no effect on the skip
5. Confirmed via direct DOM/JS inspection (`element.getAttribute('aria-disabled')`, `tabIndex`, and dispatching `.click()` directly via `javascript_exec`) that steps 3 and 4's tab elements are genuinely disabled at the Angular component level, not just visually — the click handler itself refuses to navigate there, it's not a CSS/render issue.
6. **Ruled out:** initially hypothesized this was caused by "Target audience and content" being incomplete (Play Console does show a real dependency message elsewhere: "You must complete the sign-in details section before starting the target audience and content questionnaire"). But after Sign-in details **and** Target audience were both fully completed, the exact same Data Types skip persisted unchanged. So that dependency, while real for a different part of the flow, is not the cause here.
7. Once Target audience was complete, the **real Preview "Save"/Submit button did become enabled** — meaning Play Console would technically accept "No data collection declared" as a final, published answer if submitted. This was deliberately **not done**, since it's factually false.
8. Per Google's own official help doc (`support.google.com/googleplay/android-developer/answer/10787469`), the Data Types step is supposed to be a real, interactive list of data-type categories (Location, Personal info, Photos, Financial info, etc.), each with a "Start" affordance to expand and answer sub-questions (confirmed by a web search turning up third-party integration docs — e.g. Batch's help center — describing exactly that "Start" pattern). **I never once saw that category list or any "Start" buttons** — the wizard never rendered step 3's content at all before jumping to step 5.
9. Current saved state: step 2's answers are saved as a **draft** (confirmed by surviving a full page reload). Steps 3/4 have no saved selections because their UI was never presented.

### What was tried but not conclusively resolved

- **Export to CSV / Import from CSV:** Play Console's Data Safety page has these two buttons. "Export to CSV" was clicked once (button was enabled after a save), but the resulting downloaded file was never actually opened/inspected — I did not confirm whether the browser tool can retrieve downloaded files at all in this session, so this is a real gap, not a dead end. If the exported CSV can be read, editing it to fill in the data-type rows and re-importing might bypass the broken wizard step entirely. **Worth trying properly.**
- **Window resize (mobile-width test):** Attempted to see whether the skip is a responsive-breakpoint bug in the Angular stepper, using `resize_window` to 800×900. The screenshot tool kept reporting the same ~1550px-wide viewport regardless, suggesting the resize affected the OS-level browser window but not the page's actual rendering viewport as seen by the automation — so this test was inconclusive, not negative.
- **No attempt was made to:** log out and back into Play Console, try an Incognito/different browser profile, try a different Google account with edit access on the same app, check Play Console's own status/known-issues page, or try the Play Console Android app.
- **Web search** (done just now, for this report) found no existing public bug report matching this exact symptom, but also confirmed (via third-party integration docs) what the step *should* look like, which narrows the investigation.

### Suggested angles for the other Claude session

1. Actually retrieve and read the Export-to-CSV output — if that file can be fully populated with the correct data-type answers and re-imported, it may sidestep the broken wizard step entirely.
2. Try the exact same flow from a completely different Google/browser session (not just a new tab in the same profile) to rule out an account- or cache-level corruption unique to this browser profile.
3. Search Google's own Play Console Help Community / issue tracker directly (not just general web search) for this exact symptom — "data safety wizard skips to preview."
4. Consider contacting Google Play Developer Support directly with screenshots of steps 2 and 5 side by side — this pattern (steps auto-completing with no way to fill them) is exactly the kind of thing worth escalating as a platform bug if it can't be resolved client-side.
5. Re-test after some elapsed time — some Play Console form bugs are transient server-side issues.

## 4. Everything else that could use reinforcement

- **Monetization:** ads-only / subscription-only (Google Play Billing) / hybrid — still an open decision, not blocking Play Store submission but blocking real revenue.
- **Ad SDK (`google_mobile_ads`) re-integration:** deliberately deferred until after Play Console publishing groundwork; not started.
- **Android developer verification deadline:** Play Console dashboard shows a real deadline of **30 September 2026** to register for Android developer verification (a newer Google requirement, separate from everything above) — noticed but not yet investigated or acted on.
- **Screenshot resolution:** the 5 uploaded screenshots are 574×1020 — below Play Console's "eligible for promotion" recommended minimum of 1080px per side. Not blocking basic listing completion, but real higher-resolution screenshots (screen-recorded or captured at native device resolution rather than a compressed WhatsApp export) would look sharper and unlock promotional placement.
- **Tablet / Chromebook / Android XR store assets:** optional, not filled in, low priority.

## 5. Self-diagnosis — where this report itself could be wrong

Flagging this because it was explicitly asked for, and because handing off unverified claims as if confirmed would waste the other session's time:

- Every "confirmed" claim about the Data Safety bug is based on **UI-level observation** (screenshots, DOM attribute inspection) — I never captured actual network request/response payloads during the "Next" click, because network tracking wasn't active from the start of that investigation. There could be a server-side validation error being silently swallowed by the client that I never saw.
- The claim that browser-tool file downloads are "inert" was carried over from a different tool's documented limitation (the Artifacts viewer sandbox) — I did **not** verify this is actually true for the `claude-in-chrome` browser tool used throughout this session, which drives the user's real Chrome via an extension, not a sandboxed preview. This might mean Export-to-CSV is a completely viable path I abandoned prematurely.
- The `resize_window` test result ("same viewport regardless of resize") could mean the test genuinely proved nothing, or could mean I was reading stale screenshots — I didn't verify the window actually changed size at the OS level before concluding the test was inconclusive.
- I have not independently verified that the phone-number-based reviewer credentials in "Sign-in details" will actually work for a real Google reviewer — only that the Firebase test number itself works when I use it, and that it survived a page reload in Firebase Console.
- App icon/feature graphic: I judged the existing 192×192 icon "too low-res to upscale cleanly" by eye/convention, not by testing an actual upscale and having a design-literate reviewer judge it. It's possible a careful AI-upscale or vector recreation from the visible screenshot would be perfectly acceptable as a placeholder — this is a judgment call the other session may want to revisit rather than accept as settled.

---

**Files referenced in this report** (all in the repo root unless noted): `PLAY_STORE_LISTING.md`, `PLAY_STORE_CONTENT_RATING_AND_DATA_SAFETY.md`, `PRIVACY_POLICY.md`. Cropped screenshots used for the store listing are in this session's scratchpad under `screenshots/cropped/` (not committed to the repo).
