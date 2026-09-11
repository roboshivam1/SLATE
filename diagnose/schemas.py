"""The determinism contract for diagnosis. Built per-concept at call time."""
from typing import Literal

from pydantic import BaseModel, Field, create_model


class DiagnosisBase(BaseModel):
    confidence: float = Field(ge=0.0, le=1.0)
    evidence_span: str = Field(description="verbatim substring of the student's answer")
    narration: str = Field(description="one sentence, plain language, addressed to the student")


def build_schema(slugs: list[str]) -> type[DiagnosisBase]:
    """A schema whose misconception_slug is restricted to THIS concept's options."""
    allowed = Literal[tuple(slugs + ["correct", "unknown"])]  # type: ignore
    return create_model(
        "Diagnosis",
        __base__=DiagnosisBase,
        misconception_slug=(allowed, ...),
    )
