# SLATE — Tech Stack

Constraint driving every choice: **14 hours, demoed from a laptop, no deployment.**
Prefer boring. Prefer things already installed. Prefer things already debugged in
CHALKDUST or JARVIS MK3.

---

## Chosen

| Layer | Choice | Why |
|---|---|---|
| Language | Python 3.12 | Stable. **Not 3.14** — Manim 0.21.0 has known incompatibilities there (already hit in CHALKDUST). |
| Web | FastAPI | Already the house framework |
| Templates | Jinja2 | Server-rendered, no build step |
| Interactivity | HTMX (single `<script>` tag, vendored locally) | Partial swaps cover the whole UI. No npm, no bundler, no React. |
| Styling | Hand-written CSS, one file | Faster than fighting a framework at hour 9 |
| DB | SQLite (WAL mode) | One file, zero setup, copyable for backups |
| Validation | Pydantic v2 | Enforces the §3 determinism contract |
| LLM | Anthropic SDK, `claude-sonnet-5` | Note: the SDK no longer accepts `temperature` |
| PDF text | `pypdf` | Good enough; `pdfplumber` only if layout breaks |
| Rendering | CHALKDUST (Manim 0.21.0) via subprocess | Reused as a binary, not a library |
| Video encode | Homebrew `ffmpeg` | Already installed for CHALKDUST |
| Server | `uvicorn --reload` | Nothing more is needed for a laptop demo |
| Config | `.env` via python-dotenv | Same loader as CHALKDUST |

**Stretch:** Groq Whisper for spoken answers — the client code already exists in
JARVIS MK3 and can be lifted nearly verbatim.

---

## Deliberately not used

| Not using | Because |
|---|---|
| React / Next / any JS framework | No build step survives hour 12 |
| Postgres / Docker / Redis | Nothing here needs them; setup cost is pure loss |
| Vector DB, embeddings, chunking | Demo documents fit in context. Stuffing beats retrieval at this scale. |
| Celery / job queue | One subprocess call, and it's off the critical path |
| Auth | Out of scope per PRD §4 |
| Cloud deployment | Demoing on the laptop. Do not spend an hour on a VPS you will not use. |

---

## Layout

```
slate/
├── app.py                  # FastAPI entry, routes only
├── store/                  # schema.sql, db.py
├── llm/                    # client.py, prompts.py, cache.py
├── ingest/                 # pdf.py, concepts.py
├── tutor/                  # questions.py
├── diagnose/               # classifier.py, schemas.py
├── learner/                # state.py
├── remediate/              # resolver.py, chalkdust_bridge.py
├── templates/              # base.html + partials/
├── static/                 # slate.css, htmx.min.js, clips/
├── seeds/                  # demo PDF + pre-warmed cache
└── .env
```

One concern per directory, matching ARCHITECTURE §2. Modules import `store/` and
`llm/`, never each other.

---

## Environment checklist — do this in hour 0, before writing any feature code

Ten minutes here saves two hours at hour 11.

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install fastapi uvicorn jinja2 python-multipart pydantic \
            anthropic pypdf python-dotenv

python -c "import anthropic, pypdf, fastapi; print('deps ok')"
ffmpeg -version | head -1
chalkdust components            # confirm CHALKDUST still runs standalone
```

Then render **one** trivial CHALKDUST clip end to end and play it in a browser
`<video>` tag. If that fails, you learn it now — when the fallback ladder costs
you nothing — rather than at hour 11 when it costs you the demo.

---

## Laptop demo notes

- Serve on `127.0.0.1`; never depend on venue wifi for the app itself.
- Warm `llm_cache` on the rehearsed path so the only network call is optional.
- Pre-render every clip into `static/clips/` before demo time (ROADMAP M6).
- Disable sleep, close everything else, plug in. Manim is CPU-hungry.
- Keep a copy of `slate.db` and `static/clips/` so a bad state is a 5-second restore.
