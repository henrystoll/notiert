import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { collectFingerprint } from "./hooks/fingerprint";
import { startBehaviorTracking } from "./hooks/behavior";
import {
  typeRewrite,
  adjustVisual,
  showCursor,
  hideCursor,
  showMarginNote,
  requestPermission,
} from "./hooks/tools";

// ---- LiveView Hooks ----

const Hooks = {};

/**
 * Main Notiert hook — mounted on the root element.
 * Handles fingerprint collection, behavior tracking, and server-pushed events.
 */
Hooks.Notiert = {
  mounted() {
    this.debug = this.el.dataset.debug === "true";

    // Collect fingerprint and push to server
    collectFingerprint(this);

    // Start continuous behavior tracking
    startBehaviorTracking(this);

    // Handle server-pushed tool events
    this.handleEvent("type_rewrite", (data) => {
      typeRewrite(this.el, { ...data, debug: this.debug });
    });

    this.handleEvent("adjust_visual", (data) => {
      adjustVisual(data);
    });

    this.handleEvent("show_cursor", (data) => {
      showCursor(this.el, data);
    });

    this.handleEvent("hide_cursor", () => {
      hideCursor();
    });

    this.handleEvent("show_margin_note", (data) => {
      showMarginNote(data);
    });

    this.handleEvent("request_permission", (data) => {
      requestPermission(this, data);
    });

    this.handleEvent("session_started", ({ session_id }) => {
      console.log(`notiert session: ${session_id}`);
    });
  },
};

/**
 * Ghost cursor hook — handles follow_user behavior updates.
 */
Hooks.GhostCursor = {
  mounted() {
    // Ghost cursor element is managed by tools.js
  },
  updated() {
    // Re-apply visibility when LiveView patches
    if (this.el.classList.contains("visible")) {
      this.el.style.display = "";
    }
  },
};

/**
 * Section content hook — marks sections for tool targeting.
 */
Hooks.SectionContent = {
  mounted() {
    this.sectionId = this.el.dataset.sectionId;
  },
};

/**
 * Margin note hook — handles slide-in animation.
 */
Hooks.MarginNote = {
  mounted() {
    // Trigger animation after DOM insertion
    requestAnimationFrame(() => {
      this.el.classList.add("visible");
    });
  },
};

// ---- LiveSocket setup ----

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
  dom: {
    // Preserve client-side DOM mutations (typing animations, struck text)
    // by skipping updates for elements that have been modified by tools
    onBeforeElUpdated(fromEl, toEl) {
      if (fromEl.classList?.contains("debug-rewrite")) {
        return false; // Don't let LiveView overwrite typing animations
      }
      return true;
    },
  },
});

liveSocket.connect();

// Dev helpers
window.liveSocket = liveSocket;
