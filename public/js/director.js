/**
 * director.js – The director loop
 * Builds session state, calls /api/director, executes returned tool calls.
 */

import {
  rewriteSection,
  adjustVisual,
  showGhostCursor,
  addMarginNote,
  requestBrowserPermission,
  revealCollectedData,
  doNothing,
} from './tools.js';

export function createDirector(fingerprint, behaviorTracker) {
  const startTime = Date.now();
  let tick = 0;
  let phase = 0;
  const mutations = [];
  const actionHistory = [];
  const permissions = {
    geolocation: 'unknown',
    notifications: 'unknown',
    camera: 'unknown',
    microphone: 'unknown',
  };
  let running = false;
  let timeoutId = null;

  function getPhase() {
    const elapsed = Date.now() - startTime;
    if (elapsed < 8000) return 0;
    if (elapsed < 20000) return 1;
    if (elapsed < 40000) return 2;
    if (elapsed < 75000) return 3;
    return 4;
  }

  function getTickInterval() {
    const behavioral = behaviorTracker.snapshot();

    if (!behavioral.focused) return 15000;
    if (behavioral.idleTimeMs > 15000) return 12000;

    switch (phase) {
      case 0: return 6000;
      case 1:
      case 2: return 5000;
      case 3: return 6000;
      default: return 8000;
    }
  }

  async function callDirector() {
    phase = getPhase();
    tick++;

    const sessionState = {
      elapsed_ms: Date.now() - startTime,
      tick,
      phase,
      fingerprint,
      behavioral: behaviorTracker.snapshot(),
      permissions,
      mutations: mutations.slice(-20),
      action_history: actionHistory.slice(-15),
    };

    try {
      const res = await fetch('/api/director', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(sessionState),
      });

      if (!res.ok) {
        console.warn('Director returned', res.status);
        return;
      }

      const { actions } = await res.json();
      if (!actions || !actions.length) return;

      for (const action of actions) {
        await executeAction(action, sessionState);
        actionHistory.push({
          tick,
          time: Date.now() - startTime,
          tool: action.tool,
          params: action.params,
        });
      }
    } catch (err) {
      console.warn('Director call failed:', err.message);
    }
  }

  async function executeAction(action, sessionState) {
    const { tool, params } = action;

    switch (tool) {
      case 'rewrite_section':
        await rewriteSection(params);
        mutations.push({ type: 'rewrite', section: params.section_id, content: params.content });
        break;

      case 'adjust_visual':
        adjustVisual(params);
        mutations.push({ type: 'visual', variables: params.css_variables });
        break;

      case 'show_ghost_cursor':
        showGhostCursor(params);
        mutations.push({ type: 'ghost_cursor', label: params.cursor_label });
        break;

      case 'add_margin_note':
        addMarginNote(params);
        mutations.push({ type: 'margin_note', section: params.anchor_section, content: params.content });
        break;

      case 'request_browser_permission': {
        const result = await requestBrowserPermission(params);
        permissions[params.permission] = result.granted ? 'granted' : 'denied';
        mutations.push({ type: 'permission', permission: params.permission, granted: result.granted, result: result.result });
        break;
      }

      case 'reveal_collected_data':
        revealCollectedData(params, sessionState);
        mutations.push({ type: 'reveal', data_type: params.data_type });
        break;

      case 'do_nothing':
        doNothing();
        break;

      default:
        console.warn('Unknown tool:', tool);
    }

    // Show toolbar at Phase 2+
    if (phase >= 2) {
      const toolbar = document.getElementById('toolbar');
      if (toolbar) toolbar.classList.add('visible');
    }
  }

  function scheduleNext() {
    if (!running) return;
    const interval = getTickInterval();
    timeoutId = setTimeout(async () => {
      await callDirector();
      scheduleNext();
    }, interval);
  }

  function start() {
    running = true;
    // First tick after initial phase 0 delay
    timeoutId = setTimeout(async () => {
      await callDirector();
      scheduleNext();
    }, 3000);
  }

  function stop() {
    running = false;
    if (timeoutId) clearTimeout(timeoutId);
  }

  return { start, stop };
}
