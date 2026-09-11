"""Wraps the evidence span in <mark> inside the student's answer."""
import re

from markupsafe import Markup, escape


def highlight(answer: str, span: str) -> Markup:
    if not span:
        return Markup(escape(answer))
    pattern = re.compile(
        r"\s+".join(re.escape(w) for w in span.split()), re.IGNORECASE
    )
    match = pattern.search(answer)
    if not match:
        return Markup(escape(answer))
    a, b = match.span()
    return Markup(
        f"{escape(answer[:a])}<mark class=\"evidence-mark\">{escape(answer[a:b])}</mark>{escape(answer[b:])}"
    )
