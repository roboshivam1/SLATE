/**
 * SLATE LANDING PAGE — INTERACTIVE DIAGNOSTIC SIMULATION INSPECTOR MODAL
 * Manages live stream logs, problem switcher tabs, real-time typing simulation,
 * and schema repair card activations.
 */
(() => {
  'use strict';

  const modal = document.getElementById('demo-modal');
  const demoButtons = document.querySelectorAll('.btn-watch-demo');
  const closeBtn = document.querySelector('.modal-close-btn');
  const streamLog = document.getElementById('demo-stream-log');
  const diagnosticBanner = document.getElementById('demo-diagnostic-banner');
  const remediationCard = document.getElementById('demo-remediation-card');
  const problemTabs = document.querySelectorAll('.demo-problem-tab');

  if (!modal || !streamLog) return;

  // Diagnostic Challenge Scenarios
  const CHALLENGES = {
    chainRule: {
      title: "Evaluate d/dx [ sin(x²) ] and justify each step.",
      reasoning: "I differentiated sin(x²) to cos(x²). Since x² stays inside, I didn't need to do anything to x².",
      logs: [
        { type: 'info', text: '[INTAKE] Receiving natural language reasoning string...' },
        { type: 'info', text: '[TOKENIZER] Parsed 2 symbols: sin(u) where u = x².' },
        { type: 'warning', text: '[PARSER] Outer derivative computed: cos(x²). Inner differential missing!' },
        { type: 'error', text: '⚠ MISCONCEPTION DETECTED: Argument Differentiation Omission (#CHAIN_INNER_OMIT)' }
      ],
      banner: {
        title: "● MISCONCEPTION ISOLATED: ARGUMENT DIFFERENTIATION OMISSION",
        desc: "Outer cosine computed correctly, but inner quadratic differential 2x was discarded rather than composed."
      },
      repair: {
        title: "✓ TARGET REPAIR SCHEMA ACTIVATED",
        formula: "d/dx [ sin(u) ] = cos(u) · (du/dx) ⟹ cos(x²) · 2x = 2x · cos(x²)"
      }
    },
    integrationByParts: {
      title: "Evaluate ∫ x · cos(x) dx using integration techniques.",
      reasoning: "I took the integral of x which is x²/2 and integral of cos(x) which is sin(x) and multiplied them to get (x²/2)sin(x).",
      logs: [
        { type: 'info', text: '[INTAKE] Receiving calculus reasoning submission...' },
        { type: 'info', text: '[TOKENIZER] Identified product term: f(x) = x, g(x) = cos(x).' },
        { type: 'warning', text: '[PARSER] Student applied term-by-term integration rule: ∫(f·g) = ∫f · ∫g.' },
        { type: 'error', text: '⚠ MISCONCEPTION DETECTED: Linear Multiplicative Integration Fallacy (#PARTS_PRODUCT_TRAP)' }
      ],
      banner: {
        title: "● MISCONCEPTION ISOLATED: PRODUCT INTEGRATION FALLACY",
        desc: "Integration is not distributive over multiplication. Product requires Integration by Parts schema: ∫ u dv = uv - ∫ v du."
      },
      repair: {
        title: "✓ TARGET REPAIR SCHEMA ACTIVATED",
        formula: "Let u = x, dv = cos(x)dx ⟹ du = dx, v = sin(x) ⟹ x·sin(x) - ∫ sin(x)dx = x·sin(x) + cos(x) + C"
      }
    },
    productRule: {
      title: "Evaluate d/dx [ x³ · ln(x) ].",
      reasoning: "The derivative of x³ is 3x² and derivative of ln(x) is 1/x, so the answer is 3x² · (1/x) = 3x.",
      logs: [
        { type: 'info', text: '[INTAKE] Ingesting product rule reasoning steps...' },
        { type: 'info', text: '[PARSER] Decomposed factors: u = x³, v = ln(x).' },
        { type: 'warning', text: '[PARSER] Naive derivative multiplication detected: (u)' · (v)' without cross terms.' },
        { type: 'error', text: '⚠ MISCONCEPTION DETECTED: Decoupled Product Derivative (#PRODUCT_DIRECT_MULT)' }
      ],
      banner: {
        title: "● MISCONCEPTION ISOLATED: DECOUPLED PRODUCT DERIVATIVE",
        desc: "Student evaluated factor rates independently without accounting for cross-variable rate coupling."
      },
      repair: {
        title: "✓ TARGET REPAIR SCHEMA ACTIVATED",
        formula: "d/dx [ u · v ] = u'v + uv' ⟹ (3x²)ln(x) + x³(1/x) = 3x² ln(x) + x² = x²(3 ln(x) + 1)"
      }
    }
  };

  let currentKey = 'chainRule';
  let timerId = null;

  // Open Modal
  const openModal = () => {
    modal.classList.add('active');
    document.body.style.overflow = 'hidden';
    runDiagnosticSimulation(currentKey);
  };

  // Close Modal
  const closeModal = () => {
    modal.classList.remove('active');
    document.body.style.overflow = '';
    if (timerId) clearTimeout(timerId);
  };

  demoButtons.forEach(btn => btn.addEventListener('click', (e) => {
    e.preventDefault();
    openModal();
  }));

  if (closeBtn) closeBtn.addEventListener('click', closeModal);

  modal.addEventListener('click', (e) => {
    if (e.target === modal) closeModal();
  });

  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && modal.classList.contains('active')) {
      closeModal();
    }
  });

  // Problem Switcher Tabs
  problemTabs.forEach(tab => {
    tab.addEventListener('click', () => {
      problemTabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      currentKey = tab.getAttribute('data-problem');
      runDiagnosticSimulation(currentKey);
    });
  });

  // Run Real-Time Stream Simulation
  function runDiagnosticSimulation(key) {
    if (timerId) clearTimeout(timerId);

    const challenge = CHALLENGES[key] || CHALLENGES.chainRule;

    // Reset Container Views
    streamLog.innerHTML = '';
    if (diagnosticBanner) diagnosticBanner.style.display = 'none';
    if (remediationCard) remediationCard.style.display = 'none';

    // Update Problem Context display if present
    const promptText = document.getElementById('demo-problem-prompt');
    if (promptText) promptText.textContent = challenge.title;

    const studentReasoningQuote = document.getElementById('demo-student-reasoning');
    if (studentReasoningQuote) studentReasoningQuote.textContent = `"${challenge.reasoning}"`;

    let stepIndex = 0;

    function renderNextLog() {
      if (stepIndex < challenge.logs.length) {
        const item = challenge.logs[stepIndex];
        const line = document.createElement('div');
        line.className = `stream-line stream-${item.type}`;
        line.style.opacity = '0';
        line.style.transform = 'translateY(6px)';
        line.style.transition = 'all 0.25s ease';
        line.textContent = item.text;
        
        streamLog.appendChild(line);

        setTimeout(() => {
          line.style.opacity = '1';
          line.style.transform = 'translateY(0)';
          streamLog.scrollTop = streamLog.scrollHeight;
        }, 30);

        stepIndex++;
        timerId = setTimeout(renderNextLog, 650);
      } else {
        // Show Diagnostic Banner
        setTimeout(() => {
          if (diagnosticBanner) {
            diagnosticBanner.querySelector('.diag-banner-title').textContent = challenge.banner.title;
            diagnosticBanner.querySelector('.diag-banner-desc').textContent = challenge.banner.desc;
            diagnosticBanner.style.display = 'block';
            diagnosticBanner.style.animation = 'fadeIn 0.4s ease';
          }
        }, 300);

        // Show Remediation Card
        setTimeout(() => {
          if (remediationCard) {
            remediationCard.querySelector('.remed-title').textContent = challenge.repair.title;
            remediationCard.querySelector('.remed-formula').textContent = challenge.repair.formula;
            remediationCard.style.display = 'block';
            remediationCard.style.animation = 'fadeIn 0.4s ease';
          }
        }, 850);
      }
    }

    renderNextLog();
  }

  // Global trigger for manual rerun button inside modal
  window.rerunDemoSimulation = () => {
    runDiagnosticSimulation(currentKey);
  };
})();
