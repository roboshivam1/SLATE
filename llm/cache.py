"""Prompt-hash → response cache. Makes re-runs free and the demo offline-safe."""
import hashlib
import json

from store import db


def _key(*parts: str) -> str:
    """One stable hash for the whole prompt. Any change = a different key."""
    blob = "\x00".join(parts)
    return hashlib.sha256(blob.encode()).hexdigest()


def get(*parts: str):
    row = db.one("SELECT response_json FROM llm_cache WHERE prompt_hash = ?", (_key(*parts),))
    return json.loads(row["response_json"]) if row else None


def put(*parts: str, response: dict) -> None:
    db.execute(
        "INSERT OR REPLACE INTO llm_cache (prompt_hash, response_json) VALUES (?, ?)",
        (_key(*parts), json.dumps(response)),
    )
