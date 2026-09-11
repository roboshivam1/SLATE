#!/usr/bin/env bash
# SLATE: loading states for every slow path (upload, illustration, retest).
set -euo pipefail
[ -f app.py ] || { echo "Run from the SLATE repo root."; exit 1; }
mkdir -p .backup_loading && cp -r templates static .backup_loading/ 2>/dev/null || true

echo "  write templates/upload.html"
cat > templates/upload.html << 'SLATE_EOF_MARKER'
{% extends "base.html" %}

{% block title %}Upload Learning Material — SLATE{% endblock %}

{% block content %}
<div class="lab-workspace lab-workspace-single">
  <div class="upload-wrapper">
    
    <div class="upload-intro">
      <div class="lab-label-technical" style="justify-content: center;">INTAKE CONSOLE // DOCUMENT ANALYSIS</div>
      <h1 class="lab-title-editorial">Upload Learning Material</h1>
      <p style="color: var(--ink-secondary); font-size: 1.05rem; line-height: 1.6; max-width: 580px; margin: 0 auto;">
        Upload your learning material.<br>
        SLATE will identify concepts and diagnose how you understand them.
      </p>
    </div>

    <!-- CLEAN DROP-ZONE FORM -->
    <form action="/upload" method="POST" enctype="multipart/form-data" class="lab-card" id="upload-form">
      <div class="lab-card-body" style="padding: var(--space-8);">
        <label for="material-file" class="upload-dropzone">
          <svg class="upload-icon-graphic" viewBox="0 0 24 24">
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
            <polyline points="14 2 14 8 20 8"></polyline>
            <line x1="12" y1="18" x2="12" y2="12"></line>
            <line x1="9" y1="15" x2="12" y2="12"></line>
            <line x1="15" y1="15" x2="12" y2="12"></line>
          </svg>
          <div>
            <div style="font-weight: 600; font-size: 1.05rem; color: var(--ink-primary); margin-bottom: 4px;">
              Select document or drag and drop file here
            </div>
            <div class="upload-specs">
              SUPPORTED FORMATS: PDF, MARKDOWN, LATEX, TXT (MAX 25MB)
            </div>
          </div>
          <input type="file" id="material-file" name="file" accept="application/pdf" class="upload-input-hidden">
          <div class="upload-selected-file" id="selected-file" hidden></div>
        </label>
      </div>

      <div class="lab-card-footer" style="justify-content: space-between;">
        <span class="lab-meta-mono">READY FOR EXTRACTION</span>
        <button type="submit" class="btn-lab btn-lab-accent">
          Process Document
        </button>
      </div>
    </form>

    <!-- EXISTING LAB NOTEBOOKS (REAL DOCUMENTS) -->
    {% if documents %}
    <div class="upload-fixtures-box">
      <div class="lab-label-technical" style="margin-bottom: var(--space-3);">OR SELECT AN ACTIVE LAB NOTEBOOK</div>
      <ul class="fixtures-list">
        {% for d in documents %}
        <li>
          <a href="/study/{{ d.id }}" class="fixture-link-item {% if not d.concept_count %}style-empty{% endif %}">
            <div>
              <strong>{{ d.title }}</strong>
              <div class="lab-meta-mono" style="margin-top: 2px;">
                {{ d.concept_count }} Core Concepts &bull; {{ d.page_count }} pages
                &bull; {% if d.concept_count %}Ready for diagnosis{% else %}No concepts extracted{% endif %}
              </div>
            </div>
            <span class="btn-lab btn-lab-outline" style="padding: 4px 10px; font-size: 0.7rem;">Enter Lab &rarr;</span>
          </a>
        </li>
        {% endfor %}
      </ul>
    </div>
    {% endif %}

  </div>
</div>

<!-- INGESTION OVERLAY: upload is a 20-60s synchronous round trip -->
<div id="ingest-overlay" role="status" aria-live="polite">
  <div class="ingest-doc" id="ingest-doc-name">PROCESSING DOCUMENT</div>
  <div class="ingest-bar"><span></span></div>
  <div class="ingest-stage" id="ingest-stage">Reading the document…</div>
  <div class="ingest-note">This runs once per document. Extraction takes up to a minute.</div>
</div>

