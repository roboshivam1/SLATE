#!/usr/bin/env bash
# SLATE step A+B: artifact store + targeted SVG illustration rung.
# Generated from a tree where all 13 routes render-tested green.
set -euo pipefail
[ -f app.py ] || { echo "Run from the SLATE repo root."; exit 1; }

mkdir -p .backup_AB && cp -r remediate templates store smoke_test.py .backup_AB/ 2>/dev/null || true
mkdir -p content

echo "  write store/schema.sql"
cat > store/schema.sql << 'SLATE_EOF_MARKER'
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS documents (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,
    path        TEXT NOT NULL,
    page_count  INTEGER DEFAULT 0,
    created_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS concepts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id  INTEGER NOT NULL REFERENCES documents(id),
    name         TEXT NOT NULL,
    summary      TEXT,
    source_page  INTEGER,
    order_index  INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS misconceptions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    concept_id      INTEGER NOT NULL REFERENCES concepts(id),
    slug            TEXT NOT NULL,
    name            TEXT NOT NULL,
    description     TEXT,
    wrong_model     TEXT,
    correct_model   TEXT,
    artifact_status TEXT DEFAULT 'none'   -- none | card | clip
);

CREATE TABLE IF NOT EXISTS attempts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    concept_id        INTEGER NOT NULL REFERENCES concepts(id),
    question_text     TEXT,
    answer_text       TEXT,
    misconception_id  INTEGER REFERENCES misconceptions(id),  -- NULL = correct
    confidence        REAL,
    evidence_span     TEXT,
    created_at        TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS learner_state (
    concept_id              INTEGER PRIMARY KEY REFERENCES concepts(id),
    mastery                 TEXT DEFAULT 'unseen',
    attempts_count          INTEGER DEFAULT 0,
    active_misconception_id INTEGER REFERENCES misconceptions(id),
    updated_at              TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS llm_cache (
    prompt_hash   TEXT PRIMARY KEY,
    response_json TEXT NOT NULL,
    created_at    TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_concepts_doc ON concepts(document_id);
CREATE INDEX IF NOT EXISTS idx_misc_concept ON misconceptions(concept_id);
CREATE INDEX IF NOT EXISTS idx_attempts_concept ON attempts(concept_id);

CREATE TABLE IF NOT EXISTS artifacts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    kind              TEXT NOT NULL,     -- notes | svg | audio
    scope             TEXT NOT NULL,     -- document | concept | misconception
    scope_id          INTEGER NOT NULL,
    state_fingerprint TEXT NOT NULL DEFAULT '',
    content           TEXT,
    path              TEXT,
    created_at        TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(kind, scope, scope_id, state_fingerprint)
);
SLATE_EOF_MARKER

echo "  write content/__init__.py"
cat > content/__init__.py << 'SLATE_EOF_MARKER'

SLATE_EOF_MARKER

echo "  write content/artifacts.py"
cat > content/artifacts.py << 'SLATE_EOF_MARKER'
"""Artifact store.

Every generated artifact — notes, illustrations, audio — lands here, keyed by
(kind, scope, scope_id, state_fingerprint).

The fingerprint is what makes personalisation fall out of caching for free:
artifacts that depend on what the learner knows include a hash of the learner's
current mastery state in their key. Before any quizzing that hash is the
all-unseen one, so you get baseline content. After a diagnosis the hash changes,
the cache misses, and the SAME code path regenerates content shaped by what the
student just got wrong. No separate "personalised mode" to build or explain.

Artifacts that don't depend on the learner (a misconception illustration) pass
fingerprint="" and are generated once, forever.
"""
import hashlib
from typing import Callable

from store import db


def state_fingerprint(doc_id: int) -> str:
    """Stable hash of the learner's mastery state across one document."""
    rows = db.query(
        "SELECT c.id, COALESCE(ls.mastery,'unseen') AS m, "
        "       COALESCE(ls.active_misconception_id, 0) AS a "
        "FROM concepts c LEFT JOIN learner_state ls ON ls.concept_id = c.id "
        "WHERE c.document_id = ? ORDER BY c.id",
        (doc_id,),
    )
    blob = "|".join(f"{r['id']}:{r['m']}:{r['a']}" for r in rows)
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def get(kind: str, scope: str, scope_id: int, fingerprint: str = "") -> dict | None:
    row = db.one(
        "SELECT * FROM artifacts WHERE kind=? AND scope=? AND scope_id=? "
        "AND state_fingerprint=?",
        (kind, scope, scope_id, fingerprint),
    )
    return dict(row) if row else None


def put(kind: str, scope: str, scope_id: int, fingerprint: str,
        content: str | None = None, path: str | None = None) -> dict:
    db.execute(
        "INSERT OR REPLACE INTO artifacts "
        "(kind, scope, scope_id, state_fingerprint, content, path) "
        "VALUES (?,?,?,?,?,?)",
        (kind, scope, scope_id, fingerprint, content, path),
    )
    return get(kind, scope, scope_id, fingerprint)


def get_or_create(kind: str, scope: str, scope_id: int,
                  generator: Callable[[], tuple[str | None, str | None]],
                  fingerprint: str = "") -> dict | None:
    """Return the cached artifact, else run `generator` -> (content, path).

    Never raises: a failing generator returns None and callers fall back.
    """
    hit = get(kind, scope, scope_id, fingerprint)
    if hit:
        return hit
    try:
        content, path = generator()
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[artifacts] {kind}/{scope}/{scope_id} generation failed: {e}")
        return None
    if content is None and path is None:
        return None
    return put(kind, scope, scope_id, fingerprint, content, path)


def invalidate(kind: str, scope: str, scope_id: int) -> None:
    db.execute(
        "DELETE FROM artifacts WHERE kind=? AND scope=? AND scope_id=?",
        (kind, scope, scope_id),
    )
SLATE_EOF_MARKER

echo "  write content/illustrate.py"
cat > content/illustrate.py << 'SLATE_EOF_MARKER'
"""Targeted SVG illustrations.

The model proposes SVG; `sanitize()` enforces it. Anything outside the
whitelist — scripts, external references, event handlers, off-theme colours —
is rejected, the model gets one repair attempt, and if that fails the caller
falls back to the text card. Malformed markup can never reach the page.

Colours are restricted to the stylesheet's CSS variables, so illustrations
follow the light/dark theme toggle without us doing anything.
"""
import re
import xml.etree.ElementTree as ET

from llm import client
from store import db
from content import artifacts

SVG_NS = "http://www.w3.org/2000/svg"

ALLOWED_TAGS = {
    "svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon",
    "path", "text", "tspan", "defs", "marker", "title", "desc",
}

ALLOWED_ATTRS = {
    "viewBox", "xmlns", "width", "height", "x", "y", "x1", "y1", "x2", "y2",
    "cx", "cy", "r", "rx", "ry", "d", "points", "transform", "fill", "stroke",
    "stroke-width", "stroke-dasharray", "stroke-linecap", "stroke-linejoin",
    "opacity", "fill-opacity", "stroke-opacity", "font-size", "font-family",
    "font-weight", "text-anchor", "dominant-baseline", "dy", "dx", "id",
    "class", "marker-end", "marker-start", "orient", "refX", "refY",
    "markerWidth", "markerHeight", "letter-spacing",
}

ALLOWED_PAINT = {
    "none", "currentColor", "transparent",
    "var(--ink-primary)", "var(--ink-secondary)", "var(--ink-muted)",
    "var(--accent-electric)", "var(--bg-surface)", "var(--bg-surface-inset)",
    "var(--border-graphite)", "var(--border-subtle)", "var(--border-hairline)",
    "var(--state-diagnosed)", "var(--state-diagnosed-bg)",
    "var(--state-mastered)", "var(--state-mastered-bg)",
    "var(--state-shaky)", "var(--state-improving)",
}

PAINT_ATTRS = {"fill", "stroke"}


class SvgRejected(Exception):
    pass


def sanitize(raw: str) -> str:
    """Validate and normalise model-produced SVG. Raises SvgRejected."""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-z]*\n?", "", raw)
        raw = raw.rsplit("```", 1)[0].strip()

    start = raw.find("<svg")
    if start == -1:
        raise SvgRejected("no <svg> element found")
    raw = raw[start:]

    lowered = raw.lower()
    for bad in ("<script", "<foreignobject", "<image", "<use", "javascript:",
                "xlink:href", "data:text/html", "<iframe", "<style", "@import"):
        if bad in lowered:
            raise SvgRejected(f"forbidden content: {bad}")
    if re.search(r'\son[a-z]+\s*=', raw, re.IGNORECASE):
        raise SvgRejected("event handler attribute present")

    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        raise SvgRejected(f"not well-formed XML: {e}")

    def local(tag: str) -> str:
        return tag.split("}", 1)[1] if "}" in tag else tag

    if local(root.tag) != "svg":
        raise SvgRejected("root element is not <svg>")
    if not root.get("viewBox"):
        raise SvgRejected("missing viewBox attribute")

    for el in root.iter():
        name = local(el.tag)
        if name not in ALLOWED_TAGS:
            raise SvgRejected(f"disallowed element <{name}>")
        for attr, value in list(el.attrib.items()):
            a = local(attr)
            if a not in ALLOWED_ATTRS:
                del el.attrib[attr]
                continue
            if a in PAINT_ATTRS:
                v = value.strip()
                if v not in ALLOWED_PAINT and not v.startswith("url(#"):
                    raise SvgRejected(
                        f'{a}="{v}" is not an allowed theme colour; use one of: '
                        + ", ".join(sorted(ALLOWED_PAINT))
                    )

    # Responsive: drop fixed pixel size, keep the aspect ratio from viewBox.
    root.attrib.pop("width", None)
    root.attrib.pop("height", None)
    root.set("xmlns", SVG_NS)
    root.set("class", "slate-illustration")

    ET.register_namespace("", SVG_NS)
    return ET.tostring(root, encoding="unicode")


