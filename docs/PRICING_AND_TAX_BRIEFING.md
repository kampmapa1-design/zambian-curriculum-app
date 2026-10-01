# Smart Teacher — Pricing, Marking Bundles & Zambian Tax Briefing

**For:** the finance/accounting assistant working with the app's owner in Zambia
**Prepared:** 2026-09-19, by the app's development assistant
**Status:** DRAFT for accountant review. Nothing in the app charges anyone yet, and no figure below is final.
**Companion file:** `docs/marking_pricing_model.py` — a runnable model. Every number in §6 comes from it; change any input and re-run.

---

## 0. Read this first

**What this is.** The app's owner needs to (a) price three marking bundles (K50, K100, K150), (b) finalise subscription tiers, (c) price a per-school Institutional tier, and (d) do all of it under Zambian tax and regulatory reality, with a strict profit rule (§3). This document gives you every fact we have, says how sure we are of each, and lists exactly what we need back from you (§1).

**Evidence tags used throughout**

| Tag | Meaning |
|---|---|
| `[VERIFIED]` | Read from the provider's own documentation on 2026-09-19 (URLs in §12) |
| `[CODE]` | Read from the app's source code |
| `[OWNER]` | A decision or figure stated by the owner |
| `[BELIEVED]` | Our understanding, not checked against a primary source — **verify before relying on it** |
| `[ASSUMED]` | Our own estimate — **replace with measured or real figures** |
| `[UNKNOWN]` | We do not know; you are being asked |

**The single most important caveat.** The app records **no token usage at all** today (no `usageMetadata` is logged anywhere in the backend). So the per-page AI costs below are *modelled*, not *measured*. Only the Gemini **prices** are verified. The plausible range on cost per page is about **5× wide** (Lean vs Heavy in §6). Please treat the bundle sizes as a first draft and plan to re-run the model once §10 measurements exist.

**This supersedes** an earlier informal estimate given in chat (which used an older image-token method and a single engine). Use the numbers here.

### Headline result (Base assumptions, 2026 prices, Play fee 15%, 16% VAT inside the price)

One "page" = one photographed page of a pupil's answer script. A typical script is ~4 pages `[ASSUMED]`.

| Bundle | Concise | Key-based | Stable |
|---|---|---|---|
| **K50** ($2.50) | 61 pages (~15 scripts) | 60 pages (~15 scripts) | 193 pages (~48 scripts) |
| **K100** ($5.00) | 124 pages (~31 scripts) | 122 pages (~30 scripts) | 394 pages (~98 scripts) |
| **K150** ($7.50) | 188 pages (~47 scripts) | 185 pages (~46 scripts) | 595 pages (~149 scripts) |

**Cascade:** 1 Concise page ≈ 0.99 Key-based pages ≈ **3.16 Stable pages** (2026). From 1 Jan 2027 Concise/Key-based roughly double in cost while Stable does not, so 1 Concise page ≈ **6.3 Stable pages**.

**Read the ranges before quoting any of these.** Depending on tax reading and cost scenario, K100/Concise runs from **25 to 331 pages** (§6.7). A class of 40 pupils is 40 scripts ≈ 160 pages, so even the Base K100 Concise bundle marks under one class.

---

## 1. What we need back from you (deliverables)

