# Credits, metered AI features and ad passes — how it works and what you must do to switch it on

Written 2026-09-19, extended the same day. Everything below is built, tested and
**switched OFF by default**: until you complete the steps in section 4 and change the
settings, nobody is charged anything and every feature behaves exactly as before.

## 1. What was built (plain language)

**One pool of credits for everything.** Each teacher has a balance: **10 free credits
a month (confirmed final by the owner)** (reset on the 1st, Zambia time, no roll-over) plus any bought credits (never
expire). Free credits are spent first. Every charge is made on the server, only after
the generation actually SUCCEEDED, and only once per request. A failed, empty or
unreadable result is never charged.

| What | Cost per successful use (2026) | From 1 Jan 2027 |
|---|---|---|
| Stable marking | 1 credit / page | 1 |
| Concise marking | 3.2 / page | 6.4 |
| Key-based marking | 3.3 / page | 6.5 |
| Lesson plan | 10 | 20 |
| Required core topics research (web-grounded) | 20 | 40 |
| Scheme of work | 10 | 20 |
| Teaching notes | 8 | 16 |
| Slide outline | 6 | 12 |
| Free-topic notes | 8 | 16 |
| Transcription (list / document / reference page / cover page / test submission) | 4 | 8 |
| Marking-key derivation | 8 | 16 |
| Home-assignment generation | 8 | 16 |
| Minutes | 8 | 16 |
| Timetable — independent tool (computed, no AI) | 2 | 2 |
| Timetable AI helpers (explain / read a constraint / read a photo) | 3 | 5 |
| Voice command, topic search, candidate-name detection | 0 (logged only) | 0 |

**The feature costs are STARTING ESTIMATES, not measurements** — my rough token counts
priced at Gemini 3.6 Flash rates, with one credit worth about $0.0026 of AI cost (the
level the marking weights were built on). The real cost of every call is now recorded,
and the Owner finance screen shows, for each feature, the measured cost per use and
the implied cost per credit, flagging any feature that costs materially more than it
charges. Correct the numbers from that data before relying on them.

**Ad passes (built, dormant).** A rewarded ad can pay for ONE generation of a
non-marking feature. The server only accepts an ad as proof when Google's own AdMob
servers call back with a signed message (server-side verification) — a phone saying
"I watched an ad" proves nothing and is never trusted. At most 5 passes a day per
teacher; each valid for 24 hours; never usable for marking. **This cannot work yet**
— see section 3.

**CDC catalogue fix.** The catalogue crawl (two web-grounded Gemini calls, the most
expensive thing in the backend) is now rationed by a spend guard: at most one crawl in
flight anywhere, at least 6 hours between attempts, doubling after each failure up to
48 hours, and failures are remembered. A user request can no longer trigger a crawl
on its own; anyone refused gets the last cached catalogue. The weekly refresh goes
through the same guard, and the crawl's real cost is logged.

The two switches, in the `appConfig/markingCredits` document:
* `mode` — marking: `off` / `shadow` / `enforced`.
* `featuresMode` — every other AI feature: `off` / `shadow` / `enforced`. Separate, so
  you can turn marking on first. Enforcing marking does NOT start charging features.

## 2. Things that are different from what you might expect

* **Where in the app credits are spent is the same wallet.** Free credits and bought
  credits pay for marking AND the other AI features. When a teacher runs out they
  see one "Out of credits" dialog (from anywhere in the app) with a "Get credits" button.
