#!/usr/bin/env python3
"""
Smart Teacher - AI marking cost & bundle-capacity model.

Companion to docs/PRICING_AND_TAX_BRIEFING.md. Run:  py -3 marking_pricing_model.py
Every input is in the INPUTS section below, tagged with how sure we are:
  [VERIFIED]  read from Google's own documentation on 2026-09-19 (URLs in the briefing)
  [CODE]      read from this app's source code
  [ASSUMED]   our own estimate - REPLACE with measured or real figures
Nothing here has been measured on real marking traffic yet: the app logs NO token
usage today (no usageMetadata is recorded anywhere), so every token count below the
[VERIFIED] prices is an estimate. See the briefing's "Measure first" section.
"""
import math

# ------------------------------------------------------------------ INPUTS
KWACHA_PER_USD = 20.0                       # [OWNER] K70 = $3.50, K50 = $2.50 -> K20/$. Real FX moves.

BUNDLES_USD = {"K50": 2.50, "K100": 5.00, "K150": 7.50}      # [OWNER] proposed marking bundles
SUBS_USD = {"Basic K70": 3.50, "Gold K150": 7.50}            # [OWNER] subscription prices

# Gemini prices, $ per 1M tokens (output INCLUDES thinking tokens) - [VERIFIED]
PRICE = {
    "flash_2026":      {"in": 0.75, "out": 3.75},   # gemini-3.6-flash, through 31 Dec 2026
    "flash_2027":      {"in": 1.50, "out": 7.50},   # gemini-3.6-flash, from 1 Jan 2027
    "flashlite":       {"in": 0.30, "out": 2.50},   # gemini-3.5-flash-lite, no change announced
}

PAGES_PER_SCRIPT = 4            # [ASSUMED] typical answer script; per-page = per-script / this
PROMPT_TEXT_TOKENS = 3000       # [ASSUMED] instructions + marking conventions + subject module text
SCHEME_TOKENS_PER_QUESTION = 40 # [ASSUMED] Key-based only: the marking key text sent with each call
OBS_TOKENS = 220                # [ASSUMED] the 3-8 one-sentence observations
RUBRIC_TOKENS = 150             # [ASSUMED] pure-AI rubric JSON (Concise/Stable only)
WRAPPER_TOKENS = 30

# Per-engine facts: [CODE] model + whether boxes are returned; token sizes [ASSUMED]
ENGINES = {
    #            model        tokens/question out   pure-AI (rubric)   key text   question-paper pages attached
    "Concise":   dict(model="flash",     q_out=100, rubric=True,  key=False),
    "Stable":    dict(model="flashlite", q_out=70,  rubric=True,  key=False),
    "Key-based": dict(model="flash",     q_out=100, rubric=False, key=True),
}

# Cost scenarios. Image tokens/page: 1120 = Gemini 3 default media_resolution [VERIFIED for
# "Gemini 3 models"; NOT confirmed for 3.5/3.6]. 6192 = the older tile method at 3000x4000 px
# (what we assumed before), in case these newer models bill that way instead.
SCENARIOS = {
    #          img/page  questions/page  thinking tokens/script (flash | flashlite)  retry factor  QP pages (Concise)
    "Lean":  dict(img=1120, qpp=6,  think_flash=1000, think_lite=0,    retry=1.05, qp_pages=0),
    "Base":  dict(img=1120, qpp=8,  think_flash=3000, think_lite=300,  retry=1.10, qp_pages=0),
    "Heavy": dict(img=6192, qpp=12, think_flash=8000, think_lite=1500, retry=1.25, qp_pages=3),
}

INFRA_PER_BUNDLE_USD = 0.02     # [ASSUMED] Firestore/Functions/Storage/logging per bundle sold
INFRA_PER_SUB_MONTH_USD = 0.05  # [ASSUMED]

