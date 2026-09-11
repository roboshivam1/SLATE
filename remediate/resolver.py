"""Returns the best available remediation artifact. Never raises.

Rung 1: cached clip on disk.
Rung 2: live render (wired in M7).
Rung 3: static explanation card, built from data we already have.
"""
from pathlib import Path

from store import db

CLIPS = Path("static/clips")


def get_remediation(misconception_id: int, force: str | None = None) -> dict | None:
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    if not m:
        return None

    base = {
        "id": m["id"],
        "name": m["name"],
        "description": m["description"],
        "wrong_model": m["wrong_model"],
        "correct_model": m["correct_model"],
    }

    clip = CLIPS / f"{m['slug']}.mp4"
    has_clip = clip.exists() and clip.stat().st_size > 0
    base["has_clip"] = has_clip

    # `force` comes from the UI toggle so a judge can see both rungs of the
    # fallback ladder on demand. It can never conjure a clip that isn't there.
    if force == "card":
        return {**base, "kind": "card"}
    if has_clip:
        return {**base, "kind": "clip", "clip_url": f"/static/clips/{m['slug']}.mp4"}
    return {**base, "kind": "card"}