* **School timetable creation (owner's decision 2026-09-19).** Only Gold and Institutional
  schools have it at all - every school timetable function refuses a Basic school on the
  server. A subscribed school gets **$1 of real AI cost a month included** for timetable
  work (`schoolAllowancesUsd.timetable` in the config; measured from the actual token
  cost, per school, per Zambian calendar month). The use that crosses $1 is still
  included; after that, each timetable use (the engine and the AI helpers) is charged in
  credits to the administrator making the request - there is no school wallet, so a
  school over its allowance is paying out of individual administrators' credits.
  Not yet covered: the *independent* timetable tool ("Build Timetable for Another School")
  has no school and no subscription to check, so it is simply credit-metered (2 credits to
  build, 3 per AI helper). Whether it should also be locked to subscribers is open.
* **The old phone-side monthly caps** (4 lesson plans, 2 schemes of work, 1 timetable) and
  the marking counter are dormant/removed; credits replace them.
* **The owner finance tools are in the web admin dashboard**, under "Owner finance" in
  its sidebar, shown only to accounts listed in `ownerData/settings` (checked on the
  server). (An earlier version of this document, and of my first build, wrongly said no
  web dashboard existed and put them on the phone under Scan Marker — corrected.)
  Start it with `admin_dashboard.bat`, or deploy it for schools (section 4.5).
* **Salvaged (partly recovered) marking results:** charged only if salvaging incurred FRESH
  cost (owner's rule). Salvaging just re-reads text the AI already returned - no further
  API call - so it costs nothing extra and is not charged. (The AI calls that led up to it
  are the same cost whatever happens, and a result that arrives complete after an internal
  retry is charged normally, once.)
* **Revenue is counted at the bundles' list price**, not what Google actually paid out.
* **The K800,000 VAT threshold is unverified** — editable in `ownerData/settings`.
* **Scenario 2 bundle sizes were not supplied** (`scenario2` is `null`; it falls back to
  Scenario 1). Crossing the threshold sets a flag and emails you; it does not switch
  anything automatically.
* **Credits belong to the account.** Buying requires a real sign-in. A new anonymous
  account gets its own 10 free credits, so someone could reinstall to collect more
  (about $0.026 of AI each). Enforcing App Check and keeping the Gemini spend cap set are
  the real defences.
* **Known limit — parallel requests.** The balance is checked before the AI call and
  charged after it. A determined person firing many requests at once from one account
  could get several generations past the check and only pay for what the balance
  covers (the shortfall is recorded, the balance never goes negative). The exposure is
  bounded by how many run at once, and is the reason to enforce App Check. If it
  matters, the fix is to reserve credits when the request starts — say so and I'll
  build it.
* **I could not test against real Google Play, real AdMob, or real Gemini token counts.**

## 3. Ads: what has to exist before the "watch an ad" option can work

1. **A working ad SDK in the app.** `google_mobile_ads` was removed on 2026-08-30 because it
   crashed the app on launch on a real phone (Moto G05). The app has only a stub that
   claims every ad was watched — which is exactly why the server never believes the
   phone. Bringing the SDK back safely means pinning a version and testing a release
   build on several real phones first. I did not re-add it.
2. **An AdMob account, an app entry and a rewarded ad unit** with server-side verification
   turned on, its callback URL set to the `admobRewardCallback` function (URL shown after
   you deploy), and the app passing the Firebase user id as the verification user id.
3. **You cannot choose the ad's length.** AdMob decides what plays; a 60-second rewarded ad
   can't be guaranteed (rewarded videos are usually far shorter). The pass is earned by
   completing whatever rewarded ad plays. How much one ad view earns in Zambia is
   unknown to me and is probably less than a lesson plan costs (about $0.025), so the
   daily cap of 5 is what limits the loss. Check real AdMob earnings before relying on this.
4. Then set `adPasses.enabled` to `true` in the config.

Until all four are done the option is never shown and no pass can exist.

## 4. What you need to do (in this order)

### 4.1 Deploy the backend (I cannot deploy — that's yours)

```bash
cd firebase
firebase deploy --only firestore:rules
firebase deploy --only functions
```

New functions: `admobRewardCallback`, plus the earlier `redeemMarkingBundle`,
`amIOwner`, `getOwnerFinanceSummary`, `updateExchangeRate`, `dailyRevenueRecompute`.
The CDC change alters `listCdcResources` and `refreshCdcResourcesWeekly`.
(Earlier pending items still apply: `firebase deploy --only storage`, and deleting the
dead `internalBatchSyllabusExtract` function.)

### 4.2 Load the configuration into Firestore (Firebase console → Firestore)

1. Create `appConfig/markingCredits` from `firebase/seed/marking_credits_config.json`
   (delete `_readme` if you like). **Leave `mode` and `featuresMode` as `"off"`.**
2. Create `ownerData/settings` from `firebase/seed/owner_settings.template.json` with
   **your** Firebase user id in `ownerUids` (shown as "Account ID" at the bottom of the
   web admin dashboard's sidebar once you sign in — tap to copy).

### 4.3 Play Console and Google Cloud (before any real purchase)

1. Play Console → Monetize → In-app products: create `marking_bundle_k50` (K50),
   `marking_bundle_k100` (K100), `marking_bundle_k150` (K150) and activate them.
2. Google Cloud console (project `zambian-curriculum-app`) → enable the
   **Google Play Android Developer API**.
3. Play Console → Users and permissions → invite the service account
   `377253758104-compute@developer.gserviceaccount.com` with permission to view
   financial data and manage orders.
4. Add licence testers (Play Console → Settings → License testing).
5. Payouts to a Zambian bank / mobile money are a separate open question.

### 4.4 Roll out in stages

| Step | Setting | What happens |
|---|---|---|
| A. Now | everything `off` | Nothing changes for anyone. Real token cost is recorded for every AI feature from the first use, so the estimates above can be corrected. |
| B. Measure | leave `off` for 1–2 weeks of real use | Owner finance screen fills in: measured cost per use for each feature. Adjust `features` weights in the config from it. |
| C. Trial | `featuresMode` and/or `mode` = `shadow` | Records what WOULD be charged. Nobody is charged or blocked. |
| D. Live | `mode` = `enforced` first, then `featuresMode` = `enforced` | Real charging and "out of credits". Do this only after 4.3 is done and one licence-tester purchase has credited correctly. |

## 5. What the tests prove

* 97 backend unit tests, 74 emulator integration tests, 128 security-rules tests and 503
  app tests pass. The emulator tests cover: charge-only-on-success, exactly-once per
  request id (also across different features), refused-before-the-AI-call, off/shadow
  never touching a balance, the 2027 price switch, ad passes (single use, daily cap,
  no forging, no borrowing, expiry, failed generation keeps the pass), and the CDC
  guard (of 12 simultaneous callers exactly one crawls; 500 callers after a failure
  start none).
* Not covered by any automated test: real Google Play, real AdMob, real Gemini token
  counts, and how the new screens look on a real phone.

## 4.5 Individual-teacher subscriptions (owner decision, 2026-09-28)

A teacher can now hold a personal Gold/Institutional-equivalent subscription
that unlocks Timetable Generation for themselves alone, even at a Basic (or
no) school — enforced identically on the server (every timetable Cloud
Function) and in both client UIs (phone + web dashboard).

**How to grant one, for now** (same manual-for-now pattern already used for
`schools/{id}.subscriptionTier`, since there is no real self-serve purchase
path for this yet — see the open items below): Firebase Console → Firestore
→ create a document at `personalSubscriptions/<their-uid>` with one field,
`tier` set to `"gold"` or `"institutional"` (find their uid from Settings →
Account ID inside the app, same place the owner's own uid is found for
`ownerData/settings`). A client can only ever READ its own doc
(`firestore.rules`) — there is no in-app way for a teacher to grant this to
themselves.

**Not yet built** — a real way for a teacher to actually buy this: neither a
Google Play *recurring subscription* product (a different Play API from the
one-time marking-credit bundles already wired up — `purchases.subscriptionsv2`,
not `purchases.products`) nor a website payment path (see the PhiloSoft
infrastructure notes) exists yet. Whichever is built first should write into
this same `personalSubscriptions/{uid}` collection rather than needing a
second gate — `meetsTimetableTier` in index.ts and `School.meetsTimetableTier`
client-side don't care how the tier got set.

## 4.6 The web admin dashboard: opening it instantly, and for schools

**On your PC (instant):** double-click `admin_dashboard.bat` in the project folder. It
serves a pre-built copy at http://localhost:8765/ and opens it — no compile wait. If you
change the app's code and want the change in the dashboard, run `admin_dashboard.bat rebuild`
(a few minutes). The old way (`flutter run -d web-server`) recompiles from scratch every
time and loads about 1,300 script files in debug mode, and the page is BLANK until that
finishes — that was the "won't open" you saw. It is still available on port 8766 as
`web-admin-dashboard-dev` for development.

**For every school (a real web address):** the dashboard already shows each teacher their
own school after they sign in (their school comes from their account, not from anything
typed), so one deployment serves every school. To publish it:

```bash
flutter build web --release -t lib/main_web.dart --base-href /admin/ -o firebase/hosting/public/admin
cd firebase
firebase deploy --only hosting
```

It is then at `https://zambian-curriculum-app.web.app/admin/` (`firebase.json` already routes
`/admin/**` to it and stops browsers caching a stale copy). The existing privacy-policy page
at the site root is untouched. Before enforcing App Check on functions, the web app would
need its own App Check registration.

### Who can use the web dashboard, and what they see

| Person | Institutional school | Any other school |
|---|---|---|
| Head Teacher, Deputy, Administrator | Everything (class board, report forms, timetable, by-teacher, staff, staffroom, broadcast) | Timetable creation only (Setup, Constraints, Generated) |
| Timetable operator (not one of the three) | Timetable creation only | Timetable creation only |
| Any other teacher, grade teacher, observer | Not let in ("for school administrators" page) | Not let in |
| App owner | Additionally sees "Owner finance", whatever their school role | Same |

Timetable creation still needs a **Gold plan or higher** (that rule is enforced on the
server and is unchanged), so at a Basic school an administrator sees a notice saying so.
These rules decide what the dashboard screen offers; the Cloud Functions behind each action
still check role and plan themselves. Note the school data itself can still be read by any
member of the school through the phone app - that is unchanged.