<script>
(function () {
  var form  = document.getElementById('upload-form');
  var input = document.getElementById('material-file');
  var label = document.getElementById('selected-file');
  if (!form || !input) return;

  var STAGES = [
    'Reading the document…',
    'Identifying the concepts a learner must master…',
    'Working out how students get each one wrong…',
    'Building the closed misconception set…',
    'Almost there — writing the concept map…'
  ];

  function showOverlay(name) {
    var overlay = document.getElementById('ingest-overlay');
    var docName = document.getElementById('ingest-doc-name');
    var stage   = document.getElementById('ingest-stage');
    if (name && docName) docName.textContent = name.toUpperCase();
    overlay.classList.add('visible');
    var i = 0;
    setInterval(function () {
      i = (i + 1) % STAGES.length;
      stage.textContent = STAGES[i];
    }, 4200);
  }

  input.addEventListener('change', function () {
    if (!input.files.length) return;
    var name = input.files[0].name;
    label.hidden = false;
    label.textContent = '\u2713 ' + name + ' \u2014 starting extraction';
    showOverlay(name);
    form.submit();
  });

  form.addEventListener('submit', function () {
    var name = input.files.length ? input.files[0].name : null;
    showOverlay(name);
  });
})();
</script>
{% endblock %}
SLATE_EOF_MARKER

echo "  write templates/study.html"
cat > templates/study.html << 'SLATE_EOF_MARKER'
{% extends "base.html" %}

{% block title %}SLATE — Workspace: {{ concept.name if concept else doc.title }}{% endblock %}

{% block content %}
<div class="lab-workspace">
  <!-- MAIN WORKBENCH -->
  <div class="workbench-main">

    {% if concept %}
    <header style="border-bottom: 1px solid var(--border-subtle); padding-bottom: var(--space-4);">
      <div class="lab-label-technical">CURRENT INVESTIGATION</div>
      <div style="display: flex; align-items: baseline; justify-content: space-between; margin-top: 4px; gap: var(--space-4);">
        <h1 class="lab-title-editorial" style="font-size: 2rem;">{{ concept.name }}</h1>
        <span class="mastery-pill {{ concept.mastery }}">
          CURRENT STATE: {{ concept.mastery | upper }}
        </span>
      </div>
      <p style="color: var(--ink-secondary); font-size: 0.95rem; margin-top: 6px;">
        {{ concept.summary }}
      </p>
    </header>

    <div id="question-slot">
      {% include "partials/question.html" %}
    </div>

    <div id="diagnosis-slot"></div>

    <div id="rem-indicator" class="slate-loading" role="status" aria-live="polite">
      <span class="pulse-label">BUILDING TARGETED EXPLANATION</span>
      <div class="pulse-track"><div class="pulse-indicator-node"></div></div>
      <span class="lab-meta-mono" style="font-size: 0.65rem;">DRAWING ILLUSTRATION</span>
    </div>

    <div id="remediation-slot"></div>

    <div id="retest-indicator" class="slate-loading" role="status" aria-live="polite">
      <span class="pulse-label">COMPOSING TARGETED RETEST</span>
      <div class="pulse-track"><div class="pulse-indicator-node"></div></div>
      <span class="lab-meta-mono" style="font-size: 0.65rem;">AIMING AT DIAGNOSED GAP</span>
    </div>

    {% else %}
    <section class="lab-card">
      <div class="lab-card-header">
        <div class="lab-label-technical">EXTRACTION INCOMPLETE</div>
      </div>
      <div class="lab-card-body">
        <h2 class="lab-title-editorial" style="font-size: 1.4rem;">No concepts were extracted from this document.</h2>
        <p style="color: var(--ink-secondary);">
          The source may be a scanned PDF with no text layer. Try another document.
        </p>
        <a href="/" class="btn-lab btn-lab-outline" style="margin-top: var(--space-4);">&larr; Back to intake</a>
      </div>
    </section>
    {% endif %}

  </div>

  <!-- TELEMETRY & CONCEPT MAP RAIL -->
  <aside class="telemetry-rail">

    <div id="concept-map-slot">
      {% include "partials/concept_map.html" %}
    </div>

    <div class="lab-card">
      <div class="lab-card-header">
        <div class="lab-label-technical">SESSION TELEMETRY</div>
        <span class="lab-meta-mono">REAL-TIME</span>
      </div>
      <div class="lab-card-body" style="padding: var(--space-4);">
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Source Document</span>
          <span class="stat-metric">{{ doc.page_count }} pp</span>
        </div>
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Concepts Extracted</span>
          <span class="stat-metric">{{ summary.total }}</span>
        </div>
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Evidence Extraction</span>
          <span class="stat-metric" style="color: var(--accent-electric);">Active</span>
        </div>
        <div class="telemetry-stat-row">
          <span style="color: var(--ink-muted);">Divergence Threshold</span>
          <span class="stat-metric">&gt; 60% Confidence</span>
        </div>
      </div>
    </div>

    <div class="lab-card" style="background: var(--bg-surface-inset); border: 1px dashed var(--border-graphite);">
      <div class="lab-card-body" style="padding: var(--space-4);">
        <div class="lab-meta-mono" style="font-weight: 700; color: var(--ink-primary); margin-bottom: 6px;">
          THE SLATE COGNITIVE LOOP
        </div>
        <ol style="margin-left: 18px; font-family: var(--font-mono); font-size: 0.7rem; color: var(--ink-secondary); line-height: 1.8;">
          <li>Explain in your own words</li>
          <li>Evidence span extracted</li>
          <li>Misconception diagnosed</li>
          <li>Targeted model reconciliation</li>
          <li>Retest &amp; update mastery</li>
        </ol>
      </div>
    </div>

  </aside>
