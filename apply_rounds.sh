#!/usr/bin/env bash
# SLATE: per-round slot scoping. Each question cycle is now self-contained,
# so a retest appends below instead of overwriting the round above it.
set -euo pipefail
[ -f app.py ] || { echo "Run from the SLATE repo root."; exit 1; }
mkdir -p .backup_rounds && cp -r templates app.py smoke_test.py .backup_rounds/ 2>/dev/null || true

echo "  write app.py"
cat > app.py << 'SLATE_EOF_MARKER'
import shutil
from pathlib import Path

from dotenv import load_dotenv
load_dotenv(override=True)

from fastapi import FastAPI, Request, UploadFile, File, Form
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from store import db
from ingest import pdf as pdf_ingest
from ingest import concepts as concept_ingest
from learner import state as learner_state
from tutor import questions as tutor
from diagnose import classifier
from diagnose.highlight import highlight
from remediate import resolver

app = FastAPI(title="SLATE")
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")
templates.env.filters["highlight"] = highlight

UPLOADS = Path("uploads")


@app.on_event("startup")
def startup():
    db.init_db()
    UPLOADS.mkdir(exist_ok=True)


def _map(doc_id: int, updated_id: int | None = None):
    """Concept map rows plus the `just_updated` flag the UI animates on."""
    rows = learner_state.map_for(doc_id)
    for r in rows:
        r["just_updated"] = (r["id"] == updated_id)
    return rows


# ---------------------------------------------------------------- upload

@app.get("/")
def home(request: Request):
    docs = db.query(
        "SELECT d.*, (SELECT COUNT(*) FROM concepts c WHERE c.document_id = d.id) "
        "AS concept_count FROM documents d ORDER BY d.id DESC"
    )
    return templates.TemplateResponse(request, "upload.html", {"documents": docs})


@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    dest = UPLOADS / file.filename
    with dest.open("wb") as f:
        shutil.copyfileobj(file.file, f)

    doc_id = db.execute(
        "INSERT INTO documents (title, path) VALUES (?, ?)", (file.filename, str(dest))
    )

    text, page_count = pdf_ingest.extract(str(dest))
    db.execute("UPDATE documents SET page_count = ? WHERE id = ?", (page_count, doc_id))
    try:
        concept_ingest.ingest_document(doc_id, text)
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[ingest] FAILED doc {doc_id}: {type(e).__name__}: {e}")

    return RedirectResponse(f"/study/{doc_id}", status_code=303)


# ---------------------------------------------------------------- study

@app.get("/study/{doc_id}")
def study(request: Request, doc_id: int):
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    current = learner_state.next_concept(doc_id)
    question = tutor.question_for(current["id"]) if current else None

    return templates.TemplateResponse(
        request,
        "study.html",
        {
            "doc": doc,
            "concept": current,
            "question": question,
            "concept_map": _map(doc_id),
            "summary": learner_state.summary(doc_id),
            "doc_id": doc_id,
        },
    )


# ---------------------------------------------------------------- answer

@app.post("/answer")
def answer(
    request: Request,
    concept_id: int = Form(...),
    question_text: str = Form(...),
    explanation: str = Form(...),
    is_retest: int = Form(0),
    round: int = Form(0),
):
    d = classifier.diagnose(concept_id, question_text, explanation)
    learner_state.apply(concept_id, d, is_retest=bool(is_retest))

    db.execute(
        "INSERT INTO attempts (concept_id, question_text, answer_text, "
        "misconception_id, confidence, evidence_span) VALUES (?, ?, ?, ?, ?, ?)",
        (concept_id, question_text, explanation,
         d["misconception_id"], d["confidence"], d["evidence_span"]),
    )

    concept = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    doc_id = concept["document_id"]

    return templates.TemplateResponse(
        request,
        "partials/diagnosis.html",
        {
            "concept": dict(concept) | {"mastery": learner_state.get(concept_id)["mastery"]},
            "diagnosis": d,
            "question": question_text,
            "highlighted_explanation": highlight(explanation, d["evidence_span"]),
            "concept_map": _map(doc_id, updated_id=concept_id),
            "summary": learner_state.summary(doc_id),
            "doc_id": doc_id,
            "round": round,
        },
    )


