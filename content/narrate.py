"""On-demand audio briefing.

Deliberately NOT a narration of the full notes — that would be a five-minute
file nobody listens to. Instead a separate ~60-second spoken script is written
fresh, summarising where this learner actually stands right now.

Generated only when the user presses the button. Cached under the same
state_fingerprint as the notes, so the briefing is personalised for free and
regenerates when understanding changes.

TTS: Gemini `gemini-3.1-flash-tts-preview` over plain REST. It returns raw PCM
(24kHz, mono, 16-bit) which we wrap as WAV using the stdlib — no ffmpeg, no
extra SDK, nothing that blocks cloud deployment.
"""
import base64
import io
import json
import os
import urllib.error
import urllib.request
import wave
from pathlib import Path

from pydantic import BaseModel, Field

from llm import client
from store import db
from content import artifacts, notes as notes_mod

AUDIO_DIR = Path("static/audio")
TTS_MODEL = "gemini-3.1-flash-tts-preview"
TTS_VOICE = os.getenv("SLATE_TTS_VOICE", "Kore")
TTS_URL = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    f"{TTS_MODEL}:generateContent"
)

PCM_RATE, PCM_CHANNELS, PCM_WIDTH = 24000, 1, 2


class Script(BaseModel):
    script: str = Field(description="spoken words only, 110-150 words")


SCRIPT_SYSTEM = """You write a SHORT spoken briefing for one learner, to be read
aloud by a text-to-speech voice.

HARD CONSTRAINTS:
- 110 to 150 words. This is roughly 60 seconds of speech. Never exceed it.
- Spoken register: short sentences, no lists, no headings, no markdown, no
  symbols, no numbered points. It must sound natural read aloud.
- Write "you", never "the student".
- Spell out anything a TTS voice would mangle. Write "three of six" not "3/6".

CONTENT:
- Open by telling them plainly where they stand.
- Spend most of the words on the ONE concept that most needs attention. If a
  misconception is named, say what they currently believe and why it is wrong.
- Close with a single concrete next action.
- If nothing has been attempted yet, say so and point at where to start.

Return ONLY valid JSON. No fences."""

SCRIPT_USER = """Document: {title}

Learner state:
{plan}

Write the briefing."""


def _plan_digest(plan: list[dict]) -> str:
    lines = []
    for p in plan:
        line = f'- "{p["name"]}": {p["mastery"]}'
        if p["misconception"]:
            m = p["misconception"]
            line += (f'\n    diagnosed misconception: {m["name"]}\n'
                     f'    they believe: "{m["wrong_model"]}"\n'
                     f'    the truth: "{m["correct_model"]}"')
        lines.append(line)
    return "\n".join(lines)


def _write_script(doc_id: int, plan: list[dict]) -> str:
    doc = db.one("SELECT * FROM documents WHERE id = ?", (doc_id,))
    result = client.call_json(
        SCRIPT_SYSTEM,
        SCRIPT_USER.format(title=doc["title"], plan=_plan_digest(plan)),
        Script,
        use_cache=False,
    )
    return result.script.strip()


def _pcm_to_wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(PCM_CHANNELS)
        wf.setsampwidth(PCM_WIDTH)
        wf.setframerate(PCM_RATE)
        wf.writeframes(pcm)
    return buf.getvalue()


def _synthesize(text: str) -> bytes:
    """Gemini TTS -> WAV bytes. Raises on failure; caller falls back."""
    key = os.getenv("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")

    payload = {
        "contents": [{"role": "user", "parts": [{"text": text}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
                "voiceConfig": {"prebuiltVoiceConfig": {"voiceName": TTS_VOICE}}
            },
        },
    }
    req = urllib.request.Request(
        TTS_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "x-goog-api-key": key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"TTS HTTP {e.code}: {e.read()[:300].decode(errors='replace')}")

    try:
        parts = body["candidates"][0]["content"]["parts"]
        b64 = next(p["inlineData"]["data"] for p in parts if "inlineData" in p)
    except (KeyError, IndexError, StopIteration):
        raise RuntimeError(f"no audio in TTS response: {str(body)[:300]}")

    return _pcm_to_wav(base64.b64decode(b64))


def audio_for(doc_id: int) -> dict | None:
    """Cached audio briefing for the learner's CURRENT state. None on failure."""
    plan = notes_mod.build_plan(doc_id)
    if not plan:
        return None

    fp = artifacts.state_fingerprint(doc_id)

    def generate():
        script = _write_script(doc_id, plan)
        wav_bytes = _synthesize(script)
        AUDIO_DIR.mkdir(parents=True, exist_ok=True)
        rel = f"doc-{doc_id}-{fp}.wav"
        (AUDIO_DIR / rel).write_bytes(wav_bytes)
        return script, f"/static/audio/{rel}"

    art = artifacts.get_or_create(
        "audio", "document", doc_id, generator=generate, fingerprint=fp
    )
    if not art:
        return None
    return {"script": art["content"], "url": art["path"],
            "seconds": max(20, round(len(art["content"].split()) / 2.4))}
