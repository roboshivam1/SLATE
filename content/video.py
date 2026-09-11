"""OPTIONAL video briefing, powered by the vendored CHALKDUST package.

To remove this feature entirely:
    SLATE_VIDEO=0          # disable, keep the code
    rm content/video.py    # delete; app.py's guarded import handles it
    rm -rf chalkdust/      # remove the vendored renderer too

Nothing else in SLATE imports CHALKDUST. app.py's import of this module is
wrapped in try/except, and every failure path here returns a status dict the
template renders as a notice.

HOW IT WORKS
    CHALKDUST has no CLI, so we drive its Python API directly:
        VideoSpec  ->  synthesize_video  ->  render_video  ->  assemble
    Audio is generated FIRST and measured; every animation's run time derives
    from that measured duration. So narration is not optional -- it is what
    gives each beat its length.

    manim is imported lazily inside the worker, never at app startup: it is
    heavy and we do not want it on the import path of a web request.

Scope: document-level, keyed on state_fingerprint -- the same key as the audio
briefing, so the video is personalised by construction.
"""
import importlib.util
import os
import shutil
import threading
import time
from pathlib import Path

from store import db
from content import artifacts, notes as notes_mod

VIDEO_DIR = Path("static/video")
CACHE_DIR = Path(os.getenv("SLATE_VIDEO_CACHE", ".chalkdust-cache"))
WORK_DIR = Path("/tmp/slate-video-work")

# Manim's config is process-global; tempconfig scopes it, but two concurrent
# renders would still contend. One at a time is plenty for a briefing.
_render_lock = threading.Lock()

_jobs: dict[int, dict] = {}
_jobs_lock = threading.Lock()


def _have(mod: str) -> bool:
    try:
        return importlib.util.find_spec(mod) is not None
    except (ImportError, ValueError):
        return False


def is_available() -> bool:
    """Cheap, import-free check. Decides whether the button renders at all."""
    if os.getenv("SLATE_VIDEO", "1").lower() in ("0", "false", "no"):
        return False
    return (_have("chalkdust") and _have("manim")
            and shutil.which("ffmpeg") is not None
            and shutil.which("ffprobe") is not None)


def missing_requirements() -> list[str]:
    out = []
    if not _have("chalkdust"):
        out.append("the chalkdust package (copy it into the repo root)")
    if not _have("manim"):
        out.append("manim==0.21.0 (pip install manim==0.21.0)")
    for b in ("ffmpeg", "ffprobe"):
        if shutil.which(b) is None:
            out.append(f"{b} on PATH")
    return out


def job_status(doc_id: int) -> dict:
    cached = artifacts.get("video", "document", doc_id,
                           artifacts.state_fingerprint(doc_id))
    if cached and cached["path"]:
        return {"state": "ready", "url": cached["path"], "script": cached["content"]}
    with _jobs_lock:
        job = _jobs.get(doc_id)
    return job or {"state": "idle"}


def start(doc_id: int) -> dict:
    status = job_status(doc_id)
    if status["state"] in ("ready", "rendering"):
        return status
    missing = missing_requirements()
    if missing:
        return {"state": "failed", "error": "Missing: " + "; ".join(missing)}

    with _jobs_lock:
        _jobs[doc_id] = {"state": "rendering", "started": time.time(),
                         "stage": "writing the script"}
    threading.Thread(target=_worker, args=(doc_id,), daemon=True).start()
    return job_status(doc_id)


def _set(doc_id: int, **kw):
    with _jobs_lock:
        _jobs.setdefault(doc_id, {}).update(kw)


def _clip(text: str, n: int = 120) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1].rsplit(" ", 1)[0] + "\u2026"


