/**
 * Behavior tracking hook.
 * Tracks pointer, scroll, touch, section attention, text selection, and tab visibility.
 * Sends periodic snapshots to server.
 */
export function startBehaviorTracking(hook) {
  const state = {
    inputDevice: "unknown",
    lastPointerTime: Date.now(),
    lastScrollTime: Date.now(),
    scrollVelocity: 0,
    scrollY: window.scrollY,
    currentSection: null,
    sectionDwells: {},
    textSelections: [],
    tabAwayCount: 0,
    tabAwayTotalMs: 0,
    tabAwayStart: null,
    viewportFocused: true,
    attentionPattern: "browsing",
  };

  // Section attention via IntersectionObserver
  const sections = document.querySelectorAll("[data-section]");
  const sectionVisibility = {};

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const id = entry.target.dataset.section;
        sectionVisibility[id] = entry.intersectionRatio >= 0.5;

        if (entry.intersectionRatio >= 0.5) {
          state.currentSection = id;
          if (!state.sectionDwells[id]) {
            state.sectionDwells[id] = { totalMs: 0, entries: 0, lastEnter: Date.now() };
          }
          if (!state.sectionDwells[id].lastEnter) {
            state.sectionDwells[id].lastEnter = Date.now();
            state.sectionDwells[id].entries++;
          }
        } else if (state.sectionDwells[id]?.lastEnter) {
          state.sectionDwells[id].totalMs += Date.now() - state.sectionDwells[id].lastEnter;
          state.sectionDwells[id].lastEnter = null;
        }
      }
    },
    { threshold: [0, 0.25, 0.5, 0.75, 1.0] }
  );

  sections.forEach((s) => observer.observe(s));

  // Pointer tracking (debounced — only update state, don't push)
  let pointerThrottle = 0;
  document.addEventListener(
    "pointermove",
    (e) => {
      const now = Date.now();
      if (now - pointerThrottle < 100) return;
      pointerThrottle = now;

      if (state.inputDevice === "unknown") {
        state.inputDevice = e.pointerType || "mouse";
      }
      state.lastPointerTime = now;
    },
    { passive: true }
  );

  // Scroll tracking
  let scrollThrottle = 0;
  window.addEventListener(
    "scroll",
    () => {
      const now = Date.now();
      if (now - scrollThrottle < 100) return;

      const dt = now - state.lastScrollTime;
      const dy = Math.abs(window.scrollY - state.scrollY);
      state.scrollVelocity = dt > 0 ? Math.round((dy / dt) * 1000) : 0;
      state.scrollY = window.scrollY;
      state.lastScrollTime = now;
      scrollThrottle = now;
    },
    { passive: true }
  );

  // Text selection
  document.addEventListener("selectionchange", () => {
    const text = document.getSelection()?.toString()?.trim();
    if (text && text.length > 2 && text.length < 500) {
      // Avoid duplicates
      if (!state.textSelections.some((s) => s.text === text)) {
        state.textSelections.push({ text, at: Date.now() });
        if (state.textSelections.length > 10) state.textSelections.shift();
      }
    }
  });

  // Tab visibility
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      state.viewportFocused = false;
      state.tabAwayStart = Date.now();
      state.tabAwayCount++;
    } else {
      state.viewportFocused = true;
      if (state.tabAwayStart) {
        state.tabAwayTotalMs += Date.now() - state.tabAwayStart;
        state.tabAwayStart = null;
      }
    }
  });

  // Periodic snapshot (every 2s)
  setInterval(() => {
    const now = Date.now();

    // Update dwell times for visible sections
    for (const [id, vis] of Object.entries(sectionVisibility)) {
      if (vis && state.sectionDwells[id]?.lastEnter) {
        state.sectionDwells[id].totalMs += now - state.sectionDwells[id].lastEnter;
        state.sectionDwells[id].lastEnter = now;
      }
    }

    // Classify attention
    const idleSeconds = (now - Math.max(state.lastPointerTime, state.lastScrollTime)) / 1000;

    if (idleSeconds > 5) {
      state.attentionPattern = "idle";
    } else if (state.scrollVelocity > 2000) {
      state.attentionPattern = "scanning";
    } else if (
      state.scrollVelocity < 200 &&
      state.currentSection &&
      (state.sectionDwells[state.currentSection]?.totalMs || 0) > 3000
    ) {
      state.attentionPattern = "reading";
    } else {
      state.attentionPattern = "browsing";
    }

    // Build snapshot with serializable dwell data
    const dwells = {};
    for (const [id, d] of Object.entries(state.sectionDwells)) {
      dwells[id] = { totalMs: d.totalMs, entries: d.entries };
    }

    hook.pushEvent("behavior", {
      attentionPattern: state.attentionPattern,
      currentSection: state.currentSection,
      inputDevice: state.inputDevice,
      scrollVelocity: state.scrollVelocity,
      idleSeconds: Math.round(idleSeconds),
      tabAwayCount: state.tabAwayCount,
      tabAwayTotalMs: state.tabAwayTotalMs,
      textSelections: state.textSelections.slice(-5),
      viewportFocused: state.viewportFocused,
      sectionDwells: dwells,
    });
  }, 2000);
}