# ------------------------------------------------------------------ COST PER SCRIPT / PAGE
def cost_per_script(engine, scen, year="2026"):
    e, s = ENGINES[engine], SCENARIOS[scen]
    key = "flashlite" if e["model"] == "flashlite" else f"flash_{year}"
    p = PRICE[key]
    questions = s["qpp"] * PAGES_PER_SCRIPT
    qp_tokens = s["qp_pages"] * s["img"] if engine == "Concise" else 0
    tokens_in = (
        PROMPT_TEXT_TOKENS
        + s["img"] * PAGES_PER_SCRIPT
        + qp_tokens
        + (SCHEME_TOKENS_PER_QUESTION * questions if e["key"] else 0)
    )
    thinking = s["think_lite"] if e["model"] == "flashlite" else s["think_flash"]
    tokens_out = (
        e["q_out"] * questions + OBS_TOKENS + (RUBRIC_TOKENS if e["rubric"] else 0) + WRAPPER_TOKENS + thinking
    )
    one_call = tokens_in / 1e6 * p["in"] + tokens_out / 1e6 * p["out"]
    return one_call * s["retry"], tokens_in, tokens_out


def cost_per_page(engine, scen, year="2026"):
    return cost_per_script(engine, scen, year)[0] / PAGES_PER_SCRIPT


# ------------------------------------------------------------------ THE PROFIT RULE
# Owner's rule: for every $10 of ALL costs and obligations INCLUDING taxes, net profit >= $10.
# i.e. net profit >= total costs (incl. taxes)   <=>   Revenue >= 2 x total costs.
# Two readings, because "taxes" can mean different things - the accountant must choose:
#   A) taxes are a share t of the customer's payment (VAT extracted from a VAT-inclusive price,
#      or turnover tax). Costs = channel fee f*R + t*R + AI + infra.   AI <= R(1-2f-2t)/2 - infra
#   B) income tax at rate tau on PROFIT (no revenue-based tax). Net = (1-tau)*profit and costs
#      include that tax. Operating costs K (fee + AI + infra) must satisfy
#      K <= R(1-2tau) / (2(1-tau)).            AI <= R(1-2tau)/(2(1-tau)) - f*R - infra
def ai_budget_A(price, fee, t, infra):
    return price * (1 - 2 * fee - 2 * t) / 2 - infra


def ai_budget_B(price, fee, tau, infra):
    return price * (1 - 2 * tau) / (2 * (1 - tau)) - fee * price - infra


TAX_CASES = [                                   # label, function(price, fee, infra) -> AI budget $
    ("A: no revenue tax",              lambda p, f, i: ai_budget_A(p, f, 0.0, i)),
    ("A: 4% turnover-tax-like",        lambda p, f, i: ai_budget_A(p, f, 0.04, i)),
    ("A: 16% VAT inside price (13.8%)", lambda p, f, i: ai_budget_A(p, f, 0.16 / 1.16, i)),
    ("B: 30% income tax on profit",    lambda p, f, i: ai_budget_B(p, f, 0.30, i)),
]