# ---------------------------------------------------------------- remediation

@app.get("/remediation/{misconception_id}")
def remediation(request: Request, misconception_id: int,
                mode: str | None = None, round: int = 0):
    r = resolver.get_remediation(misconception_id, force=mode)
    concept, doc_id = None, None

    row = db.one(
        "SELECT c.* FROM concepts c JOIN misconceptions m ON m.concept_id = c.id "
        "WHERE m.id = ?", (misconception_id,)
    )
    if row:
        concept = dict(row)
        doc_id = row["document_id"]
        learner_state.mark_remediated(row["id"])

    return templates.TemplateResponse(
        request,
        "partials/remediation.html",
        {"remediation": r, "concept": concept,
         "misconception_id": misconception_id, "doc_id": doc_id,
         "round": round},
    )


# ---------------------------------------------------------------- retest

@app.post("/retest")
def retest(request: Request, misconception_id: int = Form(...),
           round: int = Form(0)):
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    concept = db.one("SELECT * FROM concepts WHERE id = ?", (m["concept_id"],))
    question = tutor.retest_question_for(m["concept_id"], misconception_id)

    return templates.TemplateResponse(
        request,
        "partials/retest.html",
        {
            "concept": dict(concept) | {"mastery": learner_state.get(concept["id"])["mastery"]},
            "question": question,
            "misconception": m,
            "doc_id": concept["document_id"],
            "round": round,
            "next_round": round + 1,
        },
    )


# ---------------------------------------------------------------- debug

@app.get("/debug/{doc_id}")
def debug(request: Request, doc_id: int):
    concepts = db.query(
        "SELECT * FROM concepts WHERE document_id = ? ORDER BY order_index", (doc_id,))
    misconceptions = db.query(
        "SELECT m.* FROM misconceptions m JOIN concepts c ON c.id = m.concept_id "
        "WHERE c.document_id = ? ORDER BY c.order_index", (doc_id,))
    by_concept = {}
    for m in misconceptions:
        by_concept.setdefault(m["concept_id"], []).append(m)
    return templates.TemplateResponse(
        request, "debug.html", {"concepts": concepts, "by_concept": by_concept})


@app.get("/health")
def health():
    return {"ok": True}
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
r2 = c.post("/retest", data={"misconception_id": mis_id, "round": 0})
check("POST /retest", r2,
      ["TARGETED RETEST", "Submit Retest", 'name="is_retest" value="1"',
       'name="round" value="1"', 'id="diagnosis-slot-1"', 'id="retest-slot-1"',
       'hx-target="#diagnosis-slot-1"'])
assert 'id="diagnosis-slot-0"' not in r2.text, "round 1 must not re-declare round 0 slots"

r3 = c.post("/answer", data={"concept_id": cids[0], "question_text": "Q2?",
                             "explanation": STUDENT, "is_retest": 1, "round": 1})
check("POST /answer [round 1]", r3, ['hx-target="#remediation-slot-1"',
                                     'hx-indicator="#rem-indicator-1"'])
check("GET /remediation [round 1]", c.get(f"/remediation/{mis_id}?round=1"),
      ['hx-target="#retest-slot-1"', 'round=1'])
check("GET /debug", c.get(f"/debug/{doc_id}"), ["Misconception 0-0"])
check("GET /health", c.get("/health"))

print("\nfinal mastery:",
      [(r["name"], r["mastery"]) for r in db.query(
          "SELECT c.name, ls.mastery FROM learner_state ls JOIN concepts c ON c.id=ls.concept_id")])
print("\n" + ("ALL PASS" if not fails else f"{len(fails)} FAILURES"))
sys.exit(1 if fails else 0)
SLATE_EOF_MARKER

echo "  write templates/study.html"
cat > templates/study.html << 'SLATE_EOF_MARKER'
{% extends "base.html" %}