SYSTEM = """You draw precise educational diagrams as raw SVG.

You are given a wrong mental model a student holds and the correct model. Draw a
SINGLE diagram, split into two labelled panels side by side, that makes the
difference visible at a glance.

HARD REQUIREMENTS:
- Output ONLY raw SVG markup. No prose, no markdown fences, no explanation.
- Root element <svg> with a viewBox of exactly "0 0 720 360". No width/height.
- Left panel = the student's current (wrong) model. Right panel = the correct model.
- Label the panels. Keep total text under 40 words; this is a diagram, not a slide.
- Use shapes and spatial relationships to carry the meaning: containment,
  arrows, grouping, size. A diagram that only contains text has failed.

ALLOWED ELEMENTS: svg, g, rect, circle, ellipse, line, polyline, polygon, path,
text, tspan, defs, marker, title, desc. Nothing else.

ALLOWED fill/stroke VALUES — using anything else (including hex codes) is a
hard failure:
  none, currentColor,
  var(--ink-primary), var(--ink-secondary), var(--ink-muted),
  var(--accent-electric), var(--bg-surface), var(--bg-surface-inset),
  var(--border-graphite), var(--border-subtle), var(--border-hairline),
  var(--state-diagnosed), var(--state-diagnosed-bg),
  var(--state-mastered), var(--state-mastered-bg),
  var(--state-shaky), var(--state-improving)

Use var(--state-diagnosed) for the wrong panel's accents and
var(--state-mastered) for the correct panel's. Text should be
var(--ink-primary) or var(--ink-secondary). font-size 13-16 for labels."""

