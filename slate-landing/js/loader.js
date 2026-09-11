/**
 * SLATE LANDING PAGE — ANIMATED LOGO SPLASH & REDIRECT CONTROL
 * Animates progress, streams status logs, and smoothly redirects to index.html.
 */
(() => {
  'use strict';

  const progressFill = document.getElementById('loader-progress-fill');
  const percentageText = document.getElementById('loader-percentage');
  const logText = document.getElementById('loader-log-text');
  const loaderPage = document.getElementById('loader-page');

  if (!progressFill || !percentageText || !logText) return;

  const LOG_STEPS = [
    { at: 10, msg: "INITIALIZING COGNITIVE ENGINE V2.4..." },
    { at: 32, msg: "CALIBRATING SCHEMA RECONSTRUCTION LATTICE..." },
    { at: 58, msg: "INGESTING MATHEMATICAL VECTOR MANIFOLDS..." },
    { at: 80, msg: "SYNCHRONIZING 5 MASTERY STATES..." },
    { at: 96, msg: "SYSTEM NOMINAL // ENTERING SLATE..." }
  ];

  let currentProgress = 0;
  const durationMs = 2600; // 2.6 second initialization sequence
  const intervalMs = 25;
  const increment = 100 / (durationMs / intervalMs);

  const timer = setInterval(() => {
    currentProgress += increment;

    if (currentProgress >= 100) {
      currentProgress = 100;
      clearInterval(timer);
      onLoadingComplete();
    }

    // Update Bar & Counter
    progressFill.style.width = `${currentProgress.toFixed(1)}%`;
    percentageText.textContent = `${Math.floor(currentProgress)}%`;

    // Update Status Log Message
    for (let i = LOG_STEPS.length - 1; i >= 0; i--) {
      if (currentProgress >= LOG_STEPS[i].at) {
        logText.textContent = LOG_STEPS[i].msg;
        break;
      }
    }
  }, intervalMs);

  function onLoadingComplete() {
    setTimeout(() => {
      if (loaderPage) {
        loaderPage.classList.add('fade-out');
      }

      // Check if we are on standalone loader.html vs embedded in index.html
      setTimeout(() => {
        if (window.location.pathname.endsWith('loader.html') || window.location.pathname.endsWith('splash.html')) {
          window.location.href = 'index.html?intro=complete';
        } else if (loaderPage) {
          loaderPage.style.display = 'none';
        }
      }, 550);
    }, 250);
  }
})();