def pages_fit(budget, cost_page):
    return max(0, int(budget // cost_page)) if budget > 0 else 0


# ------------------------------------------------------------------ OUTPUT (markdown)
def md_row(cells):
    return "| " + " | ".join(str(c) for c in cells) + " |"


def cost_table(year="2026"):
    print(f"\n#### Cost per marked PAGE (USD), {year} Gemini prices\n")
    print(md_row(["Engine", "Lean", "Base", "Heavy", "Base in kwacha"]))
    print(md_row(["---"] * 5))
    for eng in ENGINES:
        vals = [cost_per_page(eng, s, year) for s in SCENARIOS]
        print(md_row([eng] + [f"${v:.4f}" for v in vals] + [f"K{vals[1] * KWACHA_PER_USD:.2f}"]))


def ratios():
    print("\n#### Cascade factors (Base scenario, 2026): cost of one page relative to a CONCISE page\n")
    c = cost_per_page("Concise", "Base")
    for eng in ENGINES:
        r = cost_per_page(eng, "Base") / c
        print(f"- 1 {eng} page costs {r:.2f}x a Concise page  ->  1 Concise page = {1 / r:.2f} {eng} pages")


def bundle_tables(year="2026", fee=0.15):
    print(f"\n#### Pages per bundle, {year} prices, channel fee {fee:.0%}, Base cost scenario "
          f"(range Lean-Heavy in brackets)\n")
    for eng in ENGINES:
        print(f"**{eng} marking**\n")
        print(md_row(["Bundle"] + [name for name, _ in TAX_CASES]))
        print(md_row(["---"] * (1 + len(TAX_CASES))))
        for bname, price in BUNDLES_USD.items():
            row = [f"{bname} (${price:.2f})"]
            for _, fn in TAX_CASES:
                budget = fn(price, fee, INFRA_PER_BUNDLE_USD)
                base, lean, heavy = (pages_fit(budget, cost_per_page(eng, s, year)) for s in ("Base", "Lean", "Heavy"))
                row.append(f"{base} ({heavy}-{lean})")   # Heavy costs most -> fewest pages
            print(md_row(row))
        print()


def cascade_from_concise(fee=0.15):
    print(f"\n#### Cascade: Concise pages per bundle -> equivalent Stable / Key-based pages "
          f"(2026, fee {fee:.0%}, Base, tax case A: 16% VAT inside price)\n")
    print(md_row(["Bundle", "Concise pages", "= Key-based pages", "= Stable pages"]))
    print(md_row(["---"] * 4))
    fn = TAX_CASES[2][1]
    for bname, price in BUNDLES_USD.items():
        budget = fn(price, fee, INFRA_PER_BUNDLE_USD)
        n_c = budget / cost_per_page("Concise", "Base")
        n_k = budget / cost_per_page("Key-based", "Base")
        n_s = budget / cost_per_page("Stable", "Base")
        print(md_row([f"{bname} (${price:.2f})", int(n_c), int(n_k), int(n_s)]))


def channel_sensitivity(year="2026"):
    print("\n#### Sensitivity: K100 bundle, CONCISE pages, Base scenario, by channel fee and tax case\n")
    print(md_row(["Channel fee"] + [n for n, _ in TAX_CASES]))
    print(md_row(["---"] * (1 + len(TAX_CASES))))
    for label, fee in (("3% (mobile-money aggregator, placeholder)", 0.03), ("15% (Play)", 0.15), ("30% (Play, standard rate)", 0.30)):
        row = [label]
        for _, fn in TAX_CASES:
            b = fn(BUNDLES_USD["K100"], fee, INFRA_PER_BUNDLE_USD)
            row.append(pages_fit(b, cost_per_page("Concise", "Base", year)))
        print(md_row(row))


def fx_sensitivity():
    print("\n#### Currency risk: K100 bundle, CONCISE pages, Base, 2026 prices, Play 15%, VAT-inside-price case\n")
    print("Costs are paid in US dollars (Gemini); the bundle is priced in kwacha.\n")
    print(md_row(["Kwacha per US$", "K100 is worth", "Concise pages", "Stable pages"]))
    print(md_row(["---"] * 4))
    fn = TAX_CASES[2][1]
    for fx in (20, 22, 25, 30):
        usd = 100 / fx
        b = fn(usd, 0.15, INFRA_PER_BUNDLE_USD)
        print(md_row([f"K{fx}", f"${usd:.2f}", pages_fit(b, cost_per_page("Concise", "Base")), pages_fit(b, cost_per_page("Stable", "Base"))]))


def subscription_pages(year="2026"):
    print(f"\n#### If marking were bundled into a subscription instead: pages per MONTH ({year}, Play 15%, Base)\n")
    print(md_row(["Tier / engine", "A: no rev. tax", "A: 4%", "A: 16% VAT", "B: 30% income tax"]))
    print(md_row(["---"] * 5))
    for tname, price in SUBS_USD.items():
        for eng in ENGINES:
            row = [f"{tname} - {eng}"]
            for _, fn in TAX_CASES:
                b = fn(price, 0.15, INFRA_PER_SUB_MONTH_USD)
                row.append(pages_fit(b, cost_per_page(eng, "Base", year)))
            print(md_row(row))


if __name__ == "__main__":
    for y in ("2026", "2027"):
        cost_table(y)
    ratios()
    bundle_tables("2026")
    bundle_tables("2027")
    cascade_from_concise()
    channel_sensitivity()
    fx_sensitivity()
    subscription_pages("2026")
    subscription_pages("2027")
    print("\n#### Token detail, one 4-page script, Base scenario, 2026: (input tokens, output incl. thinking)")
    for eng in ENGINES:
        _, tin, tout = cost_per_script(eng, "Base")
        print(f"- {eng}: {tin:,} in / {tout:,} out")
