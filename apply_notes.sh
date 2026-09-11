#!/usr/bin/env bash
# SLATE step C: adaptive study notes.
# Depth plan computed in code from learner_state; model writes prose to fill it.
# Cached under state_fingerprint, so notes regenerate when understanding changes.
set -euo pipefail
[ -f app.py ] || { echo "Run from the SLATE repo root."; exit 1; }
mkdir -p .backup_notes && cp -r templates app.py content smoke_test.py .backup_notes/ 2>/dev/null || true
mkdir -p content

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
from content import notes as content_notes

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


# ---------------------------------------------------------------- notes

@app.get("/notes/{doc_id}")
def notes_page(request: Request, doc_id: int):
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    return templates.TemplateResponse(
        request, "notes.html",
        {"doc": doc, "doc_id": doc_id, "summary": learner_state.summary(doc_id)})


@app.get("/notes/{doc_id}/body")
def notes_body(request: Request, doc_id: int):
    n, _plan = content_notes.notes_for(doc_id)
    return templates.TemplateResponse(
        request, "partials/notes_body.html", {"notes": n, "doc_id": doc_id})


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
import content.notes as cn
import json as _json
def fake_notes(doc_id, plan):
    return _json.dumps({"headline": "Keys, and what makes one minimal",
        "focus": "Start with super keys — you were diagnosed there.",
        "sections": [{"concept_name": p["name"],
                      "body": "First para.\n\nSecond para.",
                      "key_points": ["point a", "point b"]} for p in plan]})
cn._generate = fake_notes

check("GET /notes page", c.get(f"/notes/{doc_id}"), ["ADAPTIVE STUDY NOTES", "notes-indicator"])
rb = c.get(f"/notes/{doc_id}/body")
check("GET /notes body", rb, ["WHERE TO FOCUS", "EXPANDED", "CONDENSED" if False else "STANDARD",
                              "COMPUTED IN CODE FROM YOUR MASTERY STATE"])

# depth plan must react to state: concept 0 is 'improving' after earlier steps
plan = cn.build_plan(doc_id)
print("   plan:", [(p["name"][:22], p["mastery"], p["depth"]) for p in plan])
db.execute("UPDATE learner_state SET mastery='diagnosed', active_misconception_id=? WHERE concept_id=?", (mis_id, cids[0]))
db.execute("UPDATE learner_state SET mastery='mastered' WHERE concept_id=?", (cids[1],))
plan2 = cn.build_plan(doc_id)
print("   plan after state change:", [(p["name"][:22], p["mastery"], p["depth"]) for p in plan2])
assert plan2[0]["depth"] == "expanded" and plan2[0]["misconception"]
assert plan2[1]["depth"] == "condensed"

from content import artifacts as _art
fp1 = _art.state_fingerprint(doc_id)
db.execute("UPDATE learner_state SET mastery='shaky' WHERE concept_id=?", (cids[2],))
assert _art.state_fingerprint(doc_id) != fp1, "fingerprint must change with state"
print("   fingerprint changes with mastery state: ok")
check("GET /notes body [regenerated]", c.get(f"/notes/{doc_id}/body"), ["EXPANDED BECAUSE YOU WERE DIAGNOSED"])

check("GET /debug", c.get(f"/debug/{doc_id}"), ["Misconception 0-0"])
check("GET /health", c.get("/health"))

print("\nfinal mastery:",
      [(r["name"], r["mastery"]) for r in db.query(
          "SELECT c.name, ls.mastery FROM learner_state ls JOIN concepts c ON c.id=ls.concept_id")])
print("\n" + ("ALL PASS" if not fails else f"{len(fails)} FAILURES"))
sys.exit(1 if fails else 0)
SLATE_EOF_MARKER

echo "  write content/notes.py"
cat > content/notes.py << 'SLATE_EOF_MARKER'
"""Adaptive study notes.

The personalisation is NOT delegated to the model. Code reads learner_state and
computes a depth plan — which concepts get expanded, which get condensed, and
which misconception must be addressed head-on. The model then writes prose to
fill that plan.

Because the artifact is cached under `state_fingerprint(doc_id)`, the SAME
button produces baseline notes before any quizzing and re-generates
state-shaped notes the moment a diagnosis changes the fingerprint. There is no
separate "personalised mode" to build.
"""
from pydantic import BaseModel, Field