1. **Real Zambian tax treatment** for each item in §8 — actual rates, thresholds, and which apply to this business. Then state the two numbers the model needs: `t` (share of the customer's payment that goes to revenue-based tax) and `τ` (income-tax rate on profit, if applicable).
2. **Which reading of the profit rule (§3) is correct**, and confirm the target: net profit ≥ 100% of total costs (≥ 50% net margin on revenue).
3. **Recommended bundle sizes** for K50 / K100 / K150, per engine, with a stated safety margin — sized on a *pessimistic* cost, not the average (§7).
4. **A credit-weight scheme** (e.g. 1 Stable page = 1 credit; Concise = ?; Key-based = ?), including how to handle the **1 Jan 2027 Gemini price change**.
5. **A metering decision:** buy-as-you-go bundles, monthly cap per tier, or a hybrid — plus validity/expiry, refund and revenue-recognition treatment.
6. **An Institutional price formula** by number of teachers and learners, with worked prices for the three school sizes in §9, and the right billing cycle (schools budget per term).
7. **Channel viability:** can we receive Google Play payouts in Zambia, can Zambians pay via Play, and is mobile-money billing permitted for a Play-distributed app (§8d–e). This may change the whole plan.
8. **A currency policy:** costs are in US dollars, prices in kwacha (§6.7). When do we re-price?
9. **A compliance checklist with costs** (registrations, data protection).
10. **A break-even model** including fixed costs (§5), which the per-unit tables here deliberately exclude.

---

## 2. The business in brief

- **Product:** Android app "Smart Teacher" for Zambian teachers and pupils, covering both national curricula (CBC 2023 and OBC 2013): lesson plans, schemes of work, records of work, report forms, AI-assisted marking (teacher photographs pupils' scripts), a "Home Assignment" feature (pupils submit answer photos), school-wide timetable generation, and a School Network for staff. Most planning tools work offline; AI features call Firebase Cloud Functions, which call Google Gemini. `[CODE]`
- **Stage today:** closed testing with about 7 testers. The first Google app review (14 changes) was submitted 2026-09-18 and typically takes up to 7 days. **No paying users. Every paywall flag in the code is OFF** (`kEntitlementEnforced`, `kFreeTierCapEnforced`, `kGradingCapEnforced` are all `false`); usage is tracked locally only. `[CODE]`
- **Names on accounts:** Play developer account display name "Sonic Labs"; app-signing certificate organisation "Kampmapa1 Design", Lusaka. **Legal form, TPIN and VAT registration status: `[UNKNOWN]`.**
- **Currency:** prices are set in kwacha. The owner converts at **K20 = US$1** (K70 = $3.50, K50 = $2.50). `[OWNER]` The real rate moves (§6.7).
- **Where users are:** Zambia. Taxes are expected to be paid in Zambia. `[OWNER]`

---

## 3. The profit rule

**Owner's words** `[OWNER]`: for every $10 of *all costs and obligations, including taxes*, the business should make $10 or more in *net* profit.

**Formal statement:** net profit ≥ total costs (including taxes) ⇔ **Revenue ≥ 2 × total costs** ⇔ a net margin of at least **50%** of revenue.

"Taxes" can be read two ways, and the difference is large. **Please choose.**

| | Reading **A** — taxes are a share of the payment | Reading **B** — income tax on profit |
|---|---|---|
| What it models | VAT taken out of a VAT-inclusive price, or a turnover tax | Corporate/income tax at rate `τ` on profit |
| Let | `f` = channel fee (Play etc.), `t` = tax share of price, `R` = price | `f`, `τ`, `R` |
| Condition | AI budget ≤ `R(1 − 2f − 2t)/2 − infra` | Operating costs `K` ≤ `R(1 − 2τ) / (2(1 − τ))` |

**What this means in practice**
- Under A with no tax, total per-unit costs (fee + AI + infra) can be at most **50%** of the price.
- Under B with `τ` = 30% `[BELIEVED]`, they can be at most **28.6%** of the price. That is a big drop, and it means **the channel fee alone must be below 28.6% of the price.** A 30% Play fee then makes any bundle fail the rule outright (the K100/30% cell in §6.7 shows 0 pages).
- Fixed costs (§5) are **not** in the tables — they are per-unit only. Add an allocation.
- **Decision for the owner/accountant:** is the owner's own labour a "cost" under this rule? It changes everything and is currently excluded.

---

## 4. Products and prices — decided vs open

| Item | Status |
|---|---|
| **Basic ("Access") tier** — teachers | **K70/month** (~$3.50) `[OWNER]`. What it includes is **undecided**. |
| **Gold tier** | **K150/month**, exactly 2× Basic `[OWNER]`. Inclusions undecided beyond the timetable rule below. |
| **Institutional (Platinum)** | Price **undecided**. Rule `[OWNER, 2026-09-19]`: **has all functions of the app; price differs *only* by number of teachers and learners**; priced **per school**, not per teacher. |
| **Timetable creation engine** | Available **only** on Gold and Institutional `[OWNER, 2026-09-19]`. |
| **Marking bundles** | Proposed K50 ($2.50), K100 ($5.00), K150 ($7.50) `[OWNER]`. Whether tiers *also* carry a free monthly marking allowance is undecided (code today: 5 free scripts/month). |
| **Metering** | Open: bundles vs monthly caps vs hybrid. |

### Where the code does not yet match these decisions (for the developer, not you)
1. The code gives every device a free allowance of **1 timetable generation per month** (`FreeTierFeature.timetableGeneration`), which contradicts "Gold and Institutional only".
2. The "Build Timetable for Another School" tool has **no tier gate at all** (by its own doc comment).
3. School tier (`School.subscriptionTier`: basic / gold / institutional) is set **by hand in the Firebase Console**; there is no payment flow, no receipt verification, and no Play Billing integration yet.
4. Existing free quotas in code `[CODE]`: lesson plans 4/month, schemes of work 2/month, timetable generation 1/month, marking 5 scripts/month. All un-enforced.

---

## 5. Cost inventory

| Cost line | Driver | Currency | Status |
|---|---|---|---|
| **Gemini API** | tokens per AI call | USD | Prices `[VERIFIED]` (§6.2). Volumes `[ASSUMED]`. |
| **Google Play service fee** | share of each sale | USD/local | 15% on subscriptions; 15% on the first $1M/year of other digital sales for eligible developers, 30% above that `[BELIEVED]` — verify eligibility/enrolment |
| **Taxes** | revenue and/or profit | ZMW | `[UNKNOWN]` — §8 |
| **Firebase (Firestore, Functions, Storage, Logging)** | reads/writes, GB-seconds, GB stored, egress | USD | `[UNKNOWN]` real spend. Plan assumed pay-as-you-go. |
| **Cloud backups (new feature)** | up to 250 MB × 14 retained backups per teacher (worst case 3.5 GB) | USD | Object storage is roughly $0.02–0.03/GB-month `[BELIEVED]`; typical backup size `[UNKNOWN]` |
| **SMS for phone sign-in** | one SMS per verification (Firebase Phone Auth) | USD | **`[UNKNOWN]` — can be expensive in some countries; find Zambia's rate** |
| **Transactional email** | emails sent (Brevo) | USD | `[UNKNOWN]` plan and limits |
| **Crashlytics / App Check** | — | — | free at this scale `[BELIEVED]` |
| **Play developer registration** | one-off | USD | ~$25 `[BELIEVED]`; likely already paid |
| **Payout/banking/FX** | conversion spread, bank charges | mixed | `[UNKNOWN]` |
| **Compliance** | registrations, filings | ZMW | `[UNKNOWN]` — §8f–g |
| **Owner/developer labour, devices** | — | — | excluded pending decision (§3) |

**Real-world burn data points** (from the owner's billing history, `[OWNER]`/observed):
- Gemini uses **mandatory prepay** on this account ("Paid 1" tier, **$250 cap**). A $15 top-up was fully spent in ~11 days of heavy feature testing; a $21 top-up was spent in ~4 days, mostly due to a since-fixed bug (an uncached web-crawl function). The app currently logs **no per-user cost attribution**.

---

## 6. AI marking economics

### 6.1 The three engines (from the code)

All three are served by one Cloud Function, `gradeMarkingScriptConcise` `[CODE]`. Menu names are as the teacher sees them under Scan Marker.

| Engine (menu name) | Model | How it marks | Output |
|---|---|---|---|
| **Concise Marking** | `gemini-3.6-flash` | "Pure AI": reads the paper's own rules, identifies questions, marks from subject knowledge; may also receive question-paper images (up to 10, re-sent with *every* script) and an optional reference key | Per-question marks **+ page number + bounding box** (for ticks/crosses on the photo), rubric, 3–8 observations |
| **Stable Marker** | `gemini-3.5-flash-lite` (cheaper, ~4 s vs ~16–20 s) | Same pure-AI approach, lighter model | Marks only — **no boxes** — plus rubric and observations |
| **Uploaded Marking Key Based Marking** | `gemini-3.6-flash` | Strictly bound to a marking key the teacher uploaded; key text sent with each call | Same as Concise, including boxes |

Also present: an older scheme-based path (`gradeMarkingScript`, `gemini-3.6-flash`) — economically similar to Key-based, not modelled separately; and one-off marking-key derivation from a question paper (`deriveMarkingKeyFromQuestionPaper`) — a per-key cost, not modelled. Home Assignment marking (pupil photo submissions) reuses Concise/Stable.

### 6.2 Verified pricing (Google, read 2026-09-19)

| Model | Input $/1M tokens | Output $/1M tokens *(includes thinking)* | Batch (50% off) |
|---|---|---|---|
| `gemini-3.6-flash` — **through 31 Dec 2026** | $0.75 | $3.75 | $0.375 / $1.875 |
| `gemini-3.6-flash` — **from 1 Jan 2027** | **$1.50** | **$7.50** | $0.75 / $3.75 |
| `gemini-3.5-flash-lite` | $0.30 | $2.50 | $0.15 / $1.25 |

`[VERIFIED]` for all three. **No 2027 price change is announced for Flash-Lite.** Context caching exists for 3.6 Flash only (cached input $0.075 → $0.15 in 2027).

### 6.3 How a call is billed

- **Images:** Google's default for Gemini 3 models is **1,120 tokens per image** (`low` 280, `medium` 560, `high` 1,120, `ultra_high` 2,240). `[VERIFIED]` for "Gemini 3 models" — the page does **not** confirm the table for 3.5/3.6 specifically, so treat as `[ASSUMED]`. The older tile method (258 tokens per 768×768 tile, ~6,192 tokens for a 3000×4000 photo) is kept as the "Heavy" scenario in case these newer models still use it.
- **Thinking is ON by default and billed as output:** `gemini-3.6-flash` defaults to *medium*; `gemini-3.5-flash-lite` to *minimal*. `[VERIFIED]` The app sets **no** thinking level anywhere, so it pays the default.
- **Retries:** the server tries a call up to twice (a second attempt, without the JSON schema, if the first fails or returns unparseable output), and the marking queue's batch runner retries a failed script once more — so the worst case is several full calls for one script. Every retry re-sends and re-bills all the images. Modelled as a 1.05–1.25× factor `[ASSUMED]`; the real failure rate is `[UNKNOWN]`.

### 6.4 Token model (all `[ASSUMED]` unless noted) — one 4-page script, Base scenario

| Input | Tokens |
|---|---|
| Instructions + marking conventions + subject text | 3,000 |
| Images (4 pages × 1,120) | 4,480 |
| Key text (Key-based only, ~40/question) | ~1,280 |

| Output | Tokens |
|---|---|
| Per question: Concise/Key-based ~100, Stable ~70 (32 questions/script = 8 per page) | 3,200 / 2,240 |
| 3–8 observations + rubric + wrapper | ~400 |
| **Thinking**: 3.6 Flash ~3,000; Flash-Lite ~300 | 3,000 / 300 |

Resulting totals (Base, 2026): **Concise 7,480 in / 6,600 out; Stable 7,480 in / 2,940 out; Key-based 8,760 in / 6,450 out.**

**What drives the cost.** At Base, roughly **80% of a Concise page's cost is output** (≈37% thinking, ≈40% the per-question JSON) and only ≈18% is input/images. This is a derived result of the assumptions, not a measurement — but if it holds, the biggest savings come from *thinking level*, not image size (§6.9).

### 6.5 Scenarios

| Scenario | Image tokens/page | Questions/page | Thinking tokens/script (Flash / Lite) | Retry factor | Question-paper pages re-sent (Concise) |
|---|---|---|---|---|---|
| **Lean** | 1,120 | 6 | 1,000 / 0 | 1.05 | 0 |
| **Base** | 1,120 | 8 | 3,000 / 300 | 1.10 | 0 |
| **Heavy** | 6,192 | 12 | 8,000 / 1,500 | 1.25 | 3 |

### 6.6 Cost per marked page (USD)

**2026 prices**

| Engine | Lean | Base | Heavy | Base in kwacha |
|---|---|---|---|---|
| Concise | $0.0052 | $0.0083 | $0.0263 | K0.17 |
| Stable | $0.0020 | $0.0026 | $0.0067 | K0.05 |
| Key-based | $0.0053 | $0.0085 | $0.0223 | K0.17 |

**2027 prices** (Stable unchanged)

| Engine | Lean | Base | Heavy | Base in kwacha |
|---|---|---|---|---|
| Concise | $0.0104 | $0.0167 | $0.0527 | K0.33 |
| Stable | $0.0020 | $0.0026 | $0.0067 | K0.05 |
| Key-based | $0.0105 | $0.0169 | $0.0445 | K0.34 |

### 6.7 Pages per bundle — full grids

Format: **Base (Heavy–Lean)**. Channel fee 15%. Infra $0.02 per bundle `[ASSUMED]`. Tax columns are the four readings from §3 with **unverified** rates: no revenue tax; a 4% turnover-tax-like placeholder `[BELIEVED]`; 16% VAT contained in the price (=13.8% of it) `[BELIEVED]`; 30% income tax on profit `[BELIEVED]`.

#### 2026 prices

**Concise marking**

| Bundle | A: no revenue tax | A: 4% | A: 16% VAT in price | B: 30% income tax |
|---|---|---|---|---|
| K50 ($2.50) | 102 (32–164) | 90 (28–144) | 61 (19–97) | 38 (12–61) |
| K100 ($5.00) | 207 (65–331) | 183 (58–293) | 124 (39–199) | 78 (25–126) |
| K150 ($7.50) | 312 (98–499) | 276 (87–442) | 188 (59–301) | 119 (37–191) |

**Stable marking**

| Bundle | A: no revenue tax | A: 4% | A: 16% VAT in price | B: 30% income tax |
|---|---|---|---|---|
| K50 | 324 (127–437) | 286 (112–386) | 193 (76–261) | 121 (47–163) |
| K100 | 655 (257–885) | 579 (227–782) | 394 (154–532) | 249 (98–337) |
| K150 | 987 (388–1333) | 873 (343–1179) | 595 (233–803) | 378 (148–510) |

**Key-based marking**

| Bundle | A: no revenue tax | A: 4% | A: 16% VAT in price | B: 30% income tax |
|---|---|---|---|---|
| K50 | 101 (38–162) | 89 (33–143) | 60 (22–97) | 37 (14–60) |
| K100 | 204 (77–329) | 180 (68–291) | 122 (46–197) | 77 (29–125) |
| K150 | 307 (117–495) | 272 (103–438) | 185 (70–298) | 117 (44–189) |

#### 2027 prices (Stable is identical to 2026 — no announced change)

**Concise marking**

| Bundle | A: no revenue tax | A: 4% | A: 16% VAT in price | B: 30% income tax |
|---|---|---|---|---|
| K50 | 51 (16–82) | 45 (14–72) | 30 (9–48) | 19 (6–30) |
| K100 | 103 (32–165) | 91 (29–146) | 62 (19–99) | 39 (12–63) |
| K150 | 156 (49–249) | 138 (43–221) | 94 (29–150) | 59 (18–95) |

**Key-based marking**

| Bundle | A: no revenue tax | A: 4% | A: 16% VAT in price | B: 30% income tax |
|---|---|---|---|---|
| K50 | 50 (19–81) | 44 (16–71) | 30 (11–48) | 18 (7–30) |
| K100 | 102 (38–164) | 90 (34–145) | 61 (23–98) | 38 (14–62) |
| K150 | 153 (58–247) | 136 (51–219) | 92 (35–149) | 58 (22–94) |

#### Sensitivity — channel fee (K100 bundle, Concise, Base, 2026)

| Channel fee | A: no rev. tax | A: 4% | A: 16% VAT | B: 30% income tax |
|---|---|---|---|---|
| 3% (mobile-money aggregator — placeholder `[ASSUMED]`) | 279 | 255 | 196 | 150 |
| 15% (Play) | 207 | 183 | 124 | 78 |
| 30% (Play standard rate) | 117 | 93 | 34 | **0 — fails the rule** |

#### Sensitivity — currency (K100, Concise, Base, 2026, Play 15%, 16% VAT in price)

Costs are in **US dollars**; the bundle is priced in **kwacha**.

| Kwacha per US$ | K100 is worth | Concise pages | Stable pages |
|---|---|---|---|
| K20 | $5.00 | 124 | 394 |
| K22 | $4.55 | 113 | 357 |
| K25 | $4.00 | 99 | 313 |
| K30 | $3.33 | 82 | 260 |

### 6.8 If marking were folded into subscriptions instead (pages per month, Play 15%, Base)

| Tier / engine (2026 prices) | A: no rev. tax | A: 4% | A: 16% VAT | B: 30% income tax |
|---|---|---|---|---|
| Basic K70 — Concise | 140 | 123 | 82 | 50 |
| Basic K70 — Stable | 445 | 392 | 262 | 161 |
| Basic K70 — Key-based | 138 | 122 | 81 | 50 |
| Gold K150 — Concise | 308 | 272 | 184 | 115 |
| Gold K150 — Stable | 975 | 862 | 583 | 366 |
| Gold K150 — Key-based | 304 | 268 | 182 | 114 |

In 2027 the Concise/Key-based rows roughly halve (Basic Concise, 16% VAT case: 41 pages/month). One class of 40 scripts is ~160 pages, so **unlimited AI marking cannot be bundled into K70 or K150.** This is the main argument for metering.

### 6.9 Cost levers, ranked by likely impact (each needs testing against marking accuracy)

1. **Lower the thinking level** for marking (currently the default: medium on 3.6 Flash). Output is ~80% of cost at Base; thinking is the largest single unknown.
2. **Make Stable the default engine.** It is ~3× cheaper per page in 2026 and ~6× cheaper from 2027.
3. **Batch API (50% off)** for non-urgent marking — Home Assignment marking of pupil submissions could run overnight.
4. **Drop bounding boxes** where the teacher doesn't need ticks drawn on the photo (~30 fewer output tokens per question).
5. **Stop re-sending question-paper images with every script** (Concise): up to 10 images × 1,120 tokens per script. Context caching could also help.
6. **Image resolution setting** (`media_resolution` `medium` = 560 tokens) — minor if images are only ~18% of cost, and risks handwriting accuracy.
7. **Reduce retries** (measure the real failure rate first).

---

## 7. Bundle design questions for you

1. **Unit of sale.** We recommend **pages** (the natural cost driver — image and per-question output scale with pages) expressed as **credits**: 1 Stable page = 1 credit; Concise and Key-based ≈ 3 credits (2026), reviewed on 1 Jan 2027 when Concise/Key-based roughly double.
2. **Size on a pessimistic cost.** Price to roughly the 80th-percentile cost (between Base and Heavy), not the average, once measured. A cost overrun on a fixed-price bundle comes straight out of the margin.
3. **Validity & expiry.** How long is a bundle valid? What happens to unused credits? (Deferred-revenue treatment — your call.)
4. **Play semantics.** Bundles would be consumable in-app purchases. Refunds and chargebacks: who bears the AI cost already spent?
5. **Failed pages.** We propose never charging credits for a failed or unparseable result. Confirm.
6. **Free allowance.** Keep a small free monthly allowance (code today: 5 scripts)? It is a cost of acquisition — cap it explicitly.
7. **Who pays for pupil submissions** in Home Assignment — the teacher's bundle or the school's pooled credits?
8. **Fair-use rules** for shared accounts.

---

## 8. Zambian tax and regulatory questions

For each, we need the **actual rule and the number**. Where we hold a belief it is marked; please correct it.

**a) VAT**
- Standard rate — we believe 16% `[BELIEVED]`. Does it apply to selling an app subscription/credits by a Zambian developer to Zambian users? Registration threshold — we believe roughly K800,000 annual turnover `[BELIEVED]`; current figure?
- **Are K70 / K150 / K50 / K100 / K150 VAT-inclusive prices?** (Moves the model materially.)
- **Does Google collect and remit VAT on Play sales in Zambia**, or are we responsible?
- Input VAT / reverse charge on imported services (Google, Firebase).
- Are **schools** exempt or zero-rated for education software? (Affects the Institutional invoice.)

**b) Income tax regime**
- Turnover tax vs corporate income tax vs presumptive — which does a business of our size and legal form fall under? We believe a ~4% turnover tax exists for small turnover and corporate tax is 30% `[BELIEVED]`; thresholds?
- Sole proprietor vs company (**legal form unknown**). Provisional tax dates. Deductibility of Gemini, Firebase and Play fees; treatment of USD-denominated expenses.

**c) Cross-border payments**
- Who is Google's paying entity? **Withholding tax** on payments from a non-resident? Are payouts in USD or ZMW? Bank charges; Bank of Zambia rules on foreign-currency receipts; FX gains and losses.

