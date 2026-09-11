import os
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
from content import narrate as content_narrate

# ---- OPTIONAL video briefing ----------------------------------------
# Isolated: delete content/video.py or set SLATE_VIDEO=0 and everything
# below simply switches off. Nothing else in the app depends on it.
try:
    from content import video as content_video
    VIDEO_ENABLED = content_video.is_available()
except Exception as _e:
    content_video, VIDEO_ENABLED = None, False
    print(f"[video] disabled: {_e}")

app = FastAPI(title="SLATE")
app.mount("/static", StaticFiles(directory="static"), name="static")

# ---- Optional marketing landing page --------------------------------
# Fully self-contained static bundle in static/landing/. It shares NO code,
# CSS or templates with the app, so it cannot break anything.
# Disable with SLATE_LANDING=0, or simply delete static/landing/.
LANDING_DIR = Path("static/landing")
LANDING_ENABLED = (
    os.getenv("SLATE_LANDING", "1").lower() not in ("0", "false", "no")
    and (LANDING_DIR / "loader.html").exists()
)
templates = Jinja2Templates(directory="templates")
templates.env.filters["highlight"] = highlight

if LANDING_ENABLED:
    app.mount("/landing", StaticFiles(directory=str(LANDING_DIR), html=True),
              name="landing")

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
def root(request: Request):
    """Landing page if enabled, otherwise straight into the app."""
    if LANDING_ENABLED:
        return RedirectResponse("/landing/loader.html", status_code=307)
    return RedirectResponse("/start", status_code=307)


@app.get("/start")
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

    return RedirectResponse(f"/doc/{doc_id}", status_code=303)


# ---------------------------------------------------------------- doc home

@app.get("/doc/{doc_id}")
def doc_home(request: Request, doc_id: int):
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    summary = learner_state.summary(doc_id)
    counts = summary["counts"]
    needs_work = counts.get("diagnosed", 0) + counts.get("shaky", 0)
    attempts = db.one(
        "SELECT COUNT(*) AS n FROM attempts a JOIN concepts c ON c.id = a.concept_id "
        "WHERE c.document_id = ?", (doc_id,))["n"]

    # Which stage leads depends on where the learner actually is.
    lead = "diagnose" if (needs_work or attempts) else "learn"

    return templates.TemplateResponse(
        request, "doc_home.html",
        {"doc": doc, "doc_id": doc_id, "summary": summary,
         "concept_map": _map(doc_id), "concept": None,
         "needs_work": needs_work, "attempts": attempts, "lead": lead})


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
        {"doc": doc, "doc_id": doc_id, "summary": learner_state.summary(doc_id),
         "video_enabled": VIDEO_ENABLED})


@app.get("/notes/{doc_id}/body")
def notes_body(request: Request, doc_id: int):
    n, _plan = content_notes.notes_for(doc_id)
    return templates.TemplateResponse(
        request, "partials/notes_body.html", {"notes": n, "doc_id": doc_id})


@app.post("/notes/{doc_id}/audio")
def notes_audio(request: Request, doc_id: int):
    """On demand only — never generated as part of a page load."""
    audio = content_narrate.audio_for(doc_id)
    return templates.TemplateResponse(
        request, "partials/audio_player.html", {"audio": audio, "doc_id": doc_id})


if True:

    @app.post("/notes/{doc_id}/video")
    def notes_video(request: Request, doc_id: int):
        if content_video is None:
            v = {"state": "failed", "error": "content/video.py failed to import."}
        else:
            v = content_video.start(doc_id)
        return templates.TemplateResponse(
            request, "partials/video_player.html", {"v": v, "doc_id": doc_id})

    @app.get("/notes/{doc_id}/video/status")
    def notes_video_status(request: Request, doc_id: int):
        if content_video is None:
            v = {"state": "failed", "error": "content/video.py failed to import."}
        else:
            v = content_video.job_status(doc_id)
        return templates.TemplateResponse(
            request, "partials/video_player.html", {"v": v, "doc_id": doc_id})


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
