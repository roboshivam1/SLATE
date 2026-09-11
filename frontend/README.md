# SLATE — Intelligent Learning Lab Frontend

Frontend implementation for **SLATE**, an AI-native learning workspace built around the *"Intelligent Learning Lab"* visual aesthetic (**Graphite + Paper + Ink + One Electric Accent**).

---

## Architectural Principles

- **No generic AI tropes**: Strictly zero purple gradients, neon lasers, floating 3D blobs, or generic chatbot layouts.
- **Tech Stack**:
  - Jinja2 templates (semantic HTML)
  - Vendored HTMX 2.0.4 (no npm, no node build pipeline, no client-side routing)
  - Single handwritten stylesheet (`static/slate.css`)
  - Server owns all state

---

## Directory Structure

```
frontend/
├── app.py                      # Standalone interactive server for demonstration
├── templates/
│   ├── base.html               # Shell with SVG background system & persistent header
│   ├── upload.html             # Document intake & curriculum selection
│   ├── study.html              # Main laboratory workbench
│   └── partials/
│       ├── question.html       # Prompt & student explanation input
│       ├── diagnosis.html      # Hero reveal: <mark> evidence span & cognitive analysis
│       ├── remediation.html    # Dual-mode zero-shift slot (video & static notebook)
│       ├── retest.html         # Retest evaluation & out-of-band mastery update
│       └── concept_map.html    # Clean CSS grid with 5 scientific mastery states
└── static/
    ├── slate.css               # Precision stylesheet with dual theme support
    ├── htmx.min.js             # Vendored HTMX
    └── clips/
        └── chain_rule_as_product.mp4
```

---

## Background Visual System (CSS & SVG)

1. **Notebook Grid**: Micro-drifting dual-pitch drafting paper grid.
2. **Diagnostic Trace**: SVG perimeter bracket calipers and self-drawing mathematical curves.
3. **Floating Concept Nodes**: Abstract geometric nodes drifting in distant background.
4. **Thinking Pulse**: Precision indicator (`ANALYZING RESPONSE ───────●──────`) tied to `hx-indicator`.
5. **Mastery Flow**: Scientific instrument state transition animations on concept cards.
6. **Diagnosis Reveal**: Animated teacher's yellow felt highlighter on the exact evidence span within student text.

---

## Dual Theme Support

- **Light Mode (Default)**: Authentic technical drafting paper (`#F8F9FA` / `#FFFFFF`) with crisp graphite lines and carbon ink.
- **Dark Mode**: Engineering charcoal lab console (`#111315` / `#1B1E22`).
- **Toggle**: Switched via the button on the top-right corner of the workspace header (`#theme-toggle-btn`) with zero-flicker `localStorage` persistence.

---

## Running the Standalone Frontend

```bash
cd frontend
python app.py
```
Open `http://localhost:5000` to interact with the full learning loop.
