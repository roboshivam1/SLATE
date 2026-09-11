import os
import time
import re
from copy import deepcopy
from flask import Flask, render_template, request, redirect, url_for, jsonify, make_response

app = Flask(__name__, template_folder="templates", static_folder="static")

# ==============================================================================
# CANONICAL FIXTURE DATA (PER PRODUCT SPECIFICATION)
# ==============================================================================

DEFAULT_CONCEPT = {
    "id": 1,
    "name": "Chain Rule",
    "mastery": "diagnosed"
}

DEFAULT_DIAGNOSIS = {
    "misconception_name": "Treats the chain rule as multiplication",
    "narration": "You're combining the two derivatives by multiplying them, but the chain rule composes them instead.",
    "evidence_span": "so I just multiplied the two derivatives together",
    "confidence": 0.82
}

DEFAULT_REMEDIATION = {
    "kind": "clip",
    "clip_url": "/static/clips/chain_rule_as_product.mp4",
    "wrong_model": "Derivatives of composed functions multiply.",
    "correct_model": "The chain rule composes derivatives: multiply by the derivative of the outer function evaluated at the inner."
}

DEFAULT_CONCEPT_MAP = [
    {
        "id": 1,
        "name": "Chain Rule",
        "mastery": "diagnosed",
        "just_updated": False
    },
    {
        "id": 2,
        "name": "Product Rule",
        "mastery": "mastered",
        "just_updated": False
    },
    {
        "id": 3,
        "name": "Implicit Differentiation",
        "mastery": "unseen",
        "just_updated": False
    }
]

# In-memory session state for demo
session_state = {
    "concept": deepcopy(DEFAULT_CONCEPT),
    "diagnosis": deepcopy(DEFAULT_DIAGNOSIS),
    "remediation": deepcopy(DEFAULT_REMEDIATION),
    "concept_map": deepcopy(DEFAULT_CONCEPT_MAP),
    "student_explanation": "So I just multiplied the two derivatives together because that's how derivatives work."
}

def highlight_evidence(text: str, evidence_span: str) -> str:
    """
    Highlights the detected evidence span within student text using <mark class="evidence-mark">.
    Maintains case-insensitive match while preserving original casing.
    """
    if not text:
        return f'<mark class="evidence-mark">{evidence_span}</mark>'
    
    # Case-insensitive replacement
    pattern = re.compile(re.escape(evidence_span), re.IGNORECASE)
    match = pattern.search(text)
    if match:
        start, end = match.span()
        matched_str = text[start:end]
        return text[:start] + f'<mark class="evidence-mark">{matched_str}</mark>' + text[end:]
    
    # Fallback: look for sub-keywords or highlight whole phrase
    kw_pattern = re.compile(r"(multiplied the two derivatives together|multiplied the derivatives|multiplied)", re.IGNORECASE)
    if kw_pattern.search(text):
        return kw_pattern.sub(lambda m: f'<mark class="evidence-mark">{m.group(0)}</mark>', text, count=1)
    
    return f'<mark class="evidence-mark">{text}</mark>'

# ==============================================================================
# ROUTES (HTMX REST / SERVER-RENDERED)
# ==============================================================================

@app.route("/")
def index():
    """GET /: Clean dropzone & material intake page"""
    return render_template("upload.html")

@app.route("/upload", methods=["POST"])
def upload():
    """POST /upload: Handle document upload and transition to study workspace"""
    # Simulate extraction
    time.sleep(0.2)
    # Reset in-memory state for a fresh demonstration run
    session_state["concept"] = deepcopy(DEFAULT_CONCEPT)
    session_state["diagnosis"] = deepcopy(DEFAULT_DIAGNOSIS)
    session_state["remediation"] = deepcopy(DEFAULT_REMEDIATION)
    session_state["concept_map"] = deepcopy(DEFAULT_CONCEPT_MAP)
    return redirect(url_for("study", doc="calculus-derivatives"))

@app.route("/study/<doc>")
def study(doc):
    """GET /study/{doc}: Main desktop-first laboratory workbench"""
    concept = session_state["concept"]
    diagnosis = session_state["diagnosis"]
    remediation = session_state["remediation"]
    concept_map = session_state["concept_map"]
    
    explanation = session_state["student_explanation"]
    highlighted = highlight_evidence(explanation, diagnosis["evidence_span"])

    return render_template(
        "study.html",
        doc=doc,
        concept=concept,
        diagnosis=diagnosis,
        remediation=remediation,
        concept_map=concept_map,
        highlighted_explanation=highlighted,
        show_diagnosis=False,
        show_remediation=False
    )

@app.route("/answer", methods=["POST"])
def answer():
    """
    POST /answer: Server analyzes student explanation.
    Replaces #diagnosis-slot with animated <mark> evidence span and misconception.
    """
    # Simulate realistic cognitive diagnostic latency so the user observes the Thinking Pulse
    time.sleep(0.8)

    explanation = request.form.get("explanation", "").strip()
    if not explanation:
        explanation = session_state["student_explanation"]
    session_state["student_explanation"] = explanation

    diagnosis = session_state["diagnosis"]
    highlighted = highlight_evidence(explanation, diagnosis["evidence_span"])

    return render_template(
        "partials/diagnosis.html",
        concept=session_state["concept"],
        diagnosis=diagnosis,
        highlighted_explanation=highlighted
    )

@app.route("/remediation/<int:misconception_id>")
def remediation(misconception_id):
    """
    GET /remediation/{misconception_id}:
    Renders targeted remediation (clip or static explanation card)
    Both occupy identical visual footprint with zero layout jump.
    """
    mode = request.args.get("mode")
    rem_data = deepcopy(session_state["remediation"])
    
    if mode == "static":
        rem_data["kind"] = "static"
    elif mode == "clip":
        rem_data["kind"] = "clip"

    return render_template(
        "partials/remediation.html",
        concept=session_state["concept"],
        remediation=rem_data
    )

@app.route("/retest", methods=["POST"])
def retest():
    """
    POST /retest: Processes targeted retest.
    Transitions mastery state from diagnosed -> improving (scientific instrument animation).
    Uses HTMX out-of-band swap (hx-swap-oob) to update the concept map in real-time.
    """
    time.sleep(0.6)

    # Transition state to 'improving'
    session_state["concept"]["mastery"] = "improving"
    for item in session_state["concept_map"]:
        if item["id"] == 1:
            item["mastery"] = "improving"
            item["just_updated"] = True
        else:
            item["just_updated"] = False

    return render_template(
        "partials/retest.html",
        concept=session_state["concept"],
        concept_map=session_state["concept_map"]
    )

@app.route("/reset", methods=["GET", "POST"])
def reset():
    """Helper route to reset session fixture data for testing"""
    session_state["concept"] = deepcopy(DEFAULT_CONCEPT)
    session_state["diagnosis"] = deepcopy(DEFAULT_DIAGNOSIS)
    session_state["remediation"] = deepcopy(DEFAULT_REMEDIATION)
    session_state["concept_map"] = deepcopy(DEFAULT_CONCEPT_MAP)
    session_state["student_explanation"] = "So I just multiplied the two derivatives together because that's how derivatives work."
    return redirect(url_for("study", doc="calculus-derivatives"))

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"[*] SLATE Learning Lab server launching on http://localhost:{port}")
    app.run(host="0.0.0.0", port=port, debug=True)
