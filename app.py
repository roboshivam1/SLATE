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

app = FastAPI(title="SLATE")
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")
templates.env.filters["highlight"] = highlight

UPLOADS = Path("uploads")


@app.on_event("startup")
def startup():
    db.init_db()
    UPLOADS.mkdir(exist_ok=True)


@app.get("/")
def home(request: Request):
    docs = db.query("SELECT * FROM documents ORDER BY id DESC")
    return templates.TemplateResponse(
        request, "upload.html", {"documents": docs}
    )


@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    dest = UPLOADS / file.filename
    with dest.open("wb") as f:
        shutil.copyfileobj(file.file, f)

    doc_id = db.execute(
        "INSERT INTO documents (title, path) VALUES (?, ?)",
        (file.filename, str(dest)),
    )
    text, page_count = pdf_ingest.extract(str(dest))
    db.execute("UPDATE documents SET page_count = ? WHERE id = ?", (page_count, doc_id))
    try:
        concept_ingest.ingest_document(doc_id, text)
    except Exception as e:
        import traceback; traceback.print_exc()
        print(f"[ingest] FAILED doc {doc_id}: {type(e).__name__}: {e}")

    return RedirectResponse(f"/study/{doc_id}", status_code=303)


@app.get("/study/{doc_id}")
def study(request: Request, doc_id: int):
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    concept_map = learner_state.map_for(doc_id)
    current = learner_state.next_concept(doc_id)

    question = tutor.question_for(current["id"]) if current else None

    return templates.TemplateResponse(
        request, "study.html",
        {"doc": doc, "concept_map": concept_map,
         "concept": current, "question": question},
    )


@app.post("/answer")
def answer(request: Request,
           concept_id: int = Form(...),
           question_text: str = Form(...),
           answer_text: str = Form(...)):
    d = classifier.diagnose(concept_id, question_text, answer_text)

    db.execute(
        "INSERT INTO attempts (concept_id, question_text, answer_text, "
        "misconception_id, confidence, evidence_span) VALUES (?, ?, ?, ?, ?, ?)",
        (concept_id, question_text, answer_text,
         d["misconception_id"], d["confidence"], d["evidence_span"]),
    )

    concept = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    return templates.TemplateResponse(
        request, "partials/diagnosis.html",
        {"concept": concept, "question": question_text,
         "answer": answer_text, "d": d},
    )


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
        request, "debug.html",
        {"concepts": concepts, "by_concept": by_concept})


@app.get("/health")
def health():
    return {"ok": True}
