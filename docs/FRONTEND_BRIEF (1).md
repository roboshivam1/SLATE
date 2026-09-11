# SLATE — Frontend Brief

For whoever's building the UI, and for whatever AI assistant you're pairing with.
Full context is in PRD.md / ARCHITECTURE.md / TECH_STACK.md if you want it — this
is the short version.

## Stack — no exceptions

**Jinja2 templates + HTMX. No React, no Vue, no build step, no npm.**
HTMX is one vendored `<script>` tag in `static/`. Every interaction is a form or
a link with `hx-*` attributes that swaps in a server-rendered partial. If you're
reaching for client-side state, you're doing it wrong — the server owns state.

Styling: one hand-written CSS file, one accent colour. No Tailwind, no component
library. Fast to write, fast to change at 2am.

## File layout — work here

```
templates/
├── base.html            # shell: <head>, HTMX script tag, nav
├── upload.html           # page 1
├── study.html             # page 2 — the main screen, extends base
└── partials/
    ├── question.html       # the "explain this" prompt
    ├── diagnosis.html       # ★ the named misconception + evidence quote
    ├── remediation.html     # ★ clip or static card
    ├── retest.html          # follow-up questions
    └── concept_map.html      # ★ mastery-coloured grid

static/
├── slate.css
├── htmx.min.js
└── clips/                # mp4s land here later, ignore for now
```

★ = the three screens that get photographed and put in the pitch deck. Spend
your polish time there, not on the upload page.

## Build against fixtures, don't wait on the backend

Backend is being built in parallel and the endpoints won't be ready for a while.
Don't block on it — build every template against **hardcoded fixture dicts** that
match these shapes, and I'll make the real routes return the same shapes:

```python
concept = {
    "id": 1, "name": "Chain Rule", "mastery": "diagnosed",
    # unseen | shaky | diagnosed | improving | mastered
}

diagnosis = {
    "misconception_name": "Treats the chain rule as multiplication",
    "narration": "You're combining the two derivatives by multiplying them, "
                 "but the chain rule composes them instead.",
    "evidence_span": "so I just multiplied the two derivatives together",
    # ^ this exact substring should appear in — and be highlighted within —
    #   the student's own submitted answer on screen
    "confidence": 0.82,
}

remediation = {
    "kind": "clip",  # or "card"
    "clip_url": "/static/clips/chain_rule_as_product.mp4",  # if kind == clip
    "wrong_model": "Derivatives of composed functions multiply.",
    "correct_model": "The chain rule composes derivatives: multiply by the "
                      "derivative of the outer function evaluated at the inner.",
}

concept_map = [
    {"id": 1, "name": "Chain Rule", "mastery": "diagnosed"},
    {"id": 2, "name": "Product Rule", "mastery": "mastered"},
    {"id": 3, "name": "Implicit Differentiation", "mastery": "unseen"},
]
```

Five mastery states, five colours. Pick them now, keep them consistent everywhere.

## Routes you're building templates for

| Route | Returns | Swaps into |
|---|---|---|
| `GET /` | `upload.html` | full page |
| `POST /upload` | redirect to `/study/{doc}` | — |
| `GET /study/{doc}` | `study.html` (map + current question) | full page |
| `POST /answer` | `partials/diagnosis.html` | question area |
| `GET /remediation/{misconception_id}` | `partials/remediation.html` | below diagnosis |
| `POST /retest` | `partials/retest.html` → then `diagnosis.html` again | question area |

Every `hx-post` should target a specific `<div id="...">`, swap `outerHTML` or
`innerHTML` as fits, and show an `hx-indicator` spinner — remediation can take a
few seconds if it's rendering live, don't let the screen look frozen.

## What actually needs to look good

1. **The diagnosis partial** — the misconception name should read like a real
   diagnosis, not a form validation error. The evidence span quoted from the
   student's own answer, ideally highlighted inline in their submitted text
   (`<mark>`), is the single most persuasive thing on screen.
2. **The concept map** — a CSS grid of coloured cards is completely fine. Don't
   reach for a graph/network library, it's a time sink for no extra credibility.
3. **The remediation area** — needs to handle both a `<video>` clip and a static
   card gracefully, same layout slot, no jump when one swaps for the other.

Everything else (upload page, nav, retest) can be plain and functional.

## Ground rules

- No client-side routing, no fetch() calls you wrote yourself — HTMX handles it.
- No global JS state. If two partials need to agree on something, that's a sign
  it belongs in the URL or a hidden form field, not in JS.
- Don't build auth, don't build multi-document, don't build a settings page.
  Not in scope — see PRD.md §4 if anyone asks why.
- If Manim/CHALKDUST clips aren't ready yet, `remediation.kind` will just be
  `"card"` for everything — build that path first, it's what most of the demo
  runs on anyway.
