# SLATE — Standalone Marketing Landing Page
*Cognitive Mastery System // Fluid Glassmorphism & Cursive Editorial Design*

This is a standalone marketing and landing experience for **SLATE**, featuring 3D spring glass parallax, fluid frosted metrics cards, elegant cursive editorial typography, and an interactive diagnostic simulation engine.

## Core Features & Design Highlights
- **Cursive Editorial Typography**: Flowing, expressive Google Fonts (`Instrument Serif` & `Playfair Display` in italics) for **"WHY"** and the subhead paragraph below it.
- **Fluid Frosted Glass Architecture**: Heavy `backdrop-filter: blur(20px)`, translucent gradients, specular top border reflections, and liquid ambient glow orbs drifting in the background.
- **Fluid Glass Metrics Cards**: Metric strip upgraded from plain text into floating liquid frosted glass pills with specular borders and cyan ambient illumination.
- **Interactive Inspector Simulation (`demo-modal.js`)**: Interactive problem tabs (#1 Chain Rule, #2 Integration by Parts, #3 Product Rule) with real-time log typing animation, misconception flags, and repair schema activations.
- **5-State Knowledge Lattice Inspector (`interactive-widgets.js`)**: Clickable cards (Unseen, Shaky, Diagnosed, Improving, Mastered) triggering live telemetry stats (Schema Entropy, Transfer Score, Retention Half-life).

## File Structure
```text
slate-landing/
├── index.html              # HTML5 structure with cursive typography & modal markup
├── styles/
│   ├── main.css            # Typography tokens, ambient glow orbs, base layout
│   ├── glass.css           # Glassmorphism engine, 3D stage deck, fluid metrics cards
│   ├── animations.css      # Floating physics, micro-particles, scroll keyframes
│   └── responsive.css      # Responsive breakpoints (desktop, tablet, mobile)
├── js/
│   ├── parallax.js         # 3D spring deck lerped mouse parallax
│   ├── scroll-triggers.js  # Native IntersectionObserver scroll triggers
│   ├── demo-modal.js       # Live diagnostic simulation engine with problem switcher
│   └── interactive-widgets.js # 5-State Telemetry drawer & hero target triggers
└── README.md
```

## How to Preview / Run
Run using any local static file server:

### Python 3:
```bash
cd slate-landing
python -m http.server 8080
```
Open `http://localhost:8080` in your browser.
