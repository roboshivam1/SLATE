/**
 * SLATE LANDING PAGE — INTERACTIVE WIDGETS & LATTICE TELEMETRY INSPECTOR
 */
(() => {
  'use strict';

  // 1. 5-State Glass Mastery Lattice Inspector Drawer
  const stateCards = document.querySelectorAll('.mastery-glass-card');
  const telemetryDrawer = document.getElementById('telemetry-drawer');

  const STATE_TELEMETRY = {
    unseen: {
      title: "STATE 01 // UNSEEN TELEMETRY",
      entropy: "HIGH (1.00)",
      transferScore: "0.0%",
      retention: "N/A",
      vulnerability: "Prerequisite Concept Nodes Pending Ingestion"
    },
    shaky: {
      title: "STATE 02 // SHAKY TELEMETRY",
      entropy: "MODERATE (0.68)",
      transferScore: "42.5%",
      retention: "2.4 Days",
      vulnerability: "Heuristic Guessing & Superficial Formula Pattern Matching"
    },
    diagnosed: {
      title: "STATE 03 // DIAGNOSED TELEMETRY",
      entropy: "ISOLATED (0.85)",
      transferScore: "18.0%",
      retention: "1.1 Days",
      vulnerability: "Chain Rule Outer Composition Treated as Multiplication"
    },
    improving: {
      title: "STATE 04 // IMPROVING TELEMETRY",
      entropy: "DECREASING (0.24)",
      transferScore: "78.2%",
      retention: "14.8 Days",
      vulnerability: "Active Schema Remediation & Near-Transfer Practice"
    },
    mastered: {
      title: "STATE 05 // MASTERED TELEMETRY",
      entropy: "MINIMAL (0.02)",
      transferScore: "99.4%",
      retention: "Permanent (Long-Term Lattice)",
      vulnerability: "None — Deep Intuitive & Mathematical Model Stabilized"
    }
  };

  stateCards.forEach(card => {
    card.addEventListener('click', () => {
      stateCards.forEach(c => c.classList.remove('active-state'));
      card.classList.add('active-state');

      const stateKey = card.getAttribute('data-state');
      const data = STATE_TELEMETRY[stateKey];

      if (telemetryDrawer && data) {
        telemetryDrawer.querySelector('.telemetry-title').textContent = data.title;
        telemetryDrawer.querySelector('#tel-entropy').textContent = data.entropy;
        telemetryDrawer.querySelector('#tel-transfer').textContent = data.transferScore;
        telemetryDrawer.querySelector('#tel-retention').textContent = data.retention;
        telemetryDrawer.querySelector('#tel-vulnerability').textContent = data.vulnerability;
        
        telemetryDrawer.classList.add('active');
        telemetryDrawer.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      }
    });
  });

  // 2. Hero WHY Target Mark Scanner Trigger
  const whyMark = document.getElementById('why-target-mark');
  const stage = document.querySelector('.hero-glass-stage');

  if (whyMark && stage) {
    whyMark.addEventListener('click', () => {
      stage.style.transition = 'transform 0.4s cubic-bezier(0.16, 1, 0.3, 1)';
      stage.style.transform = 'scale(1.04) rotateX(4deg)';
      
      const particles = document.querySelectorAll('.particle');
      particles.forEach(p => {
        p.style.transform = 'scale(2.5)';
        p.style.background = '#7DD3FC';
      });

      setTimeout(() => {
        stage.style.transform = '';
        particles.forEach(p => {
          p.style.transform = '';
          p.style.background = '';
        });
      }, 600);
    });
  }
})();
