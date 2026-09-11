"""Generates a question designed to ELICIT the known misconceptions."""
from pydantic import BaseModel

from llm import client
from store import db

SYSTEM = """You write short diagnostic questions for a tutoring system.

You are given a concept and the specific wrong mental models students hold about
it. Write ONE open-ended question that invites the student to EXPLAIN their
reasoning in 2-4 sentences.

The question must be designed so that a student holding any of the listed
misconceptions would reveal it in their answer. Prefer a concrete scenario or a
judgement call over a definition request — "definition" questions get textbook
parroting, which is undiagnosable.

Do NOT mention the misconceptions or hint that any answer is wrong.
Return ONLY valid JSON. No prose, no fences."""

USER_TEMPLATE = """Concept: {name}
Summary: {summary}

Wrong mental models students hold:
{wrong_models}

Return: {{"question": "..."}}"""


class Question(BaseModel):
    question: str


def question_for(concept_id: int) -> str:
    concept = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    miscs = db.query(
        "SELECT wrong_model FROM misconceptions WHERE concept_id = ?", (concept_id,)
    )
    wrong_models = "\n".join(f"- {m['wrong_model']}" for m in miscs)

    result = client.call_json(
        SYSTEM,
        USER_TEMPLATE.format(
            name=concept["name"], summary=concept["summary"], wrong_models=wrong_models
        ),
        Question,
    )
    return result.question


def record_attempt(concept_id: int, question: str, answer: str) -> int:
    return db.execute(
        "INSERT INTO attempts (concept_id, question_text, answer_text) VALUES (?, ?, ?)",
        (concept_id, question, answer),
    )