</div>
{% endblock %}
SLATE_EOF_MARKER

echo "  write templates/partials/diagnosis.html"
cat > templates/partials/diagnosis.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: DIAGNOSIS RESULT (HERO MOMENT) -->
<section class="lab-card diagnosis-container" id="diagnosis-card">
  <div class="lab-card-header">
    {% if diagnosis.is_correct %}
      <div class="lab-label-technical" style="color: var(--state-mastered);">
        REASONING VERIFIED // NO DIVERGENCE DETECTED
      </div>
    {% elif diagnosis.is_unknown %}
      <div class="lab-label-technical" style="color: var(--state-shaky);">
        DIVERGENCE PRESENT // OUTSIDE KNOWN MODEL SET
      </div>
    {% elif diagnosis.is_tentative %}
      <div class="lab-label-technical" style="color: var(--state-shaky);">
        PROVISIONAL DIAGNOSIS // LOW CONFIDENCE
      </div>
    {% else %}
      <div class="lab-label-technical" style="color: var(--state-diagnosed);">
        DIAGNOSIS VERIFIED // COGNITIVE DIVERGENCE IDENTIFIED
      </div>
    {% endif %}
    <span class="lab-meta-mono">
      {% if diagnosis.evidence_span %}EVIDENCE ANCHOR // EXACT MATCH{% else %}NO VERBATIM ANCHOR{% endif %}
    </span>
  </div>

  <div class="lab-card-body">
    <!-- STUDENT EVIDENCE BOX -->
    <div class="student-evidence-box">
      <blockquote class="student-quote-text">
        &ldquo;{{ highlighted_explanation }}&rdquo;
      </blockquote>
      {% if diagnosis.evidence_span %}
        <div style="margin-top: 8px; font-family: var(--font-mono); font-size: 0.68rem; color: var(--ink-muted);">
          &uarr; SLATE detected the divergent mental model directly from this phrasing.
        </div>
      {% endif %}
    </div>

    {% if diagnosis.is_correct %}
      <div class="misconception-banner" style="border-color: var(--state-mastered-border); background: var(--state-mastered-bg);">
        <div class="misconception-tag" style="color: var(--state-mastered);">
          <span>&check;</span> SOUND REASONING
        </div>
        <h3 class="misconception-title">No misconception found in this explanation.</h3>
      </div>
    {% elif diagnosis.is_unknown %}
      <div class="misconception-banner" style="border-color: var(--state-shaky-border); background: var(--state-shaky-bg);">
        <div class="misconception-tag" style="color: var(--state-shaky);">
          <span>&sim;</span> UNRECOGNISED PATTERN
        </div>
        <h3 class="misconception-title">Something is off, but it is not a model SLATE holds content for.</h3>
      </div>
    {% else %}
      <div class="misconception-banner">
        <div class="misconception-tag">
          <span>&bull;</span>
          {% if diagnosis.is_tentative %}POSSIBLE MISCONCEPTION{% else %}MISCONCEPTION DETECTED{% endif %}
        </div>
        <h3 class="misconception-title">
          {% if diagnosis.is_tentative %}You may be: {% endif %}{{ diagnosis.misconception_name }}
        </h3>
      </div>
    {% endif %}

    <!-- WHY WE THINK THIS -->
    <div class="diagnosis-reasoning">
      <div class="reasoning-label">WHY WE THINK THIS (OBSERVED COGNITIVE MODEL)</div>
      <p class="reasoning-text">{{ diagnosis.narration }}</p>
    </div>

    <!-- DIAGNOSTIC CONFIDENCE GAUGE -->
    <div class="confidence-gauge-group" style="--confidence-percent: {{ (diagnosis.confidence * 100) | int }}%;">
      <div class="confidence-label">DIAGNOSTIC CONFIDENCE</div>
      <div class="confidence-bar-track" aria-label="Confidence gauge {{ (diagnosis.confidence * 100) | int }}%">
        <div class="confidence-bar-fill"></div>
      </div>
      <div class="confidence-value">{{ (diagnosis.confidence * 100) | int }}%</div>
    </div>

    <!-- RECTIFICATION CALL TO ACTION -->
    <div class="lab-card-footer" style="padding: var(--space-4) 0 0 0; background: transparent; border-top: 1px solid var(--border-hairline);">
      {% if diagnosis.misconception_id %}
        <span class="lab-meta-mono" style="margin-right: auto;">TARGETED INTERVENTION PREPARED</span>
        <button
          class="btn-lab btn-lab-accent"
          hx-get="/remediation/{{ diagnosis.misconception_id }}"
          hx-target="#remediation-slot"
          hx-swap="innerHTML"
          hx-indicator="#rem-indicator"
        >
          See Targeted Explanation &rarr;
        </button>
      {% else %}
        <span class="lab-meta-mono" style="margin-right: auto;">NO INTERVENTION REQUIRED</span>
        <a href="/study/{{ doc_id }}" class="btn-lab btn-lab-outline">Next Concept &rarr;</a>
      {% endif %}
    </div>
  </div>