from llm import client
from store import db
from content import artifacts

# mastery -> (depth, why it got that depth)
DEPTH_RULES = {
    "diagnosed": ("expanded", "a misconception was diagnosed here"),
    "shaky":     ("expanded", "your answer here was unclear"),
    "improving": ("standard", "you are mid-correction on this"),
    "unseen":    ("standard", "not yet attempted"),
    "mastered":  ("condensed", "you have already demonstrated this"),
}

DEPTH_BUDGET = {
    "expanded":  "3-4 paragraphs, plus a worked concrete example",
    "standard":  "1-2 paragraphs",
    "condensed": "a single sentence reminder, nothing more",
}


class NoteSection(BaseModel):
    concept_name: str
    body: str = Field(description="plain prose paragraphs separated by blank lines")
    key_points: list[str] = Field(default_factory=list)


class Notes(BaseModel):
    headline: str
    focus: str = Field(description="2-3 sentences on what to prioritise and why")
    sections: list[NoteSection]


SYSTEM = """You write study notes for one specific learner.

You are given an OUTLINE PLAN computed from what this learner currently
understands. The plan fixes the depth of every section. Follow it exactly:

- "expanded"  -> go deep. If a misconception is named, address it head-on and
                 explain why the intuitive-but-wrong reading fails. Include a
                 concrete worked example.
- "standard"  -> a normal explanation.
- "condensed" -> ONE sentence. The learner has proved this already. Do not pad it.

Rules:
- Write to the learner as "you". Never mention "the student".
- Plain prose only. No markdown syntax, no asterisks, no headings inside body
  text — the page supplies its own structure. Separate paragraphs with a blank line.
- key_points: 0 items for condensed sections, 2-4 for the rest.
- `focus` should name what to work on first and why, referencing what they got
  wrong. If nothing has been attempted yet, say so plainly and suggest a start.
- Cover the concepts in the order given.

Return ONLY valid JSON. No prose outside the JSON, no fences."""

USER_TEMPLATE = """Document: {title}

Outline plan (depth is fixed — follow it):
{plan}

Return:
{{"headline": "...", "focus": "...", "sections": [
  {{"concept_name": "...", "body": "...", "key_points": ["..."]}}
]}}"""


def build_plan(doc_id: int) -> list[dict]:
    """Pure code. Mastery state -> per-concept depth. No LLM involved."""
    rows = db.query(
        "SELECT c.id, c.name, c.summary, "
        "       COALESCE(ls.mastery,'unseen') AS mastery, "
        "       ls.active_misconception_id "
        "FROM concepts c LEFT JOIN learner_state ls ON ls.concept_id = c.id "
        "WHERE c.document_id = ? ORDER BY c.order_index",
        (doc_id,),
    )
    plan = []
    for r in rows:
        depth, reason = DEPTH_RULES.get(r["mastery"], ("standard", ""))
        entry = {
            "concept_id": r["id"],
            "name": r["name"],
            "summary": r["summary"],
            "mastery": r["mastery"],
            "depth": depth,
            "reason": reason,
            "misconception": None,
        }
        if r["active_misconception_id"]:
            m = db.one("SELECT name, wrong_model, correct_model FROM misconceptions "
                       "WHERE id = ?", (r["active_misconception_id"],))
            if m:
                entry["misconception"] = dict(m)
        plan.append(entry)
    return plan


def _plan_text(plan: list[dict]) -> str:
    out = []
    for p in plan:
        block = (f'- Concept: "{p["name"]}"\n'
                 f'  Depth: {p["depth"]} ({DEPTH_BUDGET[p["depth"]]})\n'
                 f'  Learner state: {p["mastery"]} — {p["reason"]}\n'
                 f'  Source summary: {p["summary"]}')
        if p["misconception"]:
            m = p["misconception"]
            block += (f'\n  MUST ADDRESS this diagnosed misconception: {m["name"]}\n'
                      f'    they believe: "{m["wrong_model"]}"\n'
                      f'    the truth is: "{m["correct_model"]}"')
        out.append(block)
    return "\n\n".join(out)


