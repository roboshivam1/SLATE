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