{% block title %}SLATE — Workspace: {{ concept.name if concept else doc.title }}{% endblock %}

{% block content %}
<div class="lab-workspace">
  <!-- MAIN WORKBENCH -->
  <div class="workbench-main">

    {% if concept %}
    <header style="border-bottom: 1px solid var(--border-subtle); padding-bottom: var(--space-4);">
      <div class="lab-label-technical">CURRENT INVESTIGATION</div>
      <div style="display: flex; align-items: baseline; justify-content: space-between; margin-top: 4px; gap: var(--space-4);">
        <h1 class="lab-title-editorial" style="font-size: 2rem;">{{ concept.name }}</h1>
        <span class="mastery-pill {{ concept.mastery }}">
          CURRENT STATE: {{ concept.mastery | upper }}
        </span>
      </div>
      <p style="color: var(--ink-secondary); font-size: 0.95rem; margin-top: 6px;">
        {{ concept.summary }}
      </p>
    </header>

    <div id="question-slot">
      {% with round = 0 %}{% include "partials/question.html" %}{% endwith %}
    </div>

    {% else %}
    <section class="lab-card">
      <div class="lab-card-header">
        <div class="lab-label-technical">EXTRACTION INCOMPLETE</div>
      </div>
      <div class="lab-card-body">
        <h2 class="lab-title-editorial" style="font-size: 1.4rem;">No concepts were extracted from this document.</h2>
        <p style="color: var(--ink-secondary);">
          The source may be a scanned PDF with no text layer. Try another document.
        </p>
        <a href="/" class="btn-lab btn-lab-outline" style="margin-top: var(--space-4);">&larr; Back to intake</a>
      </div>
    </section>
    {% endif %}

  </div>

  <!-- TELEMETRY & CONCEPT MAP RAIL -->
  <aside class="telemetry-rail">

    <div id="concept-map-slot">
      {% include "partials/concept_map.html" %}
    </div>

    <div class="lab-card">
      <div class="lab-card-header">
        <div class="lab-label-technical">SESSION TELEMETRY</div>
        <span class="lab-meta-mono">REAL-TIME</span>
      </div>
      <div class="lab-card-body" style="padding: var(--space-4);">
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Source Document</span>
          <span class="stat-metric">{{ doc.page_count }} pp</span>
        </div>
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Concepts Extracted</span>
          <span class="stat-metric">{{ summary.total }}</span>
        </div>
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Evidence Extraction</span>
          <span class="stat-metric" style="color: var(--accent-electric);">Active</span>
        </div>
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Divergence Threshold</span>
          <span class="stat-metric">&gt; 60% Confidence</span>
        </div>
      </div>
    </div>

    <div class="lab-card" style="background: var(--bg-surface-inset); border: 1px dashed var(--border-graphite);">
      <div class="lab-card-body" style="padding: var(--space-4);">
        <div class="lab-meta-mono" style="font-weight: 700; color: var(--ink-primary); margin-bottom: 6px;">
          THE SLATE COGNITIVE LOOP
        </div>
        <ol style="margin-left: 18px; font-family: var(--font-mono); font-size: 0.7rem; color: var(--ink-secondary); line-height: 1.8;">
          <li>Explain in your own words</li>
          <li>Evidence span extracted</li>
          <li>Misconception diagnosed</li>
          <li>Targeted model reconciliation</li>
          <li>Retest &amp; update mastery</li>
        </ol>
      </div>
    </div>

  </aside>
</div>
{% endblock %}
SLATE_EOF_MARKER

