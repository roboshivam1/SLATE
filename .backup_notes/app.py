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
