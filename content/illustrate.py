"""Targeted SVG illustrations.

The model proposes SVG; `sanitize()` enforces it. Anything outside the
whitelist — scripts, external references, event handlers, off-theme colours —
is rejected, the model gets one repair attempt, and if that fails the caller
falls back to the text card. Malformed markup can never reach the page.

Colours are restricted to the stylesheet's CSS variables, so illustrations
follow the light/dark theme toggle without us doing anything.
"""
import re
import xml.etree.ElementTree as ET

from llm import client
from store import db
from content import artifacts

SVG_NS = "http://www.w3.org/2000/svg"

ALLOWED_TAGS = {
    "svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon",
    "path", "text", "tspan", "defs", "marker", "title", "desc",
}

ALLOWED_ATTRS = {
    "viewBox", "xmlns", "width", "height", "x", "y", "x1", "y1", "x2", "y2",
    "cx", "cy", "r", "rx", "ry", "d", "points", "transform", "fill", "stroke",
    "stroke-width", "stroke-dasharray", "stroke-linecap", "stroke-linejoin",
    "opacity", "fill-opacity", "stroke-opacity", "font-size", "font-family",
    "font-weight", "text-anchor", "dominant-baseline", "dy", "dx", "id",
    "class", "marker-end", "marker-start", "orient", "refX", "refY",
    "markerWidth", "markerHeight", "letter-spacing",
}

ALLOWED_PAINT = {
    "none", "currentColor", "transparent",
    "var(--ink-primary)", "var(--ink-secondary)", "var(--ink-muted)",
    "var(--accent-electric)", "var(--bg-surface)", "var(--bg-surface-inset)",
    "var(--border-graphite)", "var(--border-subtle)", "var(--border-hairline)",
    "var(--state-diagnosed)", "var(--state-diagnosed-bg)",
    "var(--state-mastered)", "var(--state-mastered-bg)",
    "var(--state-shaky)", "var(--state-improving)",
}

PAINT_ATTRS = {"fill", "stroke"}


class SvgRejected(Exception):
    pass


def sanitize(raw: str) -> str:
    """Validate and normalise model-produced SVG. Raises SvgRejected."""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-z]*\n?", "", raw)
        raw = raw.rsplit("```", 1)[0].strip()

    start = raw.find("<svg")
    if start == -1:
        raise SvgRejected("no <svg> element found")
    raw = raw[start:]

    lowered = raw.lower()
    for bad in ("<script", "<foreignobject", "<image", "<use", "javascript:",
                "xlink:href", "data:text/html", "<iframe", "<style", "@import"):
        if bad in lowered:
            raise SvgRejected(f"forbidden content: {bad}")
    if re.search(r'\son[a-z]+\s*=', raw, re.IGNORECASE):
        raise SvgRejected("event handler attribute present")

    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        raise SvgRejected(f"not well-formed XML: {e}")

    def local(tag: str) -> str:
        return tag.split("}", 1)[1] if "}" in tag else tag

    if local(root.tag) != "svg":
        raise SvgRejected("root element is not <svg>")
    if not root.get("viewBox"):
        raise SvgRejected("missing viewBox attribute")

    for el in root.iter():
        name = local(el.tag)
        if name not in ALLOWED_TAGS:
            raise SvgRejected(f"disallowed element <{name}>")
        for attr, value in list(el.attrib.items()):
            a = local(attr)
            if a not in ALLOWED_ATTRS:
                del el.attrib[attr]
                continue
            if a in PAINT_ATTRS:
                v = value.strip()
                if v not in ALLOWED_PAINT and not v.startswith("url(#"):
                    raise SvgRejected(
                        f'{a}="{v}" is not an allowed theme colour; use one of: '
                        + ", ".join(sorted(ALLOWED_PAINT))
                    )

    # Responsive: drop fixed pixel size, keep the aspect ratio from viewBox.
    root.attrib.pop("width", None)
    root.attrib.pop("height", None)
    root.set("xmlns", SVG_NS)
    root.set("class", "slate-illustration")

    ET.register_namespace("", SVG_NS)
    return ET.tostring(root, encoding="unicode")


SYSTEM = """You draw precise educational diagrams as raw SVG.

You are given a wrong mental model a student holds and the correct model. Draw a
SINGLE diagram, split into two labelled panels side by side, that makes the
difference visible at a glance.

HARD REQUIREMENTS:
- Output ONLY raw SVG markup. No prose, no markdown fences, no explanation.
- Root element <svg> with a viewBox of exactly "0 0 720 360". No width/height.
- Left panel = the student's current (wrong) model. Right panel = the correct model.
- Label the panels. Keep total text under 40 words; this is a diagram, not a slide.
- Use shapes and spatial relationships to carry the meaning: containment,
  arrows, grouping, size. A diagram that only contains text has failed.

ALLOWED ELEMENTS: svg, g, rect, circle, ellipse, line, polyline, polygon, path,
text, tspan, defs, marker, title, desc. Nothing else.

ALLOWED fill/stroke VALUES — using anything else (including hex codes) is a
hard failure:
  none, currentColor,
  var(--ink-primary), var(--ink-secondary), var(--ink-muted),
  var(--accent-electric), var(--bg-surface), var(--bg-surface-inset),
  var(--border-graphite), var(--border-subtle), var(--border-hairline),
  var(--state-diagnosed), var(--state-diagnosed-bg),
  var(--state-mastered), var(--state-mastered-bg),
  var(--state-shaky), var(--state-improving)

Use var(--state-diagnosed) for the wrong panel's accents and
var(--state-mastered) for the correct panel's. Text should be
var(--ink-primary) or var(--ink-secondary). font-size 13-16 for labels."""

USER_TEMPLATE = """Concept: {concept}

The student's wrong mental model:
"{wrong_model}"

The correct model:
"{correct_model}"

Draw the contrast."""


def _generate_svg(concept_name: str, wrong: str, correct: str) -> str:
    user = USER_TEMPLATE.format(
        concept=concept_name, wrong_model=wrong, correct_model=correct
    )
    attempt = user
    last = None
    for _ in range(2):
        raw = client._raw_call(SYSTEM, attempt)
        try:
            return sanitize(raw)
        except SvgRejected as e:
            last = e
            attempt = (
                f"{user}\n\nYour previous SVG was REJECTED by the validator:\n"
                f"{e}\n\nReturn corrected raw SVG only."
            )
    raise SvgRejected(f"rejected twice: {last}")


def illustration_for(misconception_id: int) -> str | None:
    """Cached SVG for one misconception. Returns markup, or None on failure."""
    m = db.one("SELECT * FROM misconceptions WHERE id = ?", (misconception_id,))
    if not m:
        return None
    c = db.one("SELECT * FROM concepts WHERE id = ?", (m["concept_id"],))

    art = artifacts.get_or_create(
        "svg", "misconception", misconception_id,
        generator=lambda: (
            _generate_svg(c["name"], m["wrong_model"], m["correct_model"]),
            None,
        ),
    )
    return art["content"] if art else None
