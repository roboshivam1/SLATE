import shutil
from pathlib import Path

from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, Request, UploadFile, File
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from store import db

app = FastAPI(title="SLATE")
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

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
    # M1 will run ingestion here.
    return RedirectResponse(f"/study/{doc_id}", status_code=303)


@app.get("/study/{doc_id}")
def study(request: Request, doc_id: int):
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    concepts = db.query(
        "SELECT * FROM concepts WHERE document_id = ? ORDER BY order_index",
        (doc_id,),
    )
    return templates.TemplateResponse(
        request, "study.html", {"doc": doc, "concepts": concepts}
    )


@app.get("/health")
def health():
    return {"ok": True}