</section>

<!-- OUT-OF-BAND: repaint the concept map without a page reload -->
<div id="concept-map-slot" hx-swap-oob="true">
  {% include "partials/concept_map.html" %}
</div>
SLATE_EOF_MARKER

echo "  write templates/partials/remediation.html"
cat > templates/partials/remediation.html << 'SLATE_EOF_MARKER'
<!-- PARTIAL: REMEDIATION (DUAL-MODE WITH IDENTICAL ZERO-SHIFT STAGE) -->
{% if remediation %}
<section class="lab-card remediation-slot-wrapper" id="remediation-card">
  <div class="lab-card-header">
    <div class="lab-label-technical">
      TARGETED REMEDIATION // MODEL RESTRUCTURING
    </div>
    
    <!-- MODE SWITCHER (ALLOWS SWITCHING BETWEEN VIDEO AND STATIC NOTEBOOK CARD) -->
    <div class="remediation-mode-toggle" role="tablist" aria-label="Remediation Mode">
      {% if remediation.has_clip %}
      <button
        class="toggle-btn {% if remediation.kind == 'clip' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=clip"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        hx-indicator="#rem-indicator"
        role="tab"
        aria-selected="{% if remediation.kind == 'clip' %}true{% else %}false{% endif %}"
      >
        VIDEO CLIP
      </button>
      {% endif %}
      {% if remediation.has_svg %}
      <button
        class="toggle-btn {% if remediation.kind == 'svg' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=svg"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        hx-indicator="#rem-indicator"
        role="tab"
        aria-selected="{% if remediation.kind == 'svg' %}true{% else %}false{% endif %}"
      >
        ILLUSTRATION
      </button>
      {% endif %}
      <button
        class="toggle-btn {% if remediation.kind == 'card' %}active{% endif %}"
        hx-get="/remediation/{{ misconception_id }}?mode=card"
        hx-target="#remediation-slot"
        hx-swap="innerHTML"
        hx-indicator="#rem-indicator"
        role="tab"
        aria-selected="{% if remediation.kind == 'card' %}true{% else %}false{% endif %}"
      >
        TEXT MODEL
      </button>
    </div>
  </div>

  <div class="lab-card-body">
    <!-- IDENTICAL 380px VISUAL SLOT (ZERO LAYOUT JUMP) -->
    <div class="remediation-stage">
      {% if remediation.kind == 'svg' and remediation.svg %}
        <!-- RUNG 2: TARGETED ILLUSTRATION -->
        <figure class="remediation-illustration">
          {{ remediation.svg | safe }}
          <figcaption class="lab-meta-mono">
            GENERATED FOR THIS MISCONCEPTION &bull; NOT A SUMMARY OF THE DOCUMENT
          </figcaption>
        </figure>
      {% elif remediation.kind == 'clip' and remediation.clip_url %}
        <!-- MODE 1: VIDEO CLIP -->
        <video 
          class="remediation-video-player" 
          controls 
          preload="metadata" 
          poster=""
        >
          <source src="{{ remediation.clip_url }}" type="video/mp4">
          Your browser does not support the video tag.
        </video>
      {% else %}
        <!-- MODE 2: STATIC EXPLANATION CARD (ENGINEERING NOTEBOOK ANNOTATION) -->
        <div class="remediation-static-card">
          <!-- CURRENT / WRONG MODEL -->
          <div class="model-column wrong">
            <div class="model-header">
              <span class="model-badge wrong">YOUR CURRENT MODEL</span>
            </div>
            <p class="model-content-text">
              {{ remediation.wrong_model }}
            </p>
            <div class="lab-meta-mono" style="margin-top: var(--space-3); color: var(--state-diagnosed);">
              &cross; Divergent Premise
            </div>
          </div>

          <!-- RECONCILIATION DIVIDER -->
          <div class="model-connector-divider" title="Model reconciliation">
            &rarr;
          </div>

          <!-- TARGET / CORRECT MODEL -->
          <div class="model-column correct">
            <div class="model-header">
              <span class="model-badge correct">THE CORRECT MODEL</span>
            </div>
            <p class="model-content-text">
              {{ remediation.correct_model }}
            </p>
            <div class="lab-meta-mono" style="margin-top: var(--space-3); color: var(--state-mastered);">
              &check; Ground Truth Formulation
            </div>
          </div>
        </div>
      {% endif %}
    </div>

    <!-- ACTION FOOTER: RETEST ME -->
    <div class="lab-card-footer" style="margin-top: var(--space-6); padding: var(--space-4) 0 0 0; background: transparent; border-top: 1px solid var(--border-hairline);">
      <span class="lab-meta-mono" style="margin-right: auto;">STAGE: REMEDIATION DELIVERED &bull; READY TO RETEST</span>
      <button
        class="btn-lab btn-lab-accent"
        hx-post="/retest"
        hx-vals='{"misconception_id": "{{ misconception_id }}"}'
        hx-target="#retest-slot"
        hx-swap="innerHTML"
        hx-indicator="#retest-indicator"
      >
        Retest Me &rarr;
      </button>
    </div>
  </div>