USER_TEMPLATE = """Concept: {concept}

The student's wrong mental model:
"{wrong_model}"

The correct model:
"{correct_model}"

Draw the contrast."""


def _generate_svg(concept_name: str, wrong: str, correct: str) -> str:
    user = USER_TEMPLATE.format(
        concept=concept_name, wrong_model=wrong, correct_model=correct
    )
    attempt = user
    last = None
    for _ in range(2):
        raw = client._raw_call(SYSTEM, attempt)
        try:
            return sanitize(raw)
        except SvgRejected as e:
            last = e
            attempt = (
                f"{user}\n\nYour previous SVG was REJECTED by the validator:\n"
                f"{e}\n\nReturn corrected raw SVG only."
            )
    raise SvgRejected(f"rejected twice: {last}")


def illustration_for(misconception_id: int) -> str | None:
    """Cached SVG for one misconception. Returns markup, or None on failure."""
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    if not m:
        return None
    c = db.one("SELECT * FROM concepts WHERE id = ?", (m["concept_id"],))

    art = artifacts.get_or_create(
        "svg", "misconception", misconception_id,
        generator=lambda: (
            _generate_svg(c["name"], m["wrong_model"], m["correct_model"]),
            None,
        ),
    )
    return art["content"] if art else None
SLATE_EOF_MARKER

echo "  write remediate/resolver.py"
cat > remediate/resolver.py << 'SLATE_EOF_MARKER'
"""Returns the best available remediation artifact. Never raises.

The fallback ladder, best first:
  clip  — a rendered Manim animation on disk            (CHALKDUST, later)
  svg   — a targeted, theme-aware illustration          (generated on demand)
  card  — the wrong/right text contrast                 (always available)

Every rung above `card` is an upgrade to a path that already works, so any of
them can fail or be absent and the product still functions.
"""
from pathlib import Path

