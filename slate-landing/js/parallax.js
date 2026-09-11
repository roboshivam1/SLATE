/**
 * SLATE LANDING PAGE — ISOLATED 3D GLASS DECK PARALLAX & FOCUS ORCHESTRATION
 * Smooth spring-like lerped interpolation via requestAnimationFrame.
 * Independent panel response multipliers: Confusion (0.4x), Diagnosis (0.7x), Clarity (1.0x).
 * Luxury 500-800ms Focus -> Depth -> Dimension on card hover.
 */
(() => {
  'use strict';

  // Respect user preference for reduced motion
  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (prefersReducedMotion) return;

  const stage = document.querySelector('.hero-glass-stage');
  const panels = document.querySelectorAll('.glass-panel-wrapper');
  if (!stage || panels.length === 0) return;

  // Parallax physics coordinates
  let targetX = 0;
  let targetY = 0;
  let currentX = 0;
  let currentY = 0;
  let rafId = null;

  // Calculate mouse displacement relative to hero deck center
  const onPointerMove = (e) => {
    const rect = stage.getBoundingClientRect();
    const stageCenterX = rect.left + rect.width / 2;
    const stageCenterY = rect.top + rect.height / 2;

    // Normalized offset (-1 to +1) scaled to maximum translation
    const normX = Math.max(-1, Math.min(1, (e.clientX - stageCenterX) / (window.innerWidth / 2)));
    const normY = Math.max(-1, Math.min(1, (e.clientY - stageCenterY) / (window.innerHeight / 2)));

    targetX = normX * 36; // max ~36px translation for clarity
    targetY = normY * 30; // max ~30px vertical

    if (!rafId) {
      rafId = requestAnimationFrame(updateParallaxLoop);
    }
  };

  const updateParallaxLoop = () => {
    // Smooth lerp for buttery organic spring-like movement
    currentX += (targetX - currentX) * 0.07;
    currentY += (targetY - currentY) * 0.07;

    // Deck rotation angles (mouse left -> rotates left, mouse up -> tilts up)
    const rotX = (-currentY * 0.18).toFixed(2);
    const rotY = (currentX * 0.22).toFixed(2);

    stage.style.setProperty('--deck-rot-x', `${rotX}deg`);
    stage.style.setProperty('--deck-rot-y', `${rotY}deg`);

    // Independent depth intensities
    stage.style.setProperty('--par-confusion-x', `${(currentX * 0.4).toFixed(2)}px`);
    stage.style.setProperty('--par-confusion-y', `${(currentY * 0.4).toFixed(2)}px`);

    stage.style.setProperty('--par-diagnosis-x', `${(currentX * 0.7).toFixed(2)}px`);
    stage.style.setProperty('--par-diagnosis-y', `${(currentY * 0.7).toFixed(2)}px`);

    stage.style.setProperty('--par-clarity-x', `${(currentX * 1.0).toFixed(2)}px`);
    stage.style.setProperty('--par-clarity-y', `${(currentY * 1.0).toFixed(2)}px`);

    // Continue while movement persists
    if (Math.abs(targetX - currentX) > 0.02 || Math.abs(targetY - currentY) > 0.02) {
      rafId = requestAnimationFrame(updateParallaxLoop);
    } else {
      rafId = null;
    }
  };

  window.addEventListener('pointermove', onPointerMove, { passive: true });

  // Individual Card Hover Physics
  panels.forEach(panel => {
    panel.addEventListener('pointerenter', () => {
      stage.classList.add('deck-has-focus');
      panel.classList.add('is-focused');

      panels.forEach(other => {
        if (other !== panel) {
          other.classList.add('is-defocused');
        }
      });
    });

    panel.addEventListener('pointerleave', () => {
      stage.classList.remove('deck-has-focus');
      panel.classList.remove('is-focused');

      panels.forEach(other => {
        other.classList.remove('is-defocused');
      });
    });
  });
})();