def build_beats(doc_id: int, plan: list[dict]) -> tuple[list[dict], str]:
    """Learner state -> beat dicts. Pure data; no CHALKDUST import needed.

    Narration is what sets each beat's duration, so it must read as speech.
    Component params match CHALKDUST's registered components exactly:
      TitleCard(title, subtitle, kicker) - BulletReveal(heading, items<=6, reveal)
    """
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    title = doc["title"].rsplit(".", 1)[0][:44]
    total = len(plan)
    mastered = sum(1 for p in plan if p["mastery"] == "mastered")

    focus = next((p for p in plan if p["misconception"]), None)
    if focus is None:
        focus = next((p for p in plan if p["mastery"] != "mastered"), plan[0])

    beats = [{
        "id": "b01",
        "narration": (f"Here is where you stand on {title}. "
                      f"You have mastered {mastered} of {total} concepts so far."),
        "component": "TitleCard",
        "params": {"kicker": "SLATE briefing", "title": title,
                   "subtitle": f"{mastered} of {total} concepts mastered"},
    }]

    if focus["misconception"]:
        m = focus["misconception"]
        beats += [
            {"id": "b02",
             "narration": (f"The one to fix first is {focus['name']}. "
                           "Your answer showed a specific belief behind the mistake."),
             "component": "BulletReveal",
             "params": {"heading": _clip(focus["name"], 40),
                        "items": [_clip(m["name"])]}},
            {"id": "b03",
             "narration": "Right now, this is what you think is true.",
             "component": "BulletReveal",
             "params": {"heading": "What you currently think",
                        "items": [_clip(m["wrong_model"])]}},
            {"id": "b04",
             "narration": ("Here is what is actually the case. Read the difference "
                           "carefully, then try explaining it again in your own words."),
             "component": "BulletReveal",
             "params": {"heading": "What is actually true",
                        "items": [_clip(m["correct_model"])]}},
        ]
        summary = (f"Focus: {focus['name']}. Diagnosed: {m['name']}. "
                   f"You believe \u2014 {m['wrong_model']} In fact \u2014 {m['correct_model']}")
    else:
        beats.append({
            "id": "b02",
            "narration": (f"Nothing is diagnosed yet. Start with {focus['name']}, "
                          "and explain it in your own words so SLATE can read "
                          "your reasoning."),
            "component": "BulletReveal",
            "params": {"heading": "Start here",
                       "items": [_clip(focus["name"], 60),
                                 _clip(focus["summary"], 90)]},
        })
        summary = f"Next concept to attempt: {focus['name']}."

    return beats, summary


def _register_gemini_backend() -> None:
    """Add a cloud TTS backend WITHOUT editing the vendored package.

    CHALKDUST's BACKENDS dict is module-level and its TTSBackend contract is a
    Protocol -- a name plus synthesize(text, voice, out_path) -- so registering
    from outside is enough.
    """
    from chalkdust.speech import tts as cd_tts
    if "gemini" in cd_tts.BACKENDS:
        return

    from content.narrate import _synthesize as gemini_wav

    class GeminiBackend:
        name = "gemini"

        def synthesize(self, text, voice, out_path):
            out_path.write_bytes(gemini_wav(text))

    cd_tts.BACKENDS["gemini"] = GeminiBackend()


def _pick_voice():
    """Gemini when a key is present (deployable), else macOS say (zero setup)."""
    from chalkdust.core.models import VoiceConfig
    if os.getenv("GEMINI_API_KEY"):
        _register_gemini_backend()
        return VoiceConfig(backend="gemini",
                           voice_id=os.getenv("SLATE_TTS_VOICE", "Kore"))
    return VoiceConfig(backend="macos_say", voice_id="Daniel")


def _worker(doc_id: int):
    try:
        fp = artifacts.state_fingerprint(doc_id)
        plan = notes_mod.build_plan(doc_id)
        if not plan:
            raise RuntimeError("this document has no concepts")

        beats, summary = build_beats(doc_id, plan)

        # Imported here, not at module load: manim is heavy.
        from chalkdust.core.cache import Cache
        from chalkdust.core.models import (
            BeatSpec, BuildContext, Quality, Video, VideoSpec,
        )
        from chalkdust.render.assemble import assemble
        from chalkdust.render.worker import render_video
        from chalkdust.speech.tts import synthesize_video

        spec = VideoSpec(
            video_id=f"slate-doc{doc_id}-{fp}",
            beats=tuple(BeatSpec(**b) for b in beats),
            voice=_pick_voice(),
        )
        video = Video.from_spec(spec)
        cache = Cache(CACHE_DIR)
        ctx = BuildContext(quality=Quality.DRAFT)   # 854x480@15fps -- fast

        _set(doc_id, stage="synthesising narration")
        synthesize_video(video, cache, verbose=True)

        _set(doc_id, stage="rendering animation \u2014 this is the slow part")
        VIDEO_DIR.mkdir(parents=True, exist_ok=True)
        out = VIDEO_DIR / f"doc-{doc_id}-{fp}.mp4"

        with _render_lock:
            render_video(video, ctx, cache, verbose=True)
            _set(doc_id, stage="muxing and mastering")
            assemble(video, out, WORK_DIR / f"doc{doc_id}", verbose=True)

        if not out.exists() or out.stat().st_size == 0:
            raise RuntimeError("assembly produced no output file")

        artifacts.put("video", "document", doc_id, fp,
                      content=summary, path=f"/static/video/{out.name}")
        _set(doc_id, state="ready", url=f"/static/video/{out.name}", script=summary)

    except Exception as e:
        import traceback
        traceback.print_exc()
        _set(doc_id, state="failed", error=f"{type(e).__name__}: {e}")