from store import db

CLIPS = Path("static/clips")


def get_remediation(misconception_id: int, force: str | None = None) -> dict | None:
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    if not m:
        return None

    base = {
        "id": m["id"],
        "name": m["name"],
        "description": m["description"],
        "wrong_model": m["wrong_model"],
        "correct_model": m["correct_model"],
    }

    clip = CLIPS / f"{m['slug']}.mp4"
    has_clip = clip.exists() and clip.stat().st_size > 0
    base["has_clip"] = has_clip
    base["clip_url"] = f"/static/clips/{m['slug']}.mp4" if has_clip else None

    # Is an illustration already cached? (cheap check, no generation)
    from content import artifacts
    cached_svg = artifacts.get("svg", "misconception", misconception_id)
    base["has_svg"] = bool(cached_svg)

    # `force` drives the UI toggle so a judge can be shown each rung on demand.
    # It can never conjure an artifact that does not exist.
    if force == "card":
        return {**base, "kind": "card"}

    if force == "svg" or (force is None and not has_clip):
        svg = cached_svg["content"] if cached_svg else _try_generate(misconception_id)
        if svg:
            return {**base, "kind": "svg", "svg": svg, "has_svg": True}
        return {**base, "kind": "card"}

    if has_clip:
        return {**base, "kind": "clip"}

    return {**base, "kind": "card"}


def _try_generate(misconception_id: int) -> str | None:
    try:
        from content.illustrate import illustration_for
        return illustration_for(misconception_id)
    except Exception as e:
        print(f"[remediate] illustration failed for {misconception_id}: {e}")
        return None
SLATE_EOF_MARKER

echo "  write templates/partials/remediation.html"
cat > templates/partials/remediation.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: REMEDIATION (DUAL-MODE WITH IDENTICAL ZERO-SHIFT STAGE) -->
{% if remediation %}
<section class="lab-card remediation-slot-wrapper" id="remediation-card">
  <div class="lab-card-header">
    <div class="lab-label-technical">
      TARGETED REMEDIATION // MODEL RESTRUCTURING
    </div>
    
    <!-- MODE SWITCHER (ALLOWS SWITCHING BETWEEN VIDEO AND STATIC NOTEBOOK CARD) -->
    <div class="remediation-mode-toggle" role="tablist" aria-label="Remediation Mode">
      {% if remediation.has_clip %}
      <button
        class="toggle-btn {% if remediation.kind == 'clip' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=clip"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        role="tab"
        aria-selected="{% if remediation.kind == 'clip' %}true{% else %}false{% endif %}"
      >
        VIDEO CLIP
      </button>
      {% endif %}
      {% if remediation.has_svg %}
      <button
        class="toggle-btn {% if remediation.kind == 'svg' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=svg"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        role="tab"
        aria-selected="{% if remediation.kind == 'svg' %}true{% else %}false{% endif %}"
      >
        ILLUSTRATION
      </button>
      {% endif %}
      <button
        class="toggle-btn {% if remediation.kind == 'card' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=card"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        role="tab"
        aria-selected="{% if remediation.kind == 'card' %}true{% else %}false{% endif %}"
      >
        TEXT MODEL
      </button>
    </div>
  </div>

  <div class="lab-card-body">
    <!-- IDENTICAL 380px VISUAL SLOT (ZERO LAYOUT JUMP) -->
    <div class="remediation-stage">
      {% if remediation.kind == 'svg' and remediation.svg %}
        <!-- RUNG 2: TARGETED ILLUSTRATION -->
        <figure class="remediation-illustration">
          {{ remediation.svg | safe }}
          <figcaption class="lab-meta-mono">
            GENERATED FOR THIS MISCONCEPTION &bull; NOT A SUMMARY OF THE DOCUMENT
          </figcaption>
        </figure>
      {% elif remediation.kind == 'clip' and remediation.clip_url %}
        <!-- MODE 1: VIDEO CLIP -->
        <video 
          class="remediation-video-player" 
          controls 
          preload="metadata" 
          poster=""
        >
          <source src="{{ remediation.clip_url }}" type="video/mp4">
          Your browser does not support the video tag.
        </video>
      {% else %}
        <!-- MODE 2: STATIC EXPLANATION CARD (ENGINEERING NOTEBOOK ANNOTATION) -->
        <div class="remediation-static-card">
          <!-- CURRENT / WRONG MODEL -->
          <div class="model-column wrong">
            <div class="model-header">
              <span class="model-badge wrong">YOUR CURRENT MODEL</span>
            </div>
            <p class="model-content-text">
              {{ remediation.wrong_model }}
            </p>
            <div class="lab-meta-mono" style="margin-top: var(--space-3); color: var(--state-diagnosed);">
              &cross; Divergent Premise
            </div>
          </div>

          <!-- RECONCILIATION DIVIDER -->
          <div class="model-connector-divider" title="Model reconciliation">
            &rarr;
          </div>

          <!-- TARGET / CORRECT MODEL -->
          <div class="model-column correct">
            <div class="model-header">
              <span class="model-badge correct">THE CORRECT MODEL</span>
            </div>
            <p class="model-content-text">
              {{ remediation.correct_model }}
            </p>
            <div class="lab-meta-mono" style="margin-top: var(--space-3); color: var(--state-mastered);">
              &check; Ground Truth Formulation
            </div>
          </div>
        </div>
      {% endif %}
    </div>

    <!-- ACTION FOOTER: RETEST ME -->
    <div class="lab-card-footer" style="margin-top: var(--space-6); padding: var(--space-4) 0 0 0; background: transparent; border-top: 1px solid var(--border-hairline);">
      <span class="lab-meta-mono" style="margin-right: auto;">STAGE: REMEDIATION DELIVERED &bull; READY TO RETEST</span>
      <button
        class="btn-lab btn-lab-accent"
        hx-post="/retest"
        hx-vals='{"misconception_id": "{{ misconception_id }}"}'
        hx-target="#retest-slot"
        hx-swap="innerHTML"
      >
        Retest Me &rarr;
      </button>
    </div>
  </div>
