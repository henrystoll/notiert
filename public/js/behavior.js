/**
 * behavior.js – Continuous behavioral tracking
 * Pointer, scroll, touch, attention, selection, visibility, idle detection.
 */

export function createBehaviorTracker() {
  const state = {
    pointerType: 'unknown',
    lastPointerX: 0,
    lastPointerY: 0,
    scrollY: 0,
    scrollVelocity: 0,
    sections: {},        // { sectionId: { dwellTime, entryCount, visible } }
    currentSection: null,
    attentionPattern: 'idle', // idle | scanning | reading | browsing
    tabAwayCount: 0,
    tabAwayDuration: 0,
    textSelections: [],
    idleTime: 0,
    lastActivity: Date.now(),
    focused: true,
    _tabAwayStart: null,
  };

  let lastScrollY = window.scrollY;
  let lastScrollTime = Date.now();

  // ---- Pointer tracking ----
  function onPointerMove(e) {
    state.pointerType = e.pointerType || 'mouse';
    state.lastPointerX = e.clientX;
    state.lastPointerY = e.clientY;
    state.lastActivity = Date.now();
  }

  // ---- Scroll tracking ----
  function onScroll() {
    const now = Date.now();
    const dt = now - lastScrollTime;
    state.scrollY = window.scrollY;
    if (dt > 0) {
      state.scrollVelocity = Math.abs(window.scrollY - lastScrollY) / dt * 1000; // px/s
    }
    lastScrollY = window.scrollY;
    lastScrollTime = now;
    state.lastActivity = now;
  }

  // ---- Section attention (IntersectionObserver) ----
  function initSectionObserver() {
    const sections = document.querySelectorAll('.cv-section, .cv-header');
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const id = entry.target.id;
        if (!id) continue;
        if (!state.sections[id]) {
          state.sections[id] = { dwellTime: 0, entryCount: 0, visible: false, lastSeen: null };
        }
        const sec = state.sections[id];
        if (entry.isIntersecting && entry.intersectionRatio > 0.5) {
          if (!sec.visible) {
            sec.visible = true;
            sec.entryCount++;
            sec.lastSeen = Date.now();
          }
          state.currentSection = id;
        } else {
          if (sec.visible && sec.lastSeen) {
            sec.dwellTime += Date.now() - sec.lastSeen;
          }
          sec.visible = false;
          sec.lastSeen = null;
        }
      }
    }, { threshold: [0, 0.25, 0.5, 0.75, 1.0] });

    sections.forEach(s => observer.observe(s));
  }

  // ---- Text selection ----
  function onSelectionChange() {
    const sel = document.getSelection();
    if (sel && sel.toString().trim()) {
      const text = sel.toString().trim();
      if (text.length > 2 && text.length < 500) {
        state.textSelections.push({ text, time: Date.now() });
        // Keep last 10
        if (state.textSelections.length > 10) state.textSelections.shift();
      }
    }
    state.lastActivity = Date.now();
  }

  // ---- Tab visibility ----
  function onVisibilityChange() {
    if (document.hidden) {
      state.focused = false;
      state._tabAwayStart = Date.now();
      state.tabAwayCount++;
    } else {
      state.focused = true;
      if (state._tabAwayStart) {
        state.tabAwayDuration += Date.now() - state._tabAwayStart;
        state._tabAwayStart = null;
      }
    }
  }

  // ---- Attention pattern classification ----
  function classifyAttention() {
    const idle = Date.now() - state.lastActivity;
    state.idleTime = idle;

    if (idle > 5000) {
      state.attentionPattern = 'idle';
    } else if (state.scrollVelocity > 800) {
      state.attentionPattern = 'scanning';
    } else if (state.scrollVelocity < 100 && state.currentSection) {
      // Check if current section has been visible > 2s
      const sec = state.sections[state.currentSection];
      if (sec && sec.visible && sec.lastSeen && (Date.now() - sec.lastSeen > 2000)) {
        state.attentionPattern = 'reading';
      } else {
        state.attentionPattern = 'browsing';
      }
    } else {
      state.attentionPattern = 'browsing';
    }
  }

  // ---- Update visible section dwell times ----
  function updateDwellTimes() {
    const now = Date.now();
    for (const sec of Object.values(state.sections)) {
      if (sec.visible && sec.lastSeen) {
        sec.dwellTime += now - sec.lastSeen;
        sec.lastSeen = now;
      }
    }
  }

  // ---- Init ----
  function start() {
    try { window.addEventListener('pointermove', onPointerMove, { passive: true }); } catch {}
    try { window.addEventListener('scroll', onScroll, { passive: true }); } catch {}
    try { document.addEventListener('selectionchange', onSelectionChange); } catch {}
    try { document.addEventListener('visibilitychange', onVisibilityChange); } catch {}
    try { initSectionObserver(); } catch {}
  }

  // ---- Snapshot for director ----
  function snapshot() {
    classifyAttention();
    updateDwellTimes();

    // Build clean section dwell map
    const sectionDwells = {};
    for (const [id, s] of Object.entries(state.sections)) {
      sectionDwells[id] = {
        dwellTimeMs: Math.round(s.dwellTime),
        entryCount: s.entryCount,
        currentlyVisible: s.visible,
      };
    }

    return {
      pointerType: state.pointerType,
      currentSection: state.currentSection,
      sectionDwells,
      attentionPattern: state.attentionPattern,
      scrollVelocity: Math.round(state.scrollVelocity),
      idleTimeMs: state.idleTime,
      tabAwayCount: state.tabAwayCount,
      tabAwayDurationMs: Math.round(state.tabAwayDuration),
      textSelections: state.textSelections.slice(-5),
      focused: state.focused,
    };
  }

  return { start, snapshot };
}
