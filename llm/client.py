"""One Anthropic client. Returns validated Pydantic objects or raises."""
import json
import os

from anthropic import Anthropic
from pydantic import BaseModel, ValidationError

from llm import cache

MODEL = "claude-sonnet-5"
_client = Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))


def _strip_fences(text: str) -> str:
    """Claude sometimes wraps JSON in ```json ... ``` despite being told not to."""
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        text = text.rsplit("```", 1)[0]
    return text.strip()


def _raw_call(system: str, user: str) -> str:
    resp = _client.messages.create(
        model=MODEL,
        max_tokens=16000,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    # content may contain ThinkingBlock, ToolUseBlock, etc. Never index blindly.
    parts = [b.text for b in resp.content if getattr(b, "type", None) == "text"]
    if not parts:
        kinds = [getattr(b, "type", "?") for b in resp.content]
        raise RuntimeError(f"No text block in response; got blocks: {kinds}")
    return "\n".join(parts)


def call_json(system: str, user: str, schema: type[BaseModel], use_cache: bool = True):
    """Call the model, parse JSON, validate against `schema`. One repair retry."""
    if use_cache:
        hit = cache.get(system, user, schema.__name__)
        if hit is not None:
            return schema.model_validate(hit)

    attempt_user = user
    last_error = None

    for _ in range(2):                       # first try, then one repair
        raw = _strip_fences(_raw_call(system, attempt_user))
        try:
            parsed = schema.model_validate(json.loads(raw))
        except (json.JSONDecodeError, ValidationError) as e:
            last_error = e
            attempt_user = (
                f"{user}\n\n"
                f"Your previous response was rejected with this error:\n{e}\n\n"
                f"Return ONLY valid JSON matching the schema. No prose, no code fences."
            )
            continue

        if use_cache:
            cache.put(system, user, schema.__name__, response=parsed.model_dump())
        return parsed

    raise RuntimeError(f"LLM returned invalid JSON twice: {last_error}")
