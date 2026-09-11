"""Text → concepts, each with a CLOSED list of candidate misconceptions.

The closed list is the keystone of the whole system: because it's finite and
frozen at ingest, diagnosis becomes classification (not generation), artifacts
become pre-renderable, and the model can never invent a misconception we have
no content for.
"""
import re

from pydantic import BaseModel, Field

from llm import client
from store import db


class Misconception(BaseModel):
    slug: str = Field(description="lowercase_snake_case, unique within the concept")
    name: str = Field(description="short label, e.g. 'Treats the chain rule as multiplication'")
    description: str = Field(description='max 25 words')
    wrong_model: str = Field(description="the belief in the STUDENT'S voice, one line")
    correct_model: str = Field(description="the correction, one line")


class Concept(BaseModel):
    name: str
    summary: str
    misconceptions: list[Misconception]


class ConceptSet(BaseModel):
    concepts: list[Concept]


SYSTEM = """You are an experienced teacher who has graded thousands of student \
answers and knows exactly how learners get things wrong.

You will be given the text of a study document. Identify the key concepts a \
student must actually master, and for each one, the specific WRONG MENTAL MODELS \
students are documented to hold.

Rules:
- 5 to 6 concepts. Concepts a student could be asked to EXPLAIN, not headings.
- Exactly 3 misconceptions per concept.
- Misconceptions must be specific, classic, diagnosable confusions of reasoning.
  GOOD: "Believes the chain rule multiplies the two derivatives together."
  BAD:  "Makes calculation errors." / "Doesn't understand the topic."
- `wrong_model` must be written in the student's own voice, as a sentence they
  would agree with. This is what we later match their writing against, so it
  must sound like something a real student would say.
- `correct_model` is the one-line fix. Plain language.
- `slug` is lowercase_snake_case and unique within its concept.

Return ONLY valid JSON. No prose, no markdown fences."""

USER_TEMPLATE = """Document text:

<document>
{text}
</document>

Return JSON of exactly this shape:
{{"concepts": [{{"name": "...", "summary": "...", "misconceptions": [
  {{"slug": "...", "name": "...", "description": "...",
    "wrong_model": "...", "correct_model": "..."}}
]}}]}}"""


def _slugify(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def ingest_document(doc_id: int, text: str) -> int:
    """Extract and persist concepts + misconceptions. Returns concept count."""
    result = client.call_json(
        SYSTEM, USER_TEMPLATE.format(text=text), ConceptSet
    )

    for i, concept in enumerate(result.concepts):
        concept_id = db.execute(
            "INSERT INTO concepts (document_id, name, summary, order_index) "
            "VALUES (?, ?, ?, ?)",
            (doc_id, concept.name, concept.summary, i),
        )
        # Every concept starts unseen — this is the learner model's first row.
        db.execute(
            "INSERT INTO learner_state (concept_id, mastery) VALUES (?, 'unseen')",
            (concept_id,),
        )
        for m in concept.misconceptions:
            db.execute(
                "INSERT INTO misconceptions "
                "(concept_id, slug, name, description, wrong_model, correct_model, artifact_status) "
                "VALUES (?, ?, ?, ?, ?, ?, 'card')",
                (concept_id, _slugify(m.slug), m.name, m.description,
                 m.wrong_model, m.correct_model),
            )

    return len(result.concepts)
