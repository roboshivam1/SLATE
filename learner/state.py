"""Reads learner state. M5 adds the transition logic."""
from store import db

ORDER = {"unseen": 0, "shaky": 1, "diagnosed": 2, "improving": 3, "mastered": 4}


def map_for(doc_id: int) -> list[dict]:
    rows = db.query(
        "SELECT c.id, c.name, c.summary, "
        "       COALESCE(ls.mastery, 'unseen') AS mastery "
        "FROM concepts c "
        "LEFT JOIN learner_state ls ON ls.concept_id = c.id "
        "WHERE c.document_id = ? ORDER BY c.order_index",
        (doc_id,),
    )
    return [dict(r) for r in rows]


def next_concept(doc_id: int) -> dict | None:
    """Least-mastered concept first; ties broken by document order."""
    concepts = map_for(doc_id)
    if not concepts:
        return None
    return min(concepts, key=lambda c: (ORDER.get(c["mastery"], 0), c["id"]))
