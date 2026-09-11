/**
 * SLATE LANDING PAGE — NATIVE SCROLL OBSERVERS & TRIGGERS
 */
(() => {
  'use strict';

  // 1. Navbar Glass Blur on Scroll
  const navbar = document.getElementById('navbar');
  if (navbar) {
    const handleScroll = () => {
      if (window.scrollY > 30) {
        navbar.classList.add('scrolled');
      } else {
        navbar.classList.remove('scrolled');
      }
    };
    window.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll();
  }

  // 2. Generic Reveal Elements (Fade up)
  const revealElements = document.querySelectorAll('.reveal-fade-up');
  if ('IntersectionObserver' in window && revealElements.length > 0) {
    const revealObserver = new IntersectionObserver((entries, observer) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15, rootMargin: '0px 0px -50px 0px' });

    revealElements.forEach(el => revealObserver.observe(el));
  } else {
    revealElements.forEach(el => el.classList.add('visible'));
  }

  // 3. The SLATE Loop Timeline Activation
  const loopSection = document.getElementById('loop');
  const loopSteps = document.querySelectorAll('.loop-step');
  const loopProgressBar = document.getElementById('loop-progress-bar');

  if (loopSection && 'IntersectionObserver' in window) {
    const loopObserver = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          loopSteps.forEach((step, index) => {
            setTimeout(() => {
              step.classList.add('active');
              if (loopProgressBar) {
                loopProgressBar.style.width = `${((index + 1) / loopSteps.length) * 100}%`;
              }
            }, index * 260);
          });
          loopObserver.unobserve(loopSection);
        }
      });
    }, { threshold: 0.25 });

    loopObserver.observe(loopSection);
  }

  // 4. Diagnosis Section: Evidence Span Highlighting & Diagnostic Card Reveal
  const diagnosisSection = document.getElementById('diagnosis');
  const evidenceSpan = document.getElementById('evidence-span');
  const diagnosticCard = document.getElementById('diagnostic-card');

  if (diagnosisSection && 'IntersectionObserver' in window) {
    const diagnosisObserver = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          setTimeout(() => {
            if (evidenceSpan) evidenceSpan.classList.add('highlighted');
          }, 500);

          setTimeout(() => {
            if (diagnosticCard) diagnosticCard.classList.add('revealed');
          }, 950);

          diagnosisObserver.unobserve(diagnosisSection);
        }
      });
    }, { threshold: 0.25 });

    diagnosisObserver.observe(diagnosisSection);
  }
})();