**d) Google Play in Zambia — a viability question.**
- **Can a Zambian developer receive Play payouts** (is Zambia a supported merchant/payment-profile country)? If not, what is the workaround?
- Which **payment methods can Zambian users actually use on Play** (cards? carrier billing? gift cards)? Is kwacha pricing supported?

**e) Mobile money**
- MTN MoMo / Airtel Money via an aggregator: fees, availability, any **transaction levies or excise**.
- **Google Play policy:** digital goods and subscriptions consumed in a Play-distributed app generally must use Play Billing. Is mobile-money billing allowed for us, or would it breach the payments policy? **We must not assume it is.** This directly affects the channel-fee assumption (3% vs 15%/30%).

**f) Data protection and consumer law**
- **Data Protection Act No. 3 of 2021** `[BELIEVED]`: must we register as a data controller/processor, at what cost? The app processes **pupils' (minors') data**, photos of answer scripts, and sends data to Google/Firebase outside Zambia — consent and cross-border transfer requirements?
- Cyber-security/cyber-crime legislation, ZICTA obligations, consumer-protection rules on refunds and terms.

**g) Business registration and employment**
- PACRA registration, TPIN, licences, NAPSA/other payroll obligations if we ever employ anyone, other levies.

**h) Selling to schools**
- Invoicing rules, purchase orders, **public-school procurement** and payment terms, **withholding tax on payments by large or public payers**. Schools work in **three terms a year** — billing per term, not per month? (The app already carries the Ministry's 2026–2030 term calendar.)

---

## 9. Institutional (Platinum) pricing framework

**Owner's rule** `[OWNER]`: all app functions included; price varies **only** with the number of **teachers** and **learners**; priced **per school**.

**Cost drivers to model (per school, per term)**
- **Per teacher:** their normal Gold-equivalent usage (planning tools are offline/free to run); their own marking (§6); timetable generation (a deterministic engine plus one small AI call to explain conflicts — low cost); cloud backups (storage up to 3.5 GB worst case); School Network storage/reads.
- **Per learner:** pupil accounts; Home Assignment submissions (answer photos stored up to 10 MB each); **AI marking of those submissions** — likely the dominant cost; possibly SMS for sign-in (`[UNKNOWN]`).
- **Per school:** logo, staffroom posts, dashboards — negligible.

**Suggested structure to test** (numbers are yours to set):

`Price per term = Base + a × teachers + b × learners`, with volume bands, a **pooled AI-page allowance** per learner per term, and overage sold as marking bundles.

**Please price these three sizes** (assumptions `[ASSUMED]`, adjust freely):

| Size | Teachers | Learners |
|---|---|---|
| Small | 10 | 300 |
| Medium | 30 | 1,000 |
| Large | 80 | 3,000 |

Open questions: term vs annual prepayment discount; treatment of public vs private schools; minimum contract; what happens to a school's pooled pages at term end.

---

## 10. Measure first — how we replace assumptions with data

The backend currently records nothing about tokens. Before final pricing, and **before 1 Jan 2027**:

1. **Instrument** the marking functions to log, per call: engine, model, page count, question count, attempt number, `promptTokenCount`, `candidatesTokenCount`, `thoughtsTokenCount`, per-modality prompt tokens, and finish reason — optionally keyed by a hashed user id for per-user cost attribution. (Owner's decision; not yet built.)
2. **Calibration run:** ~30 real scripts across subjects × the 3 engines × thinking levels (default / low / minimal) × `media_resolution` (default / medium). Record cost **and** accuracy against the teacher's own marks — a cheaper setting that mis-marks is not a saving.
3. **Re-run** `docs/marking_pricing_model.py` with measured token counts, then size bundles on the pessimistic figure (§7.2).
4. Repeat quarterly, and immediately after any Google price change.

---

## 11. Assumptions register

| # | Assumption | Value used | Tag | If wrong |
|---|---|---|---|---|
| 1 | Kwacha per dollar | K20 | `[OWNER]` | Kwacha weakening shrinks every bundle (§6.7) |
| 2 | Pages per script | 4 | `[ASSUMED]` | Per-page cost includes fixed per-script costs; more pages = cheaper per page |
| 3 | Image tokens per page | 1,120 | `[VERIFIED]` for "Gemini 3 models", `[ASSUMED]` for 3.5/3.6 | Heavy = ~6,192 → costs up to ~3× on input |
| 4 | Thinking tokens per script | 3,000 (Flash), 300 (Lite) | `[ASSUMED]` | **Largest single uncertainty**; Heavy = 8,000 / 1,500 |
| 5 | Output per question | 100 (Concise/Key), 70 (Stable) | `[ASSUMED]` | Scales with question density |
| 6 | Questions per page | 8 | `[ASSUMED]` | MCQ-dense pages have more |
| 7 | Prompt text per call | 3,000 tokens | `[ASSUMED]` | Minor |
| 8 | Retry overhead | 1.10× | `[ASSUMED]` | Measure failure rate |
| 9 | Play fee | 15% | `[BELIEVED]` | 30% can make bundles fail the rule (§6.7) |
| 10 | Tax rates | 0 / 4% / 13.8% / 30% | `[BELIEVED]` | **Moves capacity ~2×** |
| 11 | Infra per bundle | $0.02 | `[ASSUMED]` | Minor for bundles |
| 12 | Infra per subscriber-month | $0.05 | `[ASSUMED]` | Unknown real Firebase spend |
| 13 | Gemini prices | see §6.2 | `[VERIFIED]` | Reprice on Jan 1, 2027 |
| 14 | Other AI features (lesson plans, notes, timetable explanations) | ignored | `[ASSUMED]` | Low-volume text calls; not zero |

---

## 12. Sources and files

**Google documentation read on 2026-09-19**
- Pricing: https://ai.google.dev/gemini-api/docs/pricing
- Thinking defaults and billing: https://ai.google.dev/gemini-api/docs/thinking
- Media resolution token counts: https://ai.google.dev/gemini-api/docs/media-resolution
- Image tokenisation (older tile method): https://ai.google.dev/gemini-api/docs/image-understanding

**In this repository**
- Model script: `docs/marking_pricing_model.py`
- Marking functions: `firebase/functions/src/index.ts` — `gradeMarkingScriptConcise` (model chosen by the `lightweight` flag), `gradeMarkingScript`, `deriveMarkingKeyFromQuestionPaper`; model constants `GEMINI_MODEL` (`gemini-3.6-flash`) and `GEMINI_MODEL_LITE` (`gemini-3.5-flash-lite`)
- Engine selection in the app: `lib/screens/concise_marking_screen.dart` (`MarkingEngine { concise, stable, keyed }`), `lib/services/concise_marking_service.dart`
- Entitlement flags and free quotas: `lib/services/entitlement_service.dart`, `free_tier_entitlement_service.dart`, `marking_entitlement_service.dart`

---

## 13. Re-running the model

```
cd docs
py -3 marking_pricing_model.py
```

All inputs are at the top of the file in the `INPUTS` section, each tagged `[VERIFIED]`, `[OWNER]` or `[ASSUMED]`. To test a tax reading, edit `TAX_CASES`; to test a channel fee, edit the `fee` argument; to test a different price, edit `BUNDLES_USD` / `SUBS_USD`. The script prints markdown tables in the same shape as §6.