</section>

{% endif %}

<!-- RETEST CONTAINER MOUNT POINT -->
<div id="retest-slot" style="margin-top: var(--space-6);"></div>
SLATE_EOF_MARKER

echo "  write smoke_test.py"
cat > smoke_test.py << 'SLATE_EOF_MARKER'
"""Renders every route with fixtures. No API calls. Catches Jinja/contract errors."""
import os, sys
os.environ["SLATE_DB"] = "/tmp/smoke.db"
os.environ["ANTHROPIC_API_KEY"] = "sk-ant-fake"
if os.path.exists("/tmp/smoke.db"):
    os.remove("/tmp/smoke.db")

from store import db
db.init_db()

doc_id = db.execute("INSERT INTO documents (title, path, page_count) VALUES (?,?,?)",
                    ("Fundamentals_of_Database_Systems.pdf", "x.pdf", 26))
cids = []
for i, name in enumerate(["Definition of a Database", "DBMS", "Data Abstraction"]):
    cid = db.execute("INSERT INTO concepts (document_id,name,summary,order_index) VALUES (?,?,?,?)",
                     (doc_id, name, f"Summary of {name}.", i))
    cids.append(cid)
    db.execute("INSERT INTO learner_state (concept_id, mastery) VALUES (?,'unseen')", (cid,))
    for j in range(3):
        db.execute("INSERT INTO misconceptions (concept_id,slug,name,description,wrong_model,correct_model,artifact_status)"
                   " VALUES (?,?,?,?,?,?, 'card')",
                   (cid, f"slug_{i}_{j}", f"Misconception {i}-{j}", "desc",
                    "If I just throw facts in a file that counts as a database.",
                    "A database is a logically coherent collection of related data."))

mis_id = db.one("SELECT id FROM misconceptions WHERE concept_id=?", (cids[0],))["id"]

import tutor.questions as tq
import diagnose.classifier as dc
tq.question_for = lambda cid: "A friend keeps a text file of random notes. Is that a database? Why?"
tq.retest_question_for = lambda cid, mid: "A shop keeps a spreadsheet of stock. Database or not? Explain."

STUDENT = "I think any collection of data is a database, so if I just throw facts in a file that counts as a database."

def fake(kind):
    base = {"slug": "slug_0_0", "misconception_id": mis_id,
            "misconception_name": "Misconception 0-0", "confidence": 0.82,
            "evidence_span": "if I just throw facts in a file",
            "narration": "You are treating any pile of data as a database.",
            "is_correct": False, "is_unknown": False, "is_tentative": False}
    if kind == "correct":
        return {**base, "slug": "correct", "misconception_id": None,
                "misconception_name": None, "is_correct": True, "confidence": 0.91}
    if kind == "unknown":
        return {**base, "slug": "unknown", "misconception_id": None,
                "misconception_name": None, "is_unknown": True, "confidence": 0.4}
    if kind == "tentative":
        return {**base, "is_tentative": True, "confidence": 0.45, "evidence_span": ""}
    return base

