# SLATE

**Structured Learning & Adaptive Teaching Engine**

Study tools tell you *what* you got wrong. SLATE names *why you think that way*,
and teaches against that specific belief.

Built for MUJ HackX 4.0 — Edtech PS #7, *AI Native Learning Workspace for Any
Study Material*. Team **Null Pointers** (TEAM161).

---

## The idea

Most feedback corrects the answer. The faulty mental model that produced the
error survives, so the same mistake returns later in a new disguise.

SLATE's unit of state is the **learner**, not the document. It tracks which
misconception you carry, per concept, and everything it shows you follows from
that.

```
upload a PDF
   └─ concepts extracted, each with a closed set of likely misconceptions
       └─ you explain a concept in your own words
           └─ the misconception is named, quoting your own sentence as evidence
               └─ targeted remediation for that belief
                   └─ retest aimed at the same gap
                       └─ mastery state updates
```

Two stages share that loop. **LEARN** writes adaptive notes, audio briefings and
animated video briefings. **DIAGNOSE** runs the misconception cycle. What
DIAGNOSE finds changes what LEARN writes.

## Why it holds up

**The model reasons and narrates; code decides and computes.**

- **Diagnosis is classification, not generation.** The misconception set is
  frozen at ingest. A Pydantic `Literal` rejects anything outside it, so the
  system cannot invent a misconception it has no content for.
- **Every diagnosis is auditable.** The model must quote a verbatim span from
  your answer. Code verifies it really occurs; an unverifiable quote lowers
  confidence and blanks the citation. Below 0.6 the UI says *possible* rather
  than asserting.
- **Notes depth is computed in Python** from mastery state — diagnosed concepts
  expand, mastered ones condense to a line.
- **Generated SVG passes a whitelist validator** (tags, attributes, theme
  colours) with one repair retry, then falls back to text. Malformed markup
  cannot reach the page.
- **Remediation never fails.** It resolves down a ladder: animation → generated
  illustration → text contrast.

## Stack

Python 3.12 · FastAPI · Jinja2 + HTMX (no JS framework, no build step) ·
SQLite (WAL) · Pydantic v2 · Anthropic Claude · Gemini TTS · Manim 0.21 · pypdf

## Running it

```bash
python3.12 -m venv .venv && source .venv/bin/activate
python -m pip install -r requirements.txt

cat > .env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
GEMINI_API_KEY=...
EOF

python -m uvicorn app:app --reload --host 127.0.0.1 --port 8000
```

Open `http://127.0.0.1:8000` and upload a PDF. Extraction takes up to a minute
and runs once per document.

Optional, for animated video briefings:

```bash
python -m pip install "manim==0.21.0"   # needs ffmpeg and ffprobe on PATH
```

## Layout

```
app.py            routes only
store/            SQLite schema and access
llm/              Anthropic client, prompt cache, JSON repair loop
ingest/           PDF → concepts + closed misconception sets
tutor/            question generation, targeted retests
diagnose/         free-response classifier, evidence verification
learner/          mastery state machine
remediate/        the fallback ladder
content/          adaptive notes, audio briefing, video briefing
chalkdust/        vendored animation renderer
templates/        Jinja pages and HTMX partials
static/landing/   standalone marketing page
```

Modules talk to `store/` and `llm/`, never to each other.

## Optional features

Each switches off cleanly without touching anything else:

| Setting | Effect |
|---|---|
| `SLATE_VIDEO=0` | hides the video briefing (or `rm content/video.py`) |
| `SLATE_LANDING=0` | `/` goes straight to the app (or `rm -rf static/landing`) |
| `SLATE_PUBLIC_DEMO=1` | disables uploads, for a public deployment |
| `SLATE_TTS_VOICE=Kore` | Gemini voice for briefings |

## Tests

```bash
python smoke_test.py
```

Renders every route and partial against fixture data with the LLM stubbed out —
no API key needed, no cost. Covers the failure paths too.