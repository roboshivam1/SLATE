# SLATE — Architecture

Companion to PRD.md. This describes how the modules connect, not line-level code.

---

## 1. Shape of the system

A modular monolith. One FastAPI process, one SQLite file, one long-lived
subprocess for rendering. No services, no queue, no containers — 14 hours.

```
                        ┌─────────────────────────────┐
   browser ◄──────────► │  web/      FastAPI + Jinja  │
   (HTMX)               │            + HTMX partials  │
                        └──────────────┬──────────────┘
                                       │
        ┌──────────────┬───────────────┼───────────────┬──────────────┐
        ▼              ▼               ▼               ▼              ▼
  ┌──────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐   ┌──────────┐
  │ ingest/  │   │ tutor/   │   │ diagnose/ │   │ learner/ │   │remediate/│
  │          │   │          │   │           │   │          │   │          │
  │ pdf→text │   │ question │   │ answer →  │   │ mastery  │   │ id → clip│
  │ →concepts│   │ selection│   │misconcep- │   │ state    │   │ or card  │
  │ →miscon- │   │ +retest  │   │ tion_id   │   │ machine  │   │          │
  │  ceptions│   │ gen      │   │           │   │          │   │          │
  └────┬─────┘   └────┬─────┘   └─────┬─────┘   └────┬─────┘   └────┬─────┘
       │              │               │              │              │
       └──────────────┴───────┬───────┴──────────────┘              │
                              ▼                                     ▼
                     ┌─────────────────┐                  ┌──────────────────┐
                     │ store/  SQLite  │                  │ chalkdust bridge │
                     │ + llm/  client  │                  │ (subprocess)     │
                     │      + cache    │                  └──────────────────┘
                     └─────────────────┘
```

**Dependency rule:** `web/` may call any module. Modules may call `store/` and
`llm/`. Modules never import each other. This keeps every milestone in ROADMAP
additive — you can bolt on `remediate/` without touching `diagnose/`.

---

## 2. Module responsibilities

| Module | Owns | Does NOT own |
|---|---|---|
| `ingest/` | PDF → text → concepts + closed misconception lists | Anything after upload |
| `tutor/` | Which concept to ask about; generating the prompt and retest items | Judging the answer |
| `diagnose/` | Free-response answer → `misconception_id` + confidence + evidence span | Deciding what to do about it |
| `learner/` | Mastery state transitions; the concept-map view model | Talking to the LLM |
| `remediate/` | `misconception_id` → the best available artifact | Rendering (delegates to bridge) |
| `llm/` | One Anthropic client, one prompt registry, response cache | Domain logic |
| `store/` | SQLite access, schema, migrations | Business rules |

---

## 3. The determinism contract (the important part)

This is the CHALKDUST pattern carried over, and it is the thing worth explaining
to judges:

> **The model reasons and narrates. Code decides and computes.**

Concretely:

- At ingest, the LLM proposes a **closed, finite list** of candidate misconceptions
  per concept. That list is written to the database and frozen.
- At diagnosis time the LLM is a **classifier over that closed list**, not a free
  generator. It returns an ID from a menu, plus a confidence and a verbatim span
  from the student's answer as evidence.
- Every downstream decision — which clip to show, which retest items to serve,
  how mastery moves — is ordinary code reading that ID. No LLM in the loop.

Three things fall out of this for free:

1. **Cacheability.** A finite misconception set means a finite artifact set, which
   means you can pre-render everything before the demo. See §5.
2. **Auditability.** Every diagnosis cites a span of the student's own words. You
   can show *why* the system said what it said — a judge-proof property.
3. **No hallucinated remediation.** The system cannot invent a misconception it
   has no content for. Worst case it returns `unknown` and routes to generic help.

**Schema contract for a diagnosis call** — the LLM must return exactly this,
and a Pydantic model validates it before anything else runs:

```json
{
  "misconception_id": "chain_rule_as_product | ... | unknown",
  "confidence": 0.0,
  "evidence_span": "verbatim substring of the student's answer",
  "narration": "one sentence, plain language, addressed to the student"
}
```

If validation fails, retry once with the validation error appended to the prompt
(the CHALKDUST repair loop). If it fails twice, return `unknown`. Never crash.

---

## 4. Data model

Six tables. Deliberately small.

```sql
documents        (id, title, path, page_count, created_at)

concepts         (id, document_id, name, summary, source_page, order_index)

misconceptions   (id, concept_id, slug, name, description,
                  wrong_model,        -- what the student believes, in one line
                  correct_model,      -- the fix, in one line
                  artifact_status)    -- none | card | clip

attempts         (id, concept_id, question_text, answer_text,
                  misconception_id,   -- nullable; null = answered correctly
                  confidence, evidence_span, created_at)

learner_state    (concept_id PRIMARY KEY, mastery, attempts_count,
                  active_misconception_id, updated_at)
                  -- mastery: unseen | shaky | diagnosed | improving | mastered

llm_cache        (prompt_hash PRIMARY KEY, response_json, created_at)
```

`llm_cache` is not an optimisation, it is demo insurance. Every LLM call goes
through it, keyed on a hash of the full prompt. Once you have rehearsed the demo
path, that path runs with the network unplugged.

---

## 5. Remediation and the fallback ladder

`remediate/` exposes one function. It returns the best artifact available and
**never raises**:

```
get_remediation(misconception_id) ->
    1. cached clip on disk?           -> serve the mp4
    2. renderable and time allows?    -> render, cache, serve   (async, optional)
    3. otherwise                      -> static explanation card
```

The static card is built from `wrong_model` + `correct_model`, which already
exist in the database from ingest. That means **level 3 works from Milestone M2
onward**, long before CHALKDUST is wired in. The animation is a visual upgrade to
a path that already functions, not a dependency.

This is why the roadmap cannot break: remediation has a working floor from the
beginning, and every later milestone raises the ceiling.

### CHALKDUST bridge

Treat CHALKDUST as an external binary. Do not refactor it, do not import it.

```
misconception row
    -> build a scene spec (EquationDerivation / CodeWalk / BulletReveal)
    -> subprocess: chalkdust build --spec spec.json --out clips/<slug>.mp4
    -> record artifact_status = 'clip'
```

The bridge is one file and one subprocess call. If CHALKDUST misbehaves during
the hackathon, delete the bridge and the app still works — that is the point of
the fallback ladder.

**Avoid LaTeX-dependent scenes** unless a TeX install is already working on the
laptop. `CodeWalk` and `BulletReveal` render without it; `EquationDerivation`
may not.

---

## 6. Request flow, end to end

```
POST /upload          → ingest/ → concepts + misconceptions → redirect to /study/{doc}
GET  /study/{doc}     → learner/ → concept map + next question
POST /answer          → diagnose/ → attempt row → learner/ state transition
                      → returns an HTMX partial containing the diagnosis
GET  /remediation/{m} → remediate/ → clip or card partial
POST /retest          → tutor/ → targeted items → diagnose/ → state update
```

Everything after `/upload` is an HTMX partial swap. No page reloads, no client
state, no JavaScript framework.

---

## 7. Mastery state machine

Owned entirely by `learner/`, pure code, no LLM:

```
unseen ──first attempt wrong──> diagnosed ──remediation shown──> improving
   │                                 ▲                              │
   │                                 │                    retest correct
   └──first attempt correct──> mastered <───────────────────────────┘
                                     ▲
              improving + retest wrong ──> diagnosed (same or new misconception)
```

`shaky` is reserved for low-confidence diagnoses (< 0.6): the UI says "I think
you might be confusing X — does that sound right?" rather than asserting it.
Cheap to implement, and it reads as intellectual honesty to judges.
