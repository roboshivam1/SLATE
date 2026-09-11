"""Artifact store.

Every generated artifact — notes, illustrations, audio — lands here, keyed by
(kind, scope, scope_id, state_fingerprint).

The fingerprint is what makes personalisation fall out of caching for free:
artifacts that depend on what the learner knows include a hash of the learner's
current mastery state in their key. Before any quizzing that hash is the
all-unseen one, so you get baseline content. After a diagnosis the hash changes,
the cache misses, and the SAME code path regenerates content shaped by what the
student just got wrong. No separate "personalised mode" to build or explain.

Artifacts that don't depend on the learner (a misconception illustration) pass
fingerprint="" and are generated once, forever.
"""
import hashlib
from typing import Callable

from store import db


def state_fingerprint(doc_id: int) -> str:
    """Stable hash of the learner's mastery state across one document."""
    rows = db.query(
        "SELECT c.id, COALESCE(ls.mastery,'unseen') AS m, "
        "       COALESCE(ls.active_misconception_id, 0) AS a "
        "FROM concepts c LEFT JOIN learner_state ls ON ls.concept_id = c.id "
        "WHERE c.document_id = ? ORDER BY c.id",
        (doc_id,),
    )
    blob = "|".join(f"{r['id']}:{r['m']}:{r['a']}" for r in rows)
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def get(kind: str, scope: str, scope_id: int, fingerprint: str = "") -> dict | None:
    row = db.one(
        "SELECT * FROM artifacts WHERE kind=? AND scope=? AND scope_id=? "
        "AND state_fingerprint=?",
        (kind, scope, scope_id, fingerprint),
    )
    return dict(row) if row else None


def put(kind: str, scope: str, scope_id: int, fingerprint: str,
        content: str | None = None, path: str | None = None) -> dict:
    db.execute(
        "INSERT OR REPLACE INTO artifacts "
        "(kind, scope, scope_id, state_fingerprint, content, path) "
        "VALUES (?,?,?,?,?,?)",
        (kind, scope, scope_id, fingerprint, content, path),
    )
    return get(kind, scope, scope_id, fingerprint)


def get_or_create(kind: str, scope: str, scope_id: int,
                  generator: Callable[[], tuple[str | None, str | None]],
                  fingerprint: str = "") -> dict | None:
    """Return the cached artifact, else run `generator` -> (content, path).

    Never raises: a failing generator returns None and callers fall back.
    """
    hit = get(kind, scope, scope_id, fingerprint)
    if hit:
        return hit
    try:
        content, path = generator()
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[artifacts] {kind}/{scope}/{scope_id} generation failed: {e}")
        return None
    if content is None and path is None:
        return None
    return put(kind, scope, scope_id, fingerprint, content, path)


def invalidate(kind: str, scope: str, scope_id: int) -> None:
    db.execute(
        "DELETE FROM artifacts WHERE kind=? AND scope=? AND scope_id=?",
        (kind, scope, scope_id),
    )