echo "  write templates/partials/question.html"
cat > templates/partials/question.html << 'SLATE_EOF_MARKER'
{% set r = round | default(0) %}
<!-- ===== ROUND {{ r }} : question + its own diagnosis/remediation slots ===== -->
<section class="lab-card" id="question-card-{{ r }}">
  <div class="lab-card-header">
    <div class="lab-label-technical">
      {% if is_retest %}TARGETED RETEST // PROMPT {{ '%02d' % (r + 1) }}
      {% else %}CONCEPT ASSESSMENT // PROMPT {{ '%02d' % (r + 1) }}{% endif %}
    </div>
    <span class="lab-meta-mono">TARGET: {{ concept.name | upper }}</span>
  </div>

  <div class="lab-card-body">
    <h2 class="question-prompt-text">{{ question }}</h2>

    <form
      id="answer-form-{{ r }}"
      hx-post="/answer"
      hx-target="#diagnosis-slot-{{ r }}"
      hx-swap="innerHTML"
      hx-indicator="#analyzing-indicator-{{ r }}"
    >
      <input type="hidden" name="concept_id" value="{{ concept.id }}">
      <input type="hidden" name="question_text" value="{{ question }}">
      <input type="hidden" name="is_retest" value="{{ 1 if is_retest else 0 }}">
      <input type="hidden" name="round" value="{{ r }}">

      <div style="margin-bottom: var(--space-4);">
        <label for="student-explanation-{{ r }}" class="lab-meta-mono" style="display: block; margin-bottom: 6px; font-weight: 600;">
          YOUR EXPLANATION (EXPRESS YOUR MENTAL MODEL CLEARLY):
        </label>
        <textarea
          id="student-explanation-{{ r }}"
          name="explanation"
          class="explanation-textarea"
          rows="4"
          required
          placeholder="Explain your reasoning in 2-4 sentences, in your own words."
        ></textarea>
      </div>

      <div id="analyzing-indicator-{{ r }}" class="thinking-pulse" role="status" aria-live="polite">
        <span class="pulse-label">ANALYZING RESPONSE</span>
        <div class="pulse-track"><div class="pulse-indicator-node"></div></div>
        <span class="lab-meta-mono" style="font-size: 0.65rem;">PARSING COGNITIVE SYNTAX</span>
      </div>

      <div class="lab-card-footer" style="margin-top: var(--space-4); padding-left: 0; padding-right: 0; background: transparent; border-top: 1px solid var(--border-hairline);">
        <span class="lab-meta-mono" style="margin-right: auto;">EVALUATION: PARSE &bull; DIAGNOSE &bull; RETEST</span>
        <button type="submit" class="btn-lab btn-lab-accent">
          {% if is_retest %}Submit Retest{% else %}Diagnose Mental Model{% endif %}
        </button>
      </div>
    </form>
  </div>
</section>

<!-- Slots belonging to THIS round. Indicators sit outside their swap targets
     so HTMX cannot remove them mid-request. -->
<div id="diagnosis-slot-{{ r }}"></div>

<div id="rem-indicator-{{ r }}" class="slate-loading" role="status" aria-live="polite">
  <span class="pulse-label">BUILDING TARGETED EXPLANATION</span>
  <div class="pulse-track"><div class="pulse-indicator-node"></div></div>
  <span class="lab-meta-mono" style="font-size: 0.65rem;">DRAWING ILLUSTRATION</span>
</div>

<div id="remediation-slot-{{ r }}"></div>

<div id="retest-indicator-{{ r }}" class="slate-loading" role="status" aria-live="polite">
  <span class="pulse-label">COMPOSING TARGETED RETEST</span>
  <div class="pulse-track"><div class="pulse-indicator-node"></div></div>
  <span class="lab-meta-mono" style="font-size: 0.65rem;">AIMING AT DIAGNOSED GAP</span>
</div>

<div id="retest-slot-{{ r }}"></div>
SLATE_EOF_MARKER

