"""Classifies a free-response answer against a CLOSED list of misconceptions.

The model chooses from a menu. It never generates a diagnosis.
"""
import re

from llm import client
from store import db
from diagnose.schemas import build_schema

SYSTEM = """You diagnose student misunderstanding.

You are given a concept, a question, a student's answer, and a NUMBERED LIST of
known wrong mental models. Decide which ONE the student's answer reveals.

Rules:
- Return the `slug` of exactly one listed misconception, OR "correct" if the
  answer is sound, OR "unknown" ONLY as a last resort.
- Match on the BELIEF the answer expresses, not on whether it addressed the
  question asked. A student who answers a different question, or answers in one
  short line, is still revealing a mental model — diagnose that model.
- A partial, vague or incomplete answer that leans toward a listed belief IS
  that misconception, reported at lower confidence. Do not escalate to
  "unknown" merely because the answer is thin.
- Reserve "unknown" for an answer that is clearly wrong in a way genuinely
  absent from the list, or that contains no reasoning at all.
- `evidence_span` MUST be copied verbatim from the student's answer — the exact
  characters, not a paraphrase. This is the phrase that revealed the belief.
  For "correct", quote the phrase that shows they understand.
- `confidence` is your honest certainty, 0.0 to 1.0. Use low values freely.
  A vague or empty answer is low confidence, not a confident "unknown".
- `narration` is ONE sentence spoken TO the student, naming what they believe
  and why it's wrong. Warm, specific, not scolding. Never say "the student".

Return ONLY valid JSON. No prose, no fences."""

USER_TEMPLATE = """Concept: {concept}

Question asked:
{question}

Student's answer:
<answer>
{answer}
</answer>

Known wrong mental models:
{options}

Return: {{"misconception_slug": "...", "confidence": 0.0,
          "evidence_span": "...", "narration": "..."}}"""


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower()).strip()


def _verify_span(span: str, answer: str) -> bool:
    """Did the model actually quote the student, or invent it?"""
    return bool(span) and _norm(span) in _norm(answer)


def diagnose(concept_id: int, question: str, answer: str) -> dict:
    concept = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    miscs = db.query(
        "SELECT id, slug, name, wrong_model FROM misconceptions WHERE concept_id = ?",
        (concept_id,),
    )

    options = "\n".join(
        f'- slug: "{m["slug"]}"\n  belief: "{m["wrong_model"]}"' for m in miscs
    )
    schema = build_schema([m["slug"] for m in miscs])

    result = client.call_json(
        SYSTEM,
        USER_TEMPLATE.format(
            concept=concept["name"], question=question, answer=answer, options=options
        ),
        schema,
        use_cache=False,          # every answer is unique
    )

    slug = result.misconception_slug
    confidence = result.confidence
    span = result.evidence_span

    # Honesty layer: an unverifiable quote means we trust the call less.
    if slug not in ("correct", "unknown") and not _verify_span(span, answer):
        confidence = max(0.0, confidence - 0.3)
        span = ""

    row = next((m for m in miscs if m["slug"] == slug), None)

    return {
        "slug": slug,
        "misconception_id": row["id"] if row else None,
        "misconception_name": row["name"] if row else None,
        "confidence": round(confidence, 2),
        "evidence_span": span,
        "narration": result.narration,
        "is_correct": slug == "correct",
        "is_unknown": slug == "unknown",
        "is_tentative": confidence < 0.6,
    }