def _generate(doc_id: int, plan: list[dict]) -> str:
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    result = client.call_json(
        SYSTEM,
        USER_TEMPLATE.format(title=doc["title"], plan=_plan_text(plan)),
        Notes,
    )
    return result.model_dump_json()


def notes_for(doc_id: int) -> tuple[dict | None, list[dict]]:
    """Returns (notes_dict, plan). Notes may be None if generation failed."""
    plan = build_plan(doc_id)
    if not plan:
        return None, []

    fp = artifacts.state_fingerprint(doc_id)
    art = artifacts.get_or_create(
        "notes", "document", doc_id,
        generator=lambda: (_generate(doc_id, plan), None),
        fingerprint=fp,
    )
    if not art:
        return None, plan

    parsed = Notes.model_validate_json(art["content"]).model_dump()

    # Merge the code-computed plan back in so the page can SHOW why each
    # section is the length it is.
    by_name = {s["concept_name"].strip().lower(): s for s in parsed["sections"]}
    merged = []
    for p in plan:
        s = by_name.get(p["name"].strip().lower())
        merged.append({**p, "body": s["body"] if s else p["summary"],
                       "key_points": s["key_points"] if s else []})
    parsed["sections"] = merged
    return parsed, plan
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
      {% if doc_id %}<a href="/study/{{ doc_id }}" class="nav-link {% if '/study' in request.url.path %}active{% endif %}">Workspace</a>
      <a href="/notes/{{ doc_id }}" class="nav-link {% if '/notes' in request.url.path %}active{% endif %}">Notes</a>{% endif %}
      
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

    <a href="/notes/{{ doc.id }}" class="btn-lab btn-lab-accent"
       style="width:100%; justify-content:center; margin-bottom: var(--space-4);">
      Study Notes &rarr;
    </a>

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

echo "  write templates/notes.html"
cat > templates/notes.html << 'SLATE_EOF_MARKER'
{% extends "base.html" %}
{% block title %}SLATE — Notes: {{ doc.title }}{% endblock %}

{% block content %}
<div class="lab-workspace lab-workspace-single">
  <div class="notes-wrapper">

    <header style="border-bottom: 1px solid var(--border-subtle); padding-bottom: var(--space-4); margin-bottom: var(--space-6);">
      <div class="lab-label-technical">ADAPTIVE STUDY NOTES // GENERATED FOR YOUR CURRENT UNDERSTANDING</div>
      <div style="display:flex; align-items:baseline; justify-content:space-between; gap:var(--space-4); margin-top:4px;">
        <h1 class="lab-title-editorial" style="font-size: 2rem;">{{ doc.title }}</h1>
        <a href="/study/{{ doc.id }}" class="btn-lab btn-lab-outline">&larr; Back to diagnosis</a>
      </div>
      <p class="lab-meta-mono" style="margin-top:8px; color: var(--ink-muted);">
        MASTERY SNAPSHOT: {{ summary.mastered }} / {{ summary.total }} MASTERED
        &bull; THIS DOCUMENT REGENERATES WHEN YOUR UNDERSTANDING CHANGES
      </p>
    </header>

    <div id="notes-body"
         hx-get="/notes/{{ doc.id }}/body"
         hx-trigger="load"
         hx-swap="innerHTML"
         hx-indicator="#notes-indicator">
    </div>

    <div id="notes-indicator" class="slate-loading" role="status" aria-live="polite">
      <span class="pulse-label">WRITING YOUR NOTES</span>
      <div class="pulse-track"><div class="pulse-indicator-node"></div></div>
      <span class="lab-meta-mono" style="font-size:0.65rem;">WEIGHTED BY WHAT YOU GOT WRONG</span>
    </div>

  </div>
</div>
{% endblock %}
SLATE_EOF_MARKER

echo "  write templates/partials/notes_body.html"
cat > templates/partials/notes_body.html << 'SLATE_EOF_MARKER'
{% if not notes %}
  <section class="lab-card">
    <div class="lab-card-body">
      <h2 class="lab-title-editorial" style="font-size:1.3rem;">Notes could not be generated.</h2>
      <p style="color: var(--ink-secondary);">The concept map for this document may be empty.</p>
    </div>
  </section>
{% else %}

