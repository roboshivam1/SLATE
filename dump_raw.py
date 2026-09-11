import sys, json
from dotenv import load_dotenv
load_dotenv(override=True)
from ingest import pdf as pdf_ingest
from ingest.concepts import SYSTEM, USER_TEMPLATE
from llm import client

text, pages = pdf_ingest.extract(sys.argv[1])
print(f"pages={pages} chars={len(text)}  calling…", flush=True)
raw = client._raw_call(SYSTEM, USER_TEMPLATE.format(text=text))
open("raw.json", "w").write(raw)
print(f"wrote raw.json ({len(raw)} chars)")
try:
    d = json.loads(client._strip_fences(raw))
    print("parsed OK, concepts:", len(d.get("concepts", [])))
except Exception as e:
    print("PARSE FAILED:", e)
