# SLATE — 14-Hour Roadmap

**The rule this roadmap is built on:** every milestone ends with a system you
could demo. Nothing is ever half-wired. If the clock stops at hour 7, you present
what exists at hour 7 and it works.

**The seam that makes this possible:** remediation has a working floor (a static
explanation card) from M4 onward. CHALKDUST is a *visual upgrade* to a working
path at M7, never a dependency. Delete the bridge at any point and the app still
runs.

---

## Milestone table

| # | Hours | Milestone | Demoable state at the end |
|---|---|---|---|
| M0 | 0:00–0:45 | Environment + skeleton | Server runs, page loads |
| M1 | 0:45–2:15 | Ingest | Upload a PDF, see extracted concepts + misconceptions |
| M2 | 2:15–3:15 | Ask + capture | System asks you to explain; your answer is stored |
| M3 | 3:15–5:45 | **Diagnosis** | System names your misconception with evidence |
| M4 | 5:45–6:45 | **Remediation v1** | Targeted explanation card appears — **loop closes** |
| M5 | 6:45–8:00 | Learner model | Concept map recolours as you progress |
| M6 | 8:00–8:45 | Retest | Full loop: diagnose → remediate → retest → update |
| M7 | 8:45–11:15 | CHALKDUST bridge | Remediation becomes an animation |
| M8 | 11:15–12:00 | Pre-render + cache warm | Demo path is instant and offline-safe |
| M9 | 12:00–13:00 | Polish | It looks intentional |
| M10 | 13:00–14:00 | Rehearsal + freeze | Rehearsed twice, backed up |

**M4 is the line.** Before it you have components; after it you have a product.
Protect the hours before M4 ruthlessly — no styling, no nice-to-haves, no
refactors.

---

## M0 · Environment + skeleton — 45 min

Run the full checklist in TECH_STACK before writing feature code, including one
trivial CHALKDUST render played in a browser `<video>` tag.

Build: FastAPI app, Jinja base template, HTMX vendored locally, `schema.sql`
applied, one route rendering one page.

**Exit:** `uvicorn app:app --reload` serves a styled-ish page at `127.0.0.1:8000`,
and you have personally watched a Manim clip play in the browser.

> If the CHALKDUST render fails here, do not debug it now. Note it, continue, and
> decide at M7 whether to attempt the bridge at all. The fallback ladder means
> this is a survivable outcome.

---

## M1 · Ingest — 1h 30m

`POST /upload` → pypdf text extraction → **one** LLM call returning concepts,
each with a closed list of 3–5 candidate misconceptions.

The prompt must ask for the classic, well-documented wrong mental models for each
concept — not generic errors. "Students think the chain rule multiplies
derivatives" is usable; "students make calculation errors" is not.

Write results to `concepts` and `misconceptions`. Render a plain list.

**Exit:** upload the seed PDF, see ~6–10 concepts, each with named misconceptions
that a teacher would recognise as real.

> Seed 2–3 documents now and pick the one whose misconceptions are crispest.
> Your demo lives or dies on this list. Budget 15 of these 90 minutes on the
> prompt, it pays back everywhere downstream.

---

## M2 · Ask + capture — 1h

`tutor/` picks the next concept (simple rule: lowest mastery, then order_index)
and asks for a free-response explanation. Textarea, HTMX post, row written to
`attempts`. No judging yet.

**Exit:** you can answer a question and see your answer echoed back, persisted.

---

## M3 · Diagnosis — 2h 30m

The core. Classifier over the closed list, constrained by the Pydantic schema in
ARCHITECTURE §3, with a single repair retry and an `unknown` escape hatch.

Render the diagnosis partial: the misconception name, the one-sentence narration,
and the evidence span quoted from the student's own answer.

**Exit:** give a deliberately wrong answer carrying a classic misconception, and
the system names it correctly and quotes the phrase that gave it away.

> Test with 5–6 deliberately wrong answers per concept. If it misfires on the one
> you plan to use on stage, fix the *prompt*, not the demo answer.

---

