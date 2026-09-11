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


MASTERY_LABELS = {
    "unseen": "not yet attempted",
    "shaky": "unclear",
    "diagnosed": "misconception found",
    "improving": "working on it",
    "mastered": "mastered",
}


def get(concept_id: int) -> dict:
    row = db.one("SELECT * FROM learner_state WHERE concept_id = ?", (concept_id,))
    if row:
        return dict(row)
    db.execute(
        "INSERT INTO learner_state (concept_id, mastery) VALUES (?, 'unseen')",
        (concept_id,),
    )
    return {"concept_id": concept_id, "mastery": "unseen",
            "attempts_count": 0, "active_misconception_id": None}


def apply(concept_id: int, d: dict, is_retest: bool = False) -> str:
    """Transition mastery from a diagnosis. Pure logic — no LLM involved."""
    current = get(concept_id)
    was = current["mastery"]

    if d["is_correct"]:
        # Correct on a retest after remediation is the meaningful win.
        new = "mastered"
        active = None
    elif d["is_unknown"] or d["is_tentative"]:
        new = "shaky"
        active = d["misconception_id"]
    else:
        new = "diagnosed"
        active = d["misconception_id"]

    db.execute(
        "UPDATE learner_state SET mastery = ?, active_misconception_id = ?, "
        "attempts_count = attempts_count + 1, updated_at = CURRENT_TIMESTAMP "
        "WHERE concept_id = ?",
        (new, active, concept_id),
    )
    return new


def mark_remediated(concept_id: int) -> None:
    """Seeing the explanation moves 'diagnosed' forward to 'improving'."""
    current = get(concept_id)
    if current["mastery"] in ("diagnosed", "shaky"):
        db.execute(
            "UPDATE learner_state SET mastery = 'improving', "
            "updated_at = CURRENT_TIMESTAMP WHERE concept_id = ?",
            (concept_id,),
        )


def summary(doc_id: int) -> dict:
    rows = map_for(doc_id)
    counts = {}
    for r in rows:
        counts[r["mastery"]] = counts.get(r["mastery"], 0) + 1
    return {"total": len(rows), "counts": counts,
            "mastered": counts.get("mastered", 0)}