import app as slate_app
from fastapi.testclient import TestClient
c = TestClient(slate_app.app)

fails = []
def check(label, r, must_contain=()):
    ok = r.status_code == 200
    body = r.text if ok else ""
    missing = [m for m in must_contain if m not in body]
    if not ok or missing:
        fails.append((label, r.status_code, missing))
        print(f"FAIL {label}: status={r.status_code} missing={missing}")
        if not ok:
            print(r.text[:1500])
    else:
        print(f"ok   {label}  ({len(body)} bytes)")

check("GET /", c.get("/"), ["Upload Learning Material", "Fundamentals_of_Database"])
check("GET /study", c.get(f"/study/{doc_id}"),
      ["Definition of a Database", "CONCEPT MASTERY MAP", "question_text", "0 / 3 MASTERED"])

for kind, expect in [("named", "MISCONCEPTION DETECTED"),
                     ("correct", "SOUND REASONING"),
                     ("unknown", "UNRECOGNISED PATTERN"),
                     ("tentative", "POSSIBLE MISCONCEPTION")]:
    dc.diagnose = lambda cid, q, a, k=kind: fake(k)
    r = c.post("/answer", data={"concept_id": cids[0], "question_text": "Q?",
                                "explanation": STUDENT, "is_retest": 0})
    check(f"POST /answer [{kind}]", r, [expect, 'hx-swap-oob="true"'])

dc.diagnose = lambda cid, q, a: fake("named")
r = c.post("/answer", data={"concept_id": cids[0], "question_text": "Q?",
                            "explanation": STUDENT, "is_retest": 0})
check("evidence <mark>", r, ["<mark class=\"evidence-mark\">if I just throw facts in a file</mark>"])

# stub the illustrator so no API call happens
import content.illustrate as ill
FAKE_SVG = ('<svg viewBox="0 0 720 360" xmlns="http://www.w3.org/2000/svg">'
            '<rect x="10" y="10" width="330" height="340" fill="none" '
            'stroke="var(--state-diagnosed)"/>'
            '<text x="20" y="40" fill="var(--ink-primary)">Your model</text></svg>')
ill._generate_svg = lambda *a, **k: ill.sanitize(FAKE_SVG)

check("GET /remediation [svg rung]", c.get(f"/remediation/{mis_id}"),
      ["slate-illustration", "TARGETED REMEDIATION", "ILLUSTRATION"])
check("GET /remediation?mode=svg", c.get(f"/remediation/{mis_id}?mode=svg"),
      ["slate-illustration"])
check("GET /remediation [card]", c.get(f"/remediation/{mis_id}?mode=card"),
      ["YOUR CURRENT MODEL", "TEXT MODEL", "Retest Me"])
check("POST /retest", c.post("/retest", data={"misconception_id": mis_id}),
      ["TARGETED RETEST", "Submit Retest", 'name="is_retest" value="1"'])
check("GET /debug", c.get(f"/debug/{doc_id}"), ["Misconception 0-0"])
check("GET /health", c.get("/health"))

print("\nfinal mastery:",
      [(r["name"], r["mastery"]) for r in db.query(
          "SELECT c.name, ls.mastery FROM learner_state ls JOIN concepts c ON c.id=ls.concept_id")])
print("\n" + ("ALL PASS" if not fails else f"{len(fails)} FAILURES"))
sys.exit(1 if fails else 0)
SLATE_EOF_MARKER

echo "  append illustration CSS"
cat >> static/slate.css << 'SLATE_EOF_MARKER'

/* Targeted illustration rung */
.remediation-illustration { margin: 0; width: 100%; }
.remediation-illustration svg.slate-illustration {
  width: 100%; height: auto; display: block;
  background: var(--bg-surface-inset);
  border: 1px solid var(--border-hairline);
  border-radius: 3px;
}
.remediation-illustration figcaption {
  margin-top: 8px; color: var(--ink-muted); font-size: 0.65rem;
}
SLATE_EOF_MARKER

echo ""
echo "==> done. The artifacts table is created on next startup."
echo "Next:  python smoke_test.py"
echo "Then:  python -m uvicorn app:app --reload --host 127.0.0.1 --port 8000"