"""Returns the best available remediation artifact. Never raises.

The fallback ladder, best first:
  clip  — a rendered Manim animation on disk            (CHALKDUST, later)
  svg   — a targeted, theme-aware illustration          (generated on demand)
  card  — the wrong/right text contrast                 (always available)

Every rung above `card` is an upgrade to a path that already works, so any of
them can fail or be absent and the product still functions.
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
    base["clip_url"] = f"/static/clips/{m['slug']}.mp4" if has_clip else None

    # Is an illustration already cached? (cheap check, no generation)
    from content import artifacts
    cached_svg = artifacts.get("svg", "misconception", misconception_id)
    base["has_svg"] = bool(cached_svg)

    # `force` drives the UI toggle so a judge can be shown each rung on demand.
    # It can never conjure an artifact that does not exist.
    if force == "card":
        return {**base, "kind": "card"}

    if force == "svg" or (force is None and not has_clip):
        svg = cached_svg["content"] if cached_svg else _try_generate(misconception_id)
        if svg:
            return {**base, "kind": "svg", "svg": svg, "has_svg": True}
        return {**base, "kind": "card"}

    if has_clip:
        return {**base, "kind": "clip"}

    return {**base, "kind": "card"}


def _try_generate(misconception_id: int) -> str | None:
    try:
        from content.illustrate import illustration_for
        return illustration_for(misconception_id)
    except Exception as e:
        print(f"[remediate] illustration failed for {misconception_id}: {e}")
        return None