</section>

{% endif %}

<!-- RETEST CONTAINER MOUNT POINT -->
<div id="retest-slot" style="margin-top: var(--space-6);"></div>
SLATE_EOF_MARKER

echo "  append loading CSS"
cat >> static/slate.css << 'SLATE_EOF_MARKER'

/* ---- Reusable loading states -------------------------------------- */
.slate-loading {
  display: none;
  align-items: center;
  gap: var(--space-4);
  padding: var(--space-4) var(--space-6);
  background: var(--bg-surface-inset);
  border: 1px dashed var(--border-graphite);
  border-radius: 2px;
  margin-top: var(--space-4);
}
.htmx-request .slate-loading,
.htmx-request.slate-loading,
.slate-loading.htmx-request { display: flex !important; }

.slate-loading .pulse-label {
  font-family: var(--font-mono); font-size: 0.7rem; font-weight: 700;
  letter-spacing: 0.12em; text-transform: uppercase; color: var(--ink-secondary);
  white-space: nowrap;
}
.slate-loading .pulse-track {
  position: relative; flex: 1; height: 2px; min-width: 80px;
  background: var(--border-subtle); overflow: hidden;
}
.slate-loading .pulse-indicator-node {
  position: absolute; top: -3px; width: 8px; height: 8px; border-radius: 50%;
  background: var(--accent-electric); animation: slateScan 1.25s ease-in-out infinite;
}
@keyframes slateScan { 0% { left: 0; } 50% { left: calc(100% - 8px); } 100% { left: 0; } }

/* ---- Full-screen ingestion overlay -------------------------------- */
#ingest-overlay {
  position: fixed; inset: 0; z-index: 9999; display: none;
  flex-direction: column; align-items: center; justify-content: center;
  gap: var(--space-5); background: var(--bg-page);
}
#ingest-overlay.visible { display: flex; }
#ingest-overlay .ingest-doc {
  font-family: var(--font-mono); font-size: 0.72rem; letter-spacing: 0.1em;
  color: var(--ink-muted); text-transform: uppercase;
}
#ingest-overlay .ingest-stage {
  font-size: 1.15rem; color: var(--ink-primary); min-height: 1.6em;
  text-align: center; max-width: 34ch;
}
#ingest-overlay .ingest-bar {
  width: 260px; height: 2px; background: var(--border-subtle);
  position: relative; overflow: hidden;
}
#ingest-overlay .ingest-bar span {
  position: absolute; top: 0; height: 100%; width: 40%;
  background: var(--accent-electric); animation: slateSweep 1.4s ease-in-out infinite;
}
@keyframes slateSweep { 0% { left: -40%; } 100% { left: 100%; } }
#ingest-overlay .ingest-note {
  font-family: var(--font-mono); font-size: 0.65rem; color: var(--ink-muted);
}
.upload-selected-file {
  margin-top: var(--space-3); font-family: var(--font-mono);
  font-size: 0.72rem; color: var(--accent-electric);
}
SLATE_EOF_MARKER

echo ""
echo "==> done. Hard-refresh the browser (Cmd+Shift+R) to pick up the CSS."