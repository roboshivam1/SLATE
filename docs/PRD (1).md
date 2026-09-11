# SLATE — Product Requirements

**MUJ HackX 4.0 · Edtech PS #7 · Round 2 (14 hours)**

> Working name. Pairs with CHALKDUST, which is the rendering engine underneath.
> Rename freely — nothing in the code depends on it.

---

## 1. The one-sentence pitch

> NotebookLM makes a video about your PDF. SLATE makes a video about your mistake.

---

## 2. Why this framing, and not the obvious one

Google's NotebookLM already ships every surface-level feature listed in PS #7:
source ingestion, mind maps, infographics, slide decks, cinematic video overviews,
flashcards with mastery tracking, quizzes with explain-why-you-were-wrong, and a
"Learning Guide" socratic mode.

A team that builds `upload → concept map → summary → quiz → study plan` is demoing
a worse NotebookLM to judges who use NotebookLM. That is the trap in this problem
statement, and it is why the statement looks easy.

The escape is a different unit of state.

| | NotebookLM | SLATE |
|---|---|---|
| Unit of state | the **notebook** | the **learner** |
| Tracks | which cards you got right | which *wrong mental model* you hold |
| Assessment | recognition (MCQ, flashcards) | explanation (free response, in your own words) |
| Visuals | stylistic summary of the whole source | targeted at one diagnosed misconception |
| Loop | generate → consume | diagnose → remediate → retest → update |

NotebookLM is a **comprehension** tool: help me understand this document.
SLATE is a **mastery** system: get me to the point where I don't need the document.

That distinction is the entire product. Every scope decision below follows from it.

---

## 3. The loop (this *is* the product)

```
upload PDF
   └─> concepts extracted, each with a closed list of likely misconceptions
        └─> student is asked to explain a concept in their own words
             └─> answer classified against that closed list
                  └─> a specific misconception is NAMED, with the evidence span
                       └─> targeted remediation is shown (animation, or fallback card)
                            └─> retest on questions aimed at that exact gap
                                 └─> learner model updates, concept map recolours
```

If a judge sees this loop run end to end on one concept, the demo has succeeded.
Nothing outside this loop earns a point.

---

## 4. Scope

### MUST — without these there is no demo

| # | Feature | Why it's must |
|---|---|---|
| F1 | Upload a PDF, extract text | Entry point |
| F2 | Extract concepts, each with a **closed list** of candidate misconceptions | Makes the whole system deterministic and cacheable — see ARCHITECTURE §3 |
| F3 | Ask a free-response "explain this in your own words" question | The differentiator vs. MCQ |
| F4 | Classify the answer to a `misconception_id` + confidence + evidence span | The core technical claim |
| F5 | Show targeted remediation for that misconception | The payoff moment |
| F6 | Generate retest questions aimed at the diagnosed gap | Closes the loop |
| F7 | Persistent learner model, visible as a mastery-coloured concept map | Proves "unit of state = learner" |

### SHOULD — build if ahead of schedule

| # | Feature | Cost |
|---|---|---|
| S1 | CHALKDUST-rendered animation as the remediation artifact (F5 upgrade) | ~3h — high value, see risk note |
| S2 | Evidence span highlighted inside the student's own typed answer | ~30m — cheap, very persuasive on screen |
| S3 | "Route me back to the source" — jump to the page the concept came from | ~30m |
| S4 | Spoken answers via Groq Whisper (code already exists in JARVIS MK3) | ~30m — strong demo beat |

### WON'T — explicitly out of scope, and we say so in the pitch

Auth and accounts · multi-document notebooks · file types beyond PDF · flashcards ·
mind maps · audio overviews · study calendar or scheduler · spaced repetition ·
mobile layout · multi-user · deployment to a VPS.

> Saying "we deliberately built one loop completely instead of six features
> halfway" is a stronger answer than a feature grid. Own the cuts.

---

## 5. Demo narrative

Four minutes, in this order:

1. **Frame the problem** (20s) — "Every AI study tool tells you *what* you got wrong. None of them tell you *why you think that way*."
2. **Upload** (20s) — pre-seeded document, one click. Do not burn demo time on ingestion.
3. **Explain out loud / in writing** (40s) — give a deliberately wrong answer that carries a *classic* misconception.
4. **The diagnosis** (40s) — system names the mental model and points at the exact phrase in the answer that revealed it. **This is the moment.** Pause here.
5. **The remediation** (60s) — the targeted animation plays.
6. **Retest + map update** (40s) — answer correctly, watch the concept node change colour.
7. **The NotebookLM line** (20s) — deliver §1 verbatim. Expect the question; have it pre-answered.

Rehearse this twice. Budget is in ROADMAP M7.

---

## 6. Risks and the pre-decided response

| Risk | Response |
|---|---|
| Manim render is slow / breaks on the laptop mid-demo | Remediation **always** falls back to a static explanation card. Never on the critical path. See ARCHITECTURE §5. |
| LLM classifies to an open-ended misconception we have no content for | Classifier is constrained to the closed list + an `unknown` escape hatch that routes to generic remediation. |
| Judge uploads their own PDF live | Supported, but slow. Have the pre-seeded doc ready; offer the live upload as a *stretch* if time permits. |
| We run out of hours | Every milestone in ROADMAP leaves a working, demoable system. Stop wherever the clock stops. |
| Laptop dies / wifi dies | Everything runs locally. Only the LLM API needs network. Cache every LLM response so a rehearsed path survives a dead connection. |

---

## 7. Success criteria

- The loop in §3 runs end to end, on stage, without a restart.
- A judge can articulate the difference from NotebookLM after watching.
- The learner model visibly changes state during the demo.