<section class="lab-card" style="margin-bottom: var(--space-6);">
  <div class="lab-card-header">
    <div class="lab-label-technical" style="color: var(--accent-electric);">WHERE TO FOCUS</div>
    <span class="lab-meta-mono">COMPUTED FROM YOUR MASTERY STATE</span>
  </div>
  <div class="lab-card-body">
    <h2 class="lab-title-editorial" style="font-size:1.4rem; margin-bottom: var(--space-3);">
      {{ notes.headline }}
    </h2>
    <p style="font-size:1rem; line-height:1.7; color: var(--ink-secondary);">{{ notes.focus }}</p>
  </div>
</section>

{% for s in notes.sections %}
<section class="lab-card note-section depth-{{ s.depth }}" style="margin-bottom: var(--space-5);">
  <div class="lab-card-header">
    <div class="lab-label-technical">{{ s.name }}</div>
    <div style="display:flex; align-items:center; gap:8px;">
      <span class="note-depth-tag depth-{{ s.depth }}">{{ s.depth | upper }}</span>
      <span class="mastery-pill {{ s.mastery }}">{{ s.mastery | upper }}</span>
    </div>
  </div>
  <div class="lab-card-body">
    {% if s.misconception %}
      <div class="note-misconception">
        <span class="lab-meta-mono" style="color: var(--state-diagnosed);">
          &cross; EXPANDED BECAUSE YOU WERE DIAGNOSED WITH THIS
        </span>
        <div style="margin-top:4px; font-weight:600;">{{ s.misconception.name }}</div>
      </div>
    {% endif %}

    {% for para in s.body.split('\n\n') %}
      {% if para.strip() %}<p class="note-para">{{ para.strip() }}</p>{% endif %}
    {% endfor %}

    {% if s.key_points %}
      <ul class="note-points">
        {% for k in s.key_points %}<li>{{ k }}</li>{% endfor %}
      </ul>
    {% endif %}
  </div>
</section>
{% endfor %}

<div class="lab-card" style="background: var(--bg-surface-inset); border: 1px dashed var(--border-graphite);">
  <div class="lab-card-body" style="padding: var(--space-4);">
    <span class="lab-meta-mono" style="color: var(--ink-muted);">
      SECTION DEPTH IS COMPUTED IN CODE FROM YOUR MASTERY STATE, NOT CHOSEN BY THE MODEL.
      ANSWER MORE QUESTIONS AND THIS DOCUMENT REWRITES ITSELF.
    </span>
  </div>
</div>

{% endif %}
SLATE_EOF_MARKER

echo "  append notes CSS"
cat >> static/slate.css << 'SLATE_EOF_MARKER'

/* ---- Adaptive notes ------------------------------------------------ */
.notes-wrapper { max-width: 780px; margin: 0 auto; width: 100%; }
.note-para { font-size: 1rem; line-height: 1.75; color: var(--ink-secondary);
             margin: 0 0 var(--space-4); }
.note-para:last-of-type { margin-bottom: 0; }
.note-points { margin: var(--space-4) 0 0 18px; padding: 0; }
.note-points li { font-size: 0.94rem; line-height: 1.65; color: var(--ink-primary);
                  margin-bottom: 6px; }
.note-depth-tag {
  font-family: var(--font-mono); font-size: 0.6rem; font-weight: 700;
  letter-spacing: 0.1em; padding: 2px 6px; border-radius: 2px;
  border: 1px solid var(--border-subtle); color: var(--ink-muted);
}
.note-depth-tag.depth-expanded {
  color: var(--state-diagnosed); border-color: var(--state-diagnosed-border);
  background: var(--state-diagnosed-bg);
}
.note-depth-tag.depth-condensed { opacity: 0.6; }
.note-section.depth-expanded { border-left: 3px solid var(--state-diagnosed); }
.note-section.depth-condensed { opacity: 0.82; }
.note-misconception {
  padding: var(--space-3) var(--space-4); margin-bottom: var(--space-4);
  background: var(--state-diagnosed-bg); border: 1px solid var(--state-diagnosed-border);
  border-radius: 2px;
}
SLATE_EOF_MARKER

echo ""
echo "==> done. python smoke_test.py, restart uvicorn, hard-refresh browser."