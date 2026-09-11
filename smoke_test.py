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

r_root = c.get("/", follow_redirects=False)
assert r_root.status_code == 307, r_root.status_code
print(f"ok   GET / redirects -> {r_root.headers['location']}")
check("GET /start", c.get("/start"), ["Upload Learning Material", "Fundamentals_of_Database"])
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

import app as _app
try:
    import content.video as vid
except ModuleNotFoundError:
    vid = None
if vid:
    _beats, _summary = vid.build_beats(doc_id, cn.build_plan(doc_id))
    from chalkdust.core.models import VideoSpec as _VS, BeatSpec as _BS
    _spec = _VS(video_id="smoke", beats=tuple(_BS(**b) for b in _beats))
    assert all(len(b.narration.split()) <= 80 for b in _spec.beats)
    print(f"ok   video: {len(_spec.beats)} beats validate against CHALKDUST schema")
    r = c.post(f"/notes/{doc_id}/video") if _app.VIDEO_ENABLED else None
    if r is not None:
        assert "VIDEO BRIEFING" in r.text
        print("ok   video: route renders")
    else:
        print(f"ok   video: unavailable here, correctly hidden ({vid.missing_requirements()})")
else:
    print("ok   video feature absent - app unaffected")

check("GET /doc home", c.get(f"/doc/{doc_id}"),
      ["ACTIVE LAB NOTEBOOK", "STAGE 01", "STAGE 02", "LEARN", "DIAGNOSE",
       "CONCEPT MASTERY MAP", "awaiting correction"])
check("GET /debug", c.get(f"/debug/{doc_id}"), ["Misconception 0-0"])
check("GET /health", c.get("/health"))

print("\nfinal mastery:",
      [(r["name"], r["mastery"]) for r in db.query(
          "SELECT c.name, ls.mastery FROM learner_state ls JOIN concepts c ON c.id=ls.concept_id")])
print("\n" + ("ALL PASS" if not fails else f"{len(fails)} FAILURES"))
sys.exit(1 if fails else 0)