echo "  write templates/partials/diagnosis.html"
cat > templates/partials/diagnosis.html << 'SLATE_EOF_MARKER'
{% set r = round | default(0) %}
<!-- PARTIAL: DIAGNOSIS RESULT (HERO MOMENT) -->
<section class="lab-card diagnosis-container" id="diagnosis-card">
  <div class="lab-card-header">
    {% if diagnosis.is_correct %}
      <div class="lab-label-technical" style="color: var(--state-mastered);">
        REASONING VERIFIED // NO DIVERGENCE DETECTED
      </div>
    {% elif diagnosis.is_unknown %}
      <div class="lab-label-technical" style="color: var(--state-shaky);">
        DIVERGENCE PRESENT // OUTSIDE KNOWN MODEL SET
      </div>
    {% elif diagnosis.is_tentative %}
      <div class="lab-label-technical" style="color: var(--state-shaky);">
        PROVISIONAL DIAGNOSIS // LOW CONFIDENCE
      </div>
    {% else %}
      <div class="lab-label-technical" style="color: var(--state-diagnosed);">
        DIAGNOSIS VERIFIED // COGNITIVE DIVERGENCE IDENTIFIED
      </div>
    {% endif %}
    <span class="lab-meta-mono">
      {% if diagnosis.evidence_span %}EVIDENCE ANCHOR // EXACT MATCH{% else %}NO VERBATIM ANCHOR{% endif %}
    </span>
  </div>

  <div class="lab-card-body">
    <!-- STUDENT EVIDENCE BOX -->
    <div class="student-evidence-box">
      <blockquote class="student-quote-text">
        &ldquo;{{ highlighted_explanation }}&rdquo;
      </blockquote>
      {% if diagnosis.evidence_span %}
        <div style="margin-top: 8px; font-family: var(--font-mono); font-size: 0.68rem; color: var(--ink-muted);">
          &uarr; SLATE detected the divergent mental model directly from this phrasing.
        </div>
      {% endif %}
    </div>

    {% if diagnosis.is_correct %}
      <div class="misconception-banner" style="border-color: var(--state-mastered-border); background: var(--state-mastered-bg);">
        <div class="misconception-tag" style="color: var(--state-mastered);">
          <span>&check;</span> SOUND REASONING
        </div>
        <h3 class="misconception-title">No misconception found in this explanation.</h3>
      </div>
    {% elif diagnosis.is_unknown %}
      <div class="misconception-banner" style="border-color: var(--state-shaky-border); background: var(--state-shaky-bg);">
        <div class="misconception-tag" style="color: var(--state-shaky);">
          <span>&sim;</span> UNRECOGNISED PATTERN
        </div>
        <h3 class="misconception-title">Something is off, but it is not a model SLATE holds content for.</h3>
      </div>
    {% else %}
      <div class="misconception-banner">
        <div class="misconception-tag">
          <span>&bull;</span>
          {% if diagnosis.is_tentative %}POSSIBLE MISCONCEPTION{% else %}MISCONCEPTION DETECTED{% endif %}
        </div>
        <h3 class="misconception-title">
          {% if diagnosis.is_tentative %}You may be: {% endif %}{{ diagnosis.misconception_name }}
        </h3>
      </div>
    {% endif %}

    <!-- WHY WE THINK THIS -->
    <div class="diagnosis-reasoning">
      <div class="reasoning-label">WHY WE THINK THIS (OBSERVED COGNITIVE MODEL)</div>
      <p class="reasoning-text">{{ diagnosis.narration }}</p>
    </div>

    <!-- DIAGNOSTIC CONFIDENCE GAUGE -->
    <div class="confidence-gauge-group" style="--confidence-percent: {{ (diagnosis.confidence * 100) | int }}%;">
      <div class="confidence-label">DIAGNOSTIC CONFIDENCE</div>
      <div class="confidence-bar-track" aria-label="Confidence gauge {{ (diagnosis.confidence * 100) | int }}%">
        <div class="confidence-bar-fill"></div>
      </div>
      <div class="confidence-value">{{ (diagnosis.confidence * 100) | int }}%</div>
    </div>

    <!-- RECTIFICATION CALL TO ACTION -->
    <div class="lab-card-footer" style="padding: var(--space-4) 0 0 0; background: transparent; border-top: 1px solid var(--border-hairline);">
      {% if diagnosis.misconception_id %}
        <span class="lab-meta-mono" style="margin-right: auto;">TARGETED INTERVENTION PREPARED</span>
        <button
          class="btn-lab btn-lab-accent"
          hx-get="/remediation/{{ diagnosis.misconception_id }}?round={{ r }}"
          hx-target="#remediation-slot-{{ r }}"
          hx-swap="innerHTML show:top"
          hx-indicator="#rem-indicator-{{ r }}"
        >
          See Targeted Explanation &rarr;
        </button>
      {% else %}
        <span class="lab-meta-mono" style="margin-right: auto;">NO INTERVENTION REQUIRED</span>
        <a href="/study/{{ doc_id }}" class="btn-lab btn-lab-outline">Next Concept &rarr;</a>
      {% endif %}
    </div>
  </div>
