"""Diagnose ingestion outside the web app. Usage: python check_ingest.py <pdf>"""
import sys, json, traceback
from dotenv import load_dotenv
load_dotenv(override=True)

from ingest import pdf as pdf_ingest
from ingest.concepts import SYSTEM, USER_TEMPLATE, ConceptSet
from llm import client

path = sys.argv[1]
text, pages = pdf_ingest.extract(path)

print(f"pages={pages}  chars={len(text)}")
print("--- first 400 chars of extracted text ---")
print(repr(text[:400]))
print("-" * 50)

if len(text.strip()) < 200:
    print("!! PDF yielded almost no text — likely a scanned/image PDF.")
    sys.exit(1)

import time
print('calling model…', flush=True)
_t = time.time()
raw = client._raw_call(SYSTEM, USER_TEMPLATE.format(text=text))
print(f'model returned in {time.time()-_t:.1f}s')
print(f"raw response length: {len(raw)} chars")
print("--- last 300 chars (truncation shows up here) ---")
print(repr(raw[-300:]))
print("-" * 50)

try:
    parsed = ConceptSet.model_validate(json.loads(client._strip_fences(raw)))
    print(f"OK — {len(parsed.concepts)} concepts")
    for c in parsed.concepts:
        print(f"  • {c.name}  ({len(c.misconceptions)} misconceptions)")
except Exception:
    traceback.print_exc()
