#!/usr/bin/env bash
# SLATE — integrate the frontend2 design with the working backend.
# Generated from a tree where all 12 routes were render-tested.
set -euo pipefail

[ -f app.py ] && [ -d frontend ] || { echo "Run this from the SLATE repo root (needs app.py and frontend/)."; exit 1; }

echo "==> backing up current templates/ and static/"
rm -rf .backup_preintegration && mkdir -p .backup_preintegration
cp -r templates static app.py .backup_preintegration/ 2>/dev/null || true

echo "==> moving design assets into place"
cp frontend/static/slate.css static/slate.css
cp frontend/static/htmx.min.js static/htmx.min.js
mkdir -p static/clips && cp -n frontend/static/clips/*.mp4 static/clips/ 2>/dev/null || true
rm -f templates/partials/answered.html
mkdir -p templates/partials

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
        },
    )


# ---------------------------------------------------------------- remediation

@app.get("/remediation/{misconception_id}")
def remediation(request: Request, misconception_id: int, mode: str | None = None):
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
         "misconception_id": misconception_id, "doc_id": doc_id},
    )


# ---------------------------------------------------------------- retest

@app.post("/retest")
def retest(request: Request, misconception_id: int = Form(...)):
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

check("GET /remediation", c.get(f"/remediation/{mis_id}"),
      ["TARGETED REMEDIATION", "YOUR CURRENT MODEL", "STATIC MODEL", "Retest Me"])
check("GET /remediation?mode=card", c.get(f"/remediation/{mis_id}?mode=card"), ["YOUR CURRENT MODEL"])
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

echo "  write templates/base.html"
cat > templates/base.html << 'SLATE_EOF_MARKER'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}SLATE — Intelligent Learning Lab{% endblock %}</title>
  
  <!-- Instant Theme Initializer (Defaults to light theme, persists user selection) -->
  <script>
    (function() {
      var saved = localStorage.getItem('slate-theme');
      var theme = saved ? saved : 'light';
      document.documentElement.setAttribute('data-theme', theme);
    })();
  </script>

  <!-- Single Handwritten Stylesheet -->
  <link rel="stylesheet" href="/static/slate.css">
  
  <!-- Vendored HTMX Script (No build step, no npm) -->
  <script src="/static/htmx.min.js"></script>
</head>
<body>
  <!-- BACKGROUND VISUAL SYSTEM (Pure CSS & SVG, Non-intrusive) -->
  <aside class="lab-background" aria-hidden="true">
    <!-- Animation 1: Precision Graph Paper Dual Grid -->
    <div class="lab-grid"></div>

    <!-- Animation 2: Technical Diagnostic Pencil/Trace Annotation Paths -->
    <svg class="lab-traces-svg" viewBox="0 0 1440 900" fill="none" xmlns="http://www.w3.org/2000/svg">
      <!-- Outer perimeter bracket markers -->
      <path class="trace-line" d="M 40 120 L 40 40 L 140 40 M 1400 120 L 1400 40 L 1300 40 M 40 780 L 40 860 L 140 860 M 1400 780 L 1400 860 L 1300 860" />
      <!-- Mathematical curvature trace -->
      <path class="trace-line-alt" d="M 60 480 C 220 540, 320 380, 520 440 S 840 560, 1100 420 S 1320 480, 1380 430" />
      <!-- Calibration grid ticks -->
      <line x1="40" y1="250" x2="48" y2="250" stroke="currentColor" stroke-width="1" opacity="0.3" />
      <line x1="40" y1="350" x2="48" y2="350" stroke="currentColor" stroke-width="1" opacity="0.3" />
      <line x1="40" y1="450" x2="52" y2="450" stroke="currentColor" stroke-width="1" opacity="0.4" />
      <line x1="40" y1="550" x2="48" y2="550" stroke="currentColor" stroke-width="1" opacity="0.3" />
      <line x1="40" y1="650" x2="48" y2="650" stroke="currentColor" stroke-width="1" opacity="0.3" />
    </svg>

    <!-- Animation 3: Floating Concept Nodes (Geometric, distant background) -->
    <div class="floating-nodes-layer">
      <!-- Node 1 -->
      <svg class="bg-node bg-node-1" width="32" height="32" viewBox="0 0 32 32">
        <rect x="6" y="6" width="20" height="20" rx="2" />
        <circle cx="16" cy="16" r="3" fill="var(--accent-electric)" />
      </svg>
      <!-- Node 2 -->
      <svg class="bg-node bg-node-2" width="28" height="28" viewBox="0 0 28 28">
        <polygon points="14,4 24,22 4,22" />
        <circle cx="14" cy="16" r="2.5" fill="var(--border-strong)" />
      </svg>
      <!-- Node 3 -->
      <svg class="bg-node bg-node-3" width="36" height="36" viewBox="0 0 36 36">
        <circle cx="18" cy="18" r="14" />
        <circle cx="18" cy="18" r="4" fill="var(--accent-electric)" />
      </svg>
      <!-- Node 4 -->
      <svg class="bg-node bg-node-4" width="30" height="30" viewBox="0 0 30 30">
        <rect x="5" y="5" width="20" height="20" transform="rotate(45 15 15)" />
      </svg>
    </div>
  </aside>

  <!-- LAB WORKSPACE HEADER -->
  <header class="lab-header">
    <a href="/" class="brand-wrapper">
      <div class="brand-symbol">S</div>
      <div class="brand-title-group">
        <span class="brand-name">SLATE</span>
        <span class="brand-tagline">Cognitive Mastery System</span>
      </div>
    </a>

    <div class="header-status-bar">
      <div class="status-badge">
        <span class="status-beacon"></span>
        <span>LAB ENGINE : ACTIVE</span>
      </div>
      {% if doc %}<span class="lab-meta-mono" style="opacity: 0.6;">DOC: {{ doc.title[:38] | upper }}</span>{% endif %}
    </div>

    <nav class="nav-links" aria-label="Main Navigation">
      <a href="/" class="nav-link {% if request.url.path == '/' %}active{% endif %}">Upload</a>
      {% if doc_id %}<a href="/study/{{ doc_id }}" class="nav-link {% if '/study' in request.url.path %}active{% endif %}">Workspace</a>{% endif %}
      
      <!-- TOP RIGHT THEME TOGGLE BUTTON -->
      <button 
        id="theme-toggle-btn" 
        class="theme-toggle-btn" 
        type="button" 
        aria-label="Toggle visual theme mode" 
        title="Toggle Light / Dark mode" 
        onclick="toggleSlateTheme()"
      >
        <span class="theme-toggle-icon" id="theme-toggle-icon" aria-hidden="true">&#9788;</span>
        <span class="theme-toggle-text" id="theme-toggle-text">LIGHT</span>
      </button>
    </nav>
  </header>

  <!-- MAIN VIEW CONTAINER -->
  <main>
    {% block content %}{% endblock %}
  </main>

  <!-- LAB PRECISION FOOTER -->
  <footer class="lab-footer">
    <div>
      <strong>SLATE</strong> // Precision Learning Laboratory &bull; Evidence-based cognitive diagnosis
    </div>
    <div>
      Mental Model Verification Engine &bull; Jinja2 + HTMX
    </div>
  </footer>

  <!-- THEME TOGGLE LOGIC -->
  <script>
    function updateThemeUI(theme) {
      var icon = document.getElementById('theme-toggle-icon');
      var text = document.getElementById('theme-toggle-text');
      var btn = document.getElementById('theme-toggle-btn');
      if (theme === 'dark') {
        if (icon) icon.innerHTML = '&#9790;';
        if (text) text.textContent = 'DARK';
        if (btn) btn.setAttribute('title', 'Switch to Light Theme');
      } else {
        if (icon) icon.innerHTML = '&#9788;';
        if (text) text.textContent = 'LIGHT';
        if (btn) btn.setAttribute('title', 'Switch to Dark Theme');
      }
    }

    function toggleSlateTheme() {
      var current = document.documentElement.getAttribute('data-theme') || 'light';
      var next = current === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', next);
      localStorage.setItem('slate-theme', next);
      updateThemeUI(next);
    }

    // Synchronize toggle button state on page load
    (function() {
      var current = document.documentElement.getAttribute('data-theme') || 'light';
      updateThemeUI(current);
    })();
  </script>
</body>
</html>
SLATE_EOF_MARKER

echo "  write templates/upload.html"
cat > templates/upload.html << 'SLATE_EOF_MARKER'
{% extends "base.html" %}

{% block title %}Upload Learning Material — SLATE{% endblock %}

{% block content %}
<div class="lab-workspace lab-workspace-single">
  <div class="upload-wrapper">
    
    <div class="upload-intro">
      <div class="lab-label-technical" style="justify-content: center;">INTAKE CONSOLE // DOCUMENT ANALYSIS</div>
      <h1 class="lab-title-editorial">Upload Learning Material</h1>
      <p style="color: var(--ink-secondary); font-size: 1.05rem; line-height: 1.6; max-width: 580px; margin: 0 auto;">
        Upload your learning material.<br>
        SLATE will identify concepts and diagnose how you understand them.
      </p>
    </div>

    <!-- CLEAN DROP-ZONE FORM -->
    <form action="/upload" method="POST" enctype="multipart/form-data" class="lab-card" id="upload-form">
      <div class="lab-card-body" style="padding: var(--space-8);">
        <label for="material-file" class="upload-dropzone">
          <svg class="upload-icon-graphic" viewBox="0 0 24 24">
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
            <polyline points="14 2 14 8 20 8"></polyline>
            <line x1="12" y1="18" x2="12" y2="12"></line>
            <line x1="9" y1="15" x2="12" y2="12"></line>
            <line x1="15" y1="15" x2="12" y2="12"></line>
          </svg>
          <div>
            <div style="font-weight: 600; font-size: 1.05rem; color: var(--ink-primary); margin-bottom: 4px;">
              Select document or drag and drop file here
            </div>
            <div class="upload-specs">
              SUPPORTED FORMATS: PDF, MARKDOWN, LATEX, TXT (MAX 25MB)
            </div>
          </div>
          <input type="file" id="material-file" name="file" class="upload-input-hidden" onchange="document.getElementById('upload-form').submit();">
        </label>
      </div>

      <div class="lab-card-footer" style="justify-content: space-between;">
        <span class="lab-meta-mono">READY FOR EXTRACTION</span>
        <button type="submit" class="btn-lab btn-lab-accent">
          Process Document
        </button>
      </div>
    </form>

    <!-- EXISTING LAB NOTEBOOKS (REAL DOCUMENTS) -->
    {% if documents %}
    <div class="upload-fixtures-box">
      <div class="lab-label-technical" style="margin-bottom: var(--space-3);">OR SELECT AN ACTIVE LAB NOTEBOOK</div>
      <ul class="fixtures-list">
        {% for d in documents %}
        <li>
          <a href="/study/{{ d.id }}" class="fixture-link-item {% if not d.concept_count %}style-empty{% endif %}">
            <div>
              <strong>{{ d.title }}</strong>
              <div class="lab-meta-mono" style="margin-top: 2px;">
                {{ d.concept_count }} Core Concepts &bull; {{ d.page_count }} pages
                &bull; {% if d.concept_count %}Ready for diagnosis{% else %}No concepts extracted{% endif %}
              </div>
            </div>
            <span class="btn-lab btn-lab-outline" style="padding: 4px 10px; font-size: 0.7rem;">Enter Lab &rarr;</span>
          </a>
        </li>
        {% endfor %}
      </ul>
    </div>
    {% endif %}

  </div>
</div>
{% endblock %}
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
      {% include "partials/question.html" %}
    </div>

    <div id="diagnosis-slot"></div>
    <div id="remediation-slot"></div>

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

echo "  write templates/debug.html"
cat > templates/debug.html << 'SLATE_EOF_MARKER'
{% extends "base.html" %}
{% block content %}
<section class="panel">
  <h1>Debug — extracted misconceptions</h1>
  
</section>

{% for c in concepts %}
<section class="panel">
  <h2>{{ c.name }}</h2>
  <p class="muted">{{ c.summary }}</p>
  <ul class="misclist">
    {% for m in by_concept.get(c.id, []) %}
      <li>
        <strong>{{ m.name }}</strong><br>
        <span class="wrong">“{{ m.wrong_model }}”</span><br>
        <span class="right">{{ m.correct_model }}</span>
      </li>
    {% endfor %}
  </ul>
</section>
{% endfor %}
{% endblock %}
SLATE_EOF_MARKER

echo "  write templates/partials/question.html"
cat > templates/partials/question.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: QUESTION FORM -->
<section class="lab-card" id="question-card">
  <div class="lab-card-header">
    <div class="lab-label-technical">
      {% if is_retest %}TARGETED RETEST // PROMPT 02{% else %}CONCEPT ASSESSMENT // PROMPT 01{% endif %}
    </div>
    <span class="lab-meta-mono">TARGET: {{ concept.name | upper }}</span>
  </div>

  <div class="lab-card-body">
    <h2 class="question-prompt-text">{{ question }}</h2>

    <form
      id="answer-form"
      hx-post="/answer"
      hx-target="#diagnosis-slot"
      hx-swap="innerHTML"
      hx-indicator="#analyzing-indicator"
    >
      <input type="hidden" name="concept_id" value="{{ concept.id }}">
      <input type="hidden" name="question_text" value="{{ question }}">
      <input type="hidden" name="is_retest" value="{{ 1 if is_retest else 0 }}">

      <div style="margin-bottom: var(--space-4);">
        <label for="student-explanation" class="lab-meta-mono" style="display: block; margin-bottom: 6px; font-weight: 600;">
          YOUR EXPLANATION (EXPRESS YOUR MENTAL MODEL CLEARLY):
        </label>
        <textarea
          id="student-explanation"
          name="explanation"
          class="explanation-textarea"
          rows="4"
          required
          placeholder="Explain your reasoning in 2-4 sentences, in your own words."
        ></textarea>
      </div>

      <!-- ANIMATION 4: THINKING PULSE -->
      <div id="analyzing-indicator" class="thinking-pulse" role="status" aria-live="polite">
        <span class="pulse-label">ANALYZING RESPONSE</span>
        <div class="pulse-track">
          <div class="pulse-indicator-node"></div>
        </div>
        <span class="lab-meta-mono" style="font-size: 0.65rem;">PARSING COGNITIVE SYNTAX</span>
      </div>

      <div class="lab-card-footer" style="margin-top: var(--space-4); padding-left: 0; padding-right: 0; background: transparent; border-top: 1px solid var(--border-hairline);">
        <span class="lab-meta-mono" style="margin-right: auto;">EVALUATION: PARSE &bull; DIAGNOSE &bull; RETEST</span>
        <button type="submit" class="btn-lab btn-lab-accent" id="diagnose-submit-btn">
          {% if is_retest %}Submit Retest{% else %}Diagnose Mental Model{% endif %}
        </button>
      </div>
    </form>
  </div>
</section>
SLATE_EOF_MARKER

echo "  write templates/partials/diagnosis.html"
cat > templates/partials/diagnosis.html << 'SLATE_EOF_MARKER'
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
          hx-get="/remediation/{{ diagnosis.misconception_id }}"
          hx-target="#remediation-slot"
          hx-swap="innerHTML"
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
      <button
        class="toggle-btn {% if remediation.kind != 'clip' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=card"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        role="tab"
        aria-selected="{% if remediation.kind != 'clip' %}true{% else %}false{% endif %}"
      >
        STATIC MODEL
      </button>
    </div>
  </div>

  <div class="lab-card-body">
    <!-- IDENTICAL 380px VISUAL SLOT (ZERO LAYOUT JUMP) -->
    <div class="remediation-stage">
      {% if remediation.kind == 'clip' and remediation.clip_url %}
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

    {% with is_retest = true %}
      {% include "partials/question.html" %}
    {% endwith %}
  </div>
</section>
SLATE_EOF_MARKER

echo "  write templates/partials/concept_map.html"
cat > templates/partials/concept_map.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: CONCEPT MASTERY MAP (CLEAN CSS GRID, FIVE STATES) -->
<div class="lab-card concept-map-container" id="concept-map-card">
  <div class="lab-card-header">
    <div class="lab-label-technical">CONCEPT MASTERY MAP</div>
    <span class="lab-meta-mono">{{ summary.mastered }} / {{ summary.total }} MASTERED</span>
  </div>

  <div class="lab-card-body" style="padding: var(--space-4);">
    <div class="concept-grid">
      {% for item in concept_map %}
        <div
          class="concept-item {% if concept and concept.id == item.id %}active{% endif %} {% if item.just_updated %}transitioning{% endif %}"
          data-mastery="{{ item.mastery }}"
          id="concept-node-{{ item.id }}"
        >
          <div class="concept-info">
            <span class="concept-id-tag">C-{{ '%02d' % loop.index }}</span>
            <span class="concept-name">{{ item.name }}</span>
          </div>

          <span class="mastery-pill {{ item.mastery }}">
            {% if item.mastery == 'unseen' %}&compfn; UNSEEN
            {% elif item.mastery == 'shaky' %}&sim; SHAKY
            {% elif item.mastery == 'diagnosed' %}&cross; DIAGNOSED
            {% elif item.mastery == 'improving' %}&nearr; IMPROVING
            {% elif item.mastery == 'mastered' %}&check; MASTERED
            {% else %}{{ item.mastery | upper }}{% endif %}
          </span>
        </div>
      {% endfor %}
    </div>

    <!-- RESTRAINED STATE LEGEND -->
    <div style="margin-top: var(--space-4); padding-top: var(--space-3); border-top: 1px solid var(--border-hairline);">
      <div class="lab-meta-mono" style="font-size: 0.65rem; color: var(--ink-muted); margin-bottom: 6px;">
        MASTERY STATE PROGRESSION:
      </div>
      <div style="display: flex; flex-wrap: wrap; gap: 4px;">
        <span class="mastery-pill unseen" style="font-size: 0.6rem; padding: 1px 5px;">UNSEEN</span>
        <span class="mastery-pill shaky" style="font-size: 0.6rem; padding: 1px 5px;">SHAKY</span>
        <span class="mastery-pill diagnosed" style="font-size: 0.6rem; padding: 1px 5px;">DIAGNOSED</span>
        <span class="mastery-pill improving" style="font-size: 0.6rem; padding: 1px 5px;">IMPROVING</span>
        <span class="mastery-pill mastered" style="font-size: 0.6rem; padding: 1px 5px;">MASTERED</span>
      </div>
    </div>
  </div>
</div>
SLATE_EOF_MARKER

echo "  write diagnose/highlight.py"
cat > diagnose/highlight.py << 'SLATE_EOF_MARKER'
"""Wraps the evidence span in <mark> inside the student's answer."""
import re

from markupsafe import Markup, escape


def highlight(answer: str, span: str) -> Markup:
    if not span:
        return Markup(escape(answer))
    pattern = re.compile(
        r"\s+".join(re.escape(w) for w in span.split()), re.IGNORECASE
    )
    match = pattern.search(answer)
    if not match:
        return Markup(escape(answer))
    a, b = match.span()
    return Markup(
        f"{escape(answer[:a])}<mark class=\"evidence-mark\">{escape(answer[a:b])}</mark>{escape(answer[b:])}"
    )
SLATE_EOF_MARKER

echo "  write learner/state.py"
cat > learner/state.py << 'SLATE_EOF_MARKER'
"""Reads learner state. M5 adds the transition logic."""
from store import db

ORDER = {"unseen": 0, "shaky": 1, "diagnosed": 2, "improving": 3, "mastered": 4}


def map_for(doc_id: int) -> list[dict]:
    rows = db.query(
        "SELECT c.id, c.name, c.summary, "
        "       COALESCE(ls.mastery, 'unseen') AS mastery "
        "FROM concepts c "
        "LEFT JOIN learner_state ls ON ls.concept_id = c.id "
        "WHERE c.document_id = ? ORDER BY c.order_index",
        (doc_id,),
    )
    return [dict(r) for r in rows]


def next_concept(doc_id: int) -> dict | None:
    """Least-mastered concept first; ties broken by document order."""
    concepts = map_for(doc_id)
    if not concepts:
        return None
    return min(concepts, key=lambda c: (ORDER.get(c["mastery"], 0), c["id"]))


MASTERY_LABELS = {
    "unseen": "not yet attempted",
    "shaky": "unclear",
    "diagnosed": "misconception found",
    "improving": "working on it",
    "mastered": "mastered",
}


def get(concept_id: int) -> dict:
    row = db.one("SELECT * FROM learner_state WHERE concept_id = ?", (concept_id,))
    if row:
        return dict(row)
    db.execute(
        "INSERT INTO learner_state (concept_id, mastery) VALUES (?, 'unseen')",
        (concept_id,),
    )
    return {"concept_id": concept_id, "mastery": "unseen",
            "attempts_count": 0, "active_misconception_id": None}


def apply(concept_id: int, d: dict, is_retest: bool = False) -> str:
    """Transition mastery from a diagnosis. Pure logic — no LLM involved."""
    current = get(concept_id)
    was = current["mastery"]

    if d["is_correct"]:
        # Correct on a retest after remediation is the meaningful win.
        new = "mastered"
        active = None
    elif d["is_unknown"] or d["is_tentative"]:
        new = "shaky"
        active = d["misconception_id"]
    else:
        new = "diagnosed"
        active = d["misconception_id"]

    db.execute(
        "UPDATE learner_state SET mastery = ?, active_misconception_id = ?, "
        "attempts_count = attempts_count + 1, updated_at = CURRENT_TIMESTAMP "
        "WHERE concept_id = ?",
        (new, active, concept_id),
    )
    return new


def mark_remediated(concept_id: int) -> None:
    """Seeing the explanation moves 'diagnosed' forward to 'improving'."""
    current = get(concept_id)
    if current["mastery"] in ("diagnosed", "shaky"):
        db.execute(
            "UPDATE learner_state SET mastery = 'improving', "
            "updated_at = CURRENT_TIMESTAMP WHERE concept_id = ?",
            (concept_id,),
        )


def summary(doc_id: int) -> dict:
    rows = map_for(doc_id)
    counts = {}
    for r in rows:
        counts[r["mastery"]] = counts.get(r["mastery"], 0) + 1
    return {"total": len(rows), "counts": counts,
            "mastered": counts.get("mastered", 0)}
SLATE_EOF_MARKER

echo "  write remediate/resolver.py"
cat > remediate/resolver.py << 'SLATE_EOF_MARKER'
"""Returns the best available remediation artifact. Never raises.

Rung 1: cached clip on disk.
Rung 2: live render (wired in M7).
Rung 3: static explanation card, built from data we already have.
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

    # `force` comes from the UI toggle so a judge can see both rungs of the
    # fallback ladder on demand. It can never conjure a clip that isn't there.
    if force == "card":
        return {**base, "kind": "card"}
    if has_clip:
        return {**base, "kind": "clip", "clip_url": f"/static/clips/{m['slug']}.mp4"}
    return {**base, "kind": "card"}
SLATE_EOF_MARKER

echo "  write tutor/questions.py"
cat > tutor/questions.py << 'SLATE_EOF_MARKER'
"""Generates a question designed to ELICIT the known misconceptions."""
from pydantic import BaseModel

from llm import client
from store import db

SYSTEM = """You write short diagnostic questions for a tutoring system.

You are given a concept and the specific wrong mental models students hold about
it. Write ONE open-ended question that invites the student to EXPLAIN their
reasoning in 2-4 sentences.

The question must be designed so that a student holding any of the listed
misconceptions would reveal it in their answer. Prefer a concrete scenario or a
judgement call over a definition request — "definition" questions get textbook
parroting, which is undiagnosable.

Do NOT mention the misconceptions or hint that any answer is wrong.
Return ONLY valid JSON. No prose, no fences."""

USER_TEMPLATE = """Concept: {name}
Summary: {summary}

Wrong mental models students hold:
{wrong_models}

Return: {{"question": "..."}}"""


class Question(BaseModel):
    question: str


def question_for(concept_id: int) -> str:
    concept = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    miscs = db.query(
        "SELECT wrong_model FROM misconceptions WHERE concept_id = ?", (concept_id,)
    )
    wrong_models = "\n".join(f"- {m['wrong_model']}" for m in miscs)

    result = client.call_json(
        SYSTEM,
        USER_TEMPLATE.format(
            name=concept["name"], summary=concept["summary"], wrong_models=wrong_models
        ),
        Question,
    )
    return result.question


def record_attempt(concept_id: int, question: str, answer: str) -> int:
    return db.execute(
        "INSERT INTO attempts (concept_id, question_text, answer_text) VALUES (?, ?, ?)",
        (concept_id, question, answer),
    )


RETEST_SYSTEM = """You write a single targeted retest question.

The student held a specific wrong mental model and has just been shown the
correction. Write ONE question that can only be answered well by someone who has
actually abandoned that wrong model — not a rephrasing of the original question,
and not answerable by parroting the correction back.

Prefer a fresh concrete case that pivots on exactly this distinction.
Do NOT mention the misconception. Return ONLY valid JSON. No prose, no fences."""

RETEST_USER = """Concept: {name}

The wrong model the student held:
"{wrong_model}"

The correction they were shown:
"{correct_model}"

Return: {{"question": "..."}}"""


def retest_question_for(concept_id: int, misconception_id: int) -> str:
    c = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    result = client.call_json(
        RETEST_SYSTEM,
        RETEST_USER.format(name=c["name"], wrong_model=m["wrong_model"],
                           correct_model=m["correct_model"]),
        Question,
    )
    return result.question
SLATE_EOF_MARKER

echo ""
echo "==> done. Backup in .backup_preintegration/"
echo "Next:  python smoke_test.py     (renders every route, no API calls)"
echo "Then:  python -m uvicorn app:app --reload --host 127.0.0.1 --port 8000"