</section>

<!-- OUT-OF-BAND: repaint the concept map without a page reload -->
<div id="concept-map-slot" hx-swap-oob="true">
  {% include "partials/concept_map.html" %}
</div>
SLATE_EOF_MARKER

echo "  write templates/partials/remediation.html"
cat > templates/partials/remediation.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: REMEDIATION (DUAL-MODE WITH IDENTICAL ZERO-SHIFT STAGE) -->
{% set r = round | default(0) %}
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
        hx-get="/remediation/{{ misconception_id }}?mode=clip&round={{ r }}"
        hx-target="#remediation-slot-{{ r }}"
        hx-swap="innerHTML"
        hx-indicator="#rem-indicator-{{ r }}"
        role="tab"
        aria-selected="{% if remediation.kind == 'clip' %}true{% else %}false{% endif %}"
      >
        VIDEO CLIP
      </button>
      {% endif %}
      {% if remediation.has_svg %}
      <button
        class="toggle-btn {% if remediation.kind == 'svg' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=svg&round={{ r }}"
        hx-target="#remediation-slot-{{ r }}"
        hx-swap="innerHTML"
        hx-indicator="#rem-indicator-{{ r }}"
        role="tab"
        aria-selected="{% if remediation.kind == 'svg' %}true{% else %}false{% endif %}"
      >
        ILLUSTRATION
      </button>
      {% endif %}
      <button
        class="toggle-btn {% if remediation.kind == 'card' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=card&round={{ r }}"
        hx-target="#remediation-slot-{{ r }}"
        hx-swap="innerHTML"
        hx-indicator="#rem-indicator-{{ r }}"
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
        hx-vals='{"misconception_id": "{{ misconception_id }}", "round": "{{ r }}"}'
        hx-target="#retest-slot-{{ r }}"
        hx-swap="innerHTML show:top"
        hx-indicator="#retest-indicator-{{ r }}"
      >
        Retest Me &rarr;
      </button>
    </div>
  </div>
</section>

{% endif %}
SLATE_EOF_MARKER

echo "  write templates/partials/retest.html"
cat > templates/partials/retest.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: TARGETED RETEST -->
<section class="lab-card retest-card" id="retest-card">
  <div class="lab-card-header">
    <div class="lab-label-technical" style="color: var(--accent-electric);">
      TARGETED RETEST // CONCEPT VERIFICATION
    </div>
    <span class="lab-meta-mono">AIMED AT: {{ misconception.slug | upper }}</span>
  </div>

  <div class="lab-card-body">
    <div class="retest-result-box improving" style="margin-bottom: var(--space-6);">
      <div class="lab-meta-mono" style="color: var(--state-improving); margin-bottom: 4px;">
        &nearr; THIS QUESTION PIVOTS ON THE EXACT GAP DIAGNOSED
      </div>
      <p style="font-size: 0.9rem; line-height: 1.6; color: var(--ink-secondary); margin: 0;">
        Answering this correctly requires that you have actually abandoned the model
        SLATE diagnosed — restating the correction will not pass it.
      </p>
    </div>

    {% with is_retest = true, round = next_round %}
      {% include "partials/question.html" %}
    {% endwith %}
  </div>
</section>
SLATE_EOF_MARKER

echo ""
echo "==> done. python smoke_test.py, then restart uvicorn."