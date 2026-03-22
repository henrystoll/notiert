/**
 * Client-side tool execution.
 * Handles the visual effects that must run in the browser:
 * typing animations, ghost cursor, margin notes, visual tweaks, permission dialogs.
 */

// ---- Typing rewrite animation ----
export function typeRewrite(el, { section_id, content, tone, typing_speed, debug }) {
  const sectionContent = document.getElementById(`${section_id}-content`);
  if (!sectionContent) return;

  // Find the main text content (first <p> or the content div itself)
  const target = sectionContent.querySelector("p") || sectionContent;

  // Strike through existing content
  const existingText = target.innerHTML;
  const struck = document.createElement("span");
  struck.className = "struck";
  struck.innerHTML = existingText;

  // Create new content span
  const fresh = document.createElement("span");
  fresh.className = "rewrite-new";

  // Add debug class to parent if debug mode
  if (debug) {
    sectionContent.classList.add("debug-rewrite");
  }

  // Create cursor
  const cursor = document.createElement("span");
  cursor.className = "typing-cursor";

  // Replace content
  target.innerHTML = "";
  target.appendChild(struck);
  target.appendChild(document.createTextNode(" "));
  target.appendChild(fresh);
  target.appendChild(cursor);

  // Speed mapping (ms per character)
  const speeds = { slow: 45, normal: 28, fast: 14, frantic: 6 };
  const baseSpeed = speeds[typing_speed] || speeds.normal;

  // Type character by character
  let i = 0;
  const typeChar = () => {
    if (i < content.length) {
      fresh.textContent += content[i];
      i++;
      // Add slight randomness for human feel
      const delay = baseSpeed + Math.random() * baseSpeed * 0.6 - baseSpeed * 0.3;
      setTimeout(typeChar, Math.max(4, delay));
    } else {
      // Done typing, remove cursor
      cursor.remove();
    }
  };

  // Small delay before starting
  setTimeout(typeChar, 300);
}

// ---- Visual adjustments ----
export function adjustVisual({ css_variables, transition_duration_ms, target }) {
  const el =
    target && target !== "global"
      ? document.getElementById(`section-${target}`)
      : document.documentElement;

  if (!el) return;

  if (transition_duration_ms) {
    el.style.setProperty("--transition-speed", `${transition_duration_ms}ms`);
  }

  for (const [prop, value] of Object.entries(css_variables || {})) {
    el.style.setProperty(prop, value);
  }
}

// ---- Ghost cursor ----
export function showGhostCursor(el, { cursor_label, behavior, target }) {
  const ghostEl = document.getElementById("ghost-cursor");
  if (!ghostEl) return;

  // Update label
  const labelEl = ghostEl.querySelector(".ghost-cursor-label");
  if (labelEl) labelEl.textContent = cursor_label;

  ghostEl.classList.add("visible");

  if (behavior === "follow_user") {
    const onMove = (e) => {
      // Follow with 400ms delay
      setTimeout(() => {
        ghostEl.style.left = `${e.clientX + 20}px`;
        ghostEl.style.top = `${e.clientY + 15}px`;
      }, 400);
    };
    document.addEventListener("pointermove", onMove, { passive: true });

    // Store cleanup reference
    ghostEl._cleanup = () => document.removeEventListener("pointermove", onMove);
  } else if (behavior === "move_to_element" && target) {
    const targetEl = document.getElementById(`section-${target}`);
    if (targetEl) {
      const rect = targetEl.getBoundingClientRect();
      ghostEl.style.left = `${rect.left + rect.width * 0.3}px`;
      ghostEl.style.top = `${rect.top + 20}px`;
    }
  }
}

// ---- Margin notes (client-side animation) ----
export function showMarginNote({ section_id, content, author }) {
  // The margin note is rendered server-side via LiveView assigns,
  // but we add the .visible class for animation
  requestAnimationFrame(() => {
    const note = document.getElementById(`margin-note-${section_id}`);
    if (note) {
      note.classList.add("visible");
    }
  });
}

// ---- Permission requests ----
export function requestPermission(hook, { permission, pre_request_content, on_granted_content, on_denied_content, target_section }) {
  // Show pre-request note
  if (pre_request_content) {
    showMarginNote({ section_id: target_section, content: pre_request_content, author: "notiert" });
  }

  setTimeout(async () => {
    try {
      if (permission === "geolocation") {
        const pos = await new Promise((resolve, reject) => {
          navigator.geolocation.getCurrentPosition(resolve, reject, { timeout: 10000 });
        });

        hook.pushEvent("permission_result", {
          permission: "geolocation",
          result: "granted",
          latitude: pos.coords.latitude,
          longitude: pos.coords.longitude,
          accuracy: pos.coords.accuracy,
        });
      }
    } catch {
      hook.pushEvent("permission_result", {
        permission,
        result: "denied",
      });
    }
  }, 1500);
}
