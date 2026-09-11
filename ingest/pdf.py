"""PDF → text. Deliberately dumb: the whole document goes in the prompt."""
from pypdf import PdfReader

MAX_CHARS = 18_000


def extract(path: str) -> tuple[str, int]:
    """Returns (text, page_count)."""
    reader = PdfReader(path)
    pages = [(p.extract_text() or "") for p in reader.pages]
    text = "\n\n".join(pages)
    return text[:MAX_CHARS], len(reader.pages)