## M4 · Remediation v1 — 1h

`remediate/` returns a static explanation card built from `wrong_model` and
`correct_model`, which already exist from M1. No rendering, no CHALKDUST.

**Exit: the loop is closed.** Upload → question → wrong answer → named
misconception → targeted explanation. **You now have a demoable product.**
Take five minutes to acknowledge that and back up the database.

---

## M5 · Learner model — 1h 15m

The state machine from ARCHITECTURE §7, plus the concept map view: nodes coloured
by mastery. A CSS grid of coloured cards is fine — do not reach for a graph
library, it is a time sink and the grid reads just as well on a projector.

**Exit:** answering changes a node's colour on screen. This is the visible proof
that the unit of state is the learner.

---

## M6 · Retest — 45 min

Generate 2–3 items aimed at the diagnosed misconception, route answers back
through `diagnose/`, transition state on success.

**Exit:** the full PRD §3 loop runs end to end, on one concept, without a restart.

---

## M7 · CHALKDUST bridge — 2h 30m

Spec builder + subprocess call + `artifact_status` flag. Start with **one**
misconception and one scene component. Use `CodeWalk` or `BulletReveal` unless
LaTeX is confirmed working.

**Exit:** at least one misconception resolves to a playing animation, and every
other misconception still falls back cleanly to its card.

> **Hard stop at 11:15 regardless of state.** If the bridge is not working, revert
> to M6 and move on. The card path is a perfectly good demo — the *diagnosis* is
> the technical claim, the animation is the flourish. Do not trade the former for
> the latter.

---

## M8 · Pre-render + cache warm — 45 min

Render clips for every misconception on the demo document into `static/clips/`.
Walk the rehearsed path once so every LLM response lands in `llm_cache`.

**Exit:** disconnect the wifi and run the demo path. It completes.

---

## M9 · Polish — 1h

Typography and spacing. One accent colour. The diagnosis card and the concept map
get 80% of this hour — they are the two screens that will be photographed.

Add S2 (highlight the evidence span inside the student's answer) if it fits; it's
~30 minutes and it is the single most persuasive visual detail in the product.

**Exit:** nothing on screen looks like an unstyled form.

---

## M10 · Rehearsal + freeze — 1h

**Feature freeze at 13:00. No exceptions, including yours.**

- Copy `slate.db` and `static/clips/` to a backup directory
- Run the PRD §5 script twice, out loud, timed
- Whoever presents says the NotebookLM line verbatim — rehearse that sentence
- Write down the three questions judges will ask and the answers:
  1. *"How is this different from NotebookLM?"* → PRD §1
  2. *"How do you know the diagnosis is right?"* → evidence span + closed list + it cannot invent a misconception it has no content for
  3. *"Does this scale beyond one document?"* → the misconception taxonomy is per-concept and reusable across sources; the learner model is the durable asset

**Exit:** two clean run-throughs, backed up, everyone knows their part.

---

## Parallel tracks

If you have three or more people, these split cleanly because modules never
import each other:

| Track | Owns | Can start at |
|---|---|---|
| **A — pipeline** | `ingest/`, `llm/`, `diagnose/` prompts | M0 |
| **B — app** | routes, `store/`, `learner/`, `tutor/` | M0 |
| **C — surface** | templates, CSS, then CHALKDUST bridge at M7 | M0 (against fake data) |

Track C should build every template against hardcoded fixture data from hour 1
and never wait on the backend. Agree the dict shapes in the first 15 minutes and
write them down — that contract is the only coordination cost you should pay.

---

## Cut list, in the order things get cut

When you fall behind — and you will — cut in exactly this order. Decide it now,
not at hour 10 when you are tired and attached to things.

1. Spoken answers (S4)
2. Jump-to-source (S3)
3. CHALKDUST bridge (M7) → cards only
4. Retest (M6) → diagnosis and remediation still demo fine
5. Concept map colouring (M5) → a plain list still shows state

**Never cut:** ingest, free-response capture, diagnosis, remediation card.
That is M0–M4, and it is the product.
