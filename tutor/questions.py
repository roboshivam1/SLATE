"""Generates a question designed to ELICIT the known misconceptions."""
from pydantic import BaseModel

from llm import client
from store import db

SYSTEM = """You write short diagnostic questions for a tutoring system.

You are given a concept and the specific wrong mental models students hold about
it. Write ONE open-ended question that invites the student to EXPLAIN their
reasoning in 2-4 sentences.

HARD CONSTRAINTS:
- ONE question asking for ONE thing. Never bundle multiple asks with "and".
- Maximum 45 words total. If a scenario needs setup, keep the setup to one sentence.
- Answerable honestly in 2-4 sentences by a student at a keyboard.

The question must be designed so that a student holding any of the listed
misconceptions would reveal it. Prefer a short concrete scenario or a judgement
call over a definition request — "definition" questions get textbook parroting,
which is undiagnosable.

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


RETEST_SYSTEM = """You write a single targeted retest question.

The student held a specific wrong mental model and has just been shown the
correction. Write ONE question that can only be answered well by someone who has
actually abandoned that wrong model — not a rephrasing of the original question,
and not answerable by parroting the correction back.

Prefer a fresh concrete case that pivots on exactly this distinction.
Do NOT mention the misconception. Return ONLY valid JSON. No prose, no fences."""

RETEST_USER = """Concept: {name}

The wrong model the student held:
"{wrong_model}"

The correction they were shown:
"{correct_model}"

Return: {{"question": "..."}}"""


def retest_question_for(concept_id: int, misconception_id: int) -> str:
    c = db.one("SELECT * FROM concepts WHERE id = ?", (concept_id,))
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    result = client.call_json(
        RETEST_SYSTEM,
        RETEST_USER.format(name=c["name"], wrong_model=m["wrong_model"],
                           correct_model=m["correct_model"]),
        Question,
    )
    return result.question
