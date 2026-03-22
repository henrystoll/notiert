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

  // Wrap existing content — hidden in normal mode, struck through in debug
  const existingText = target.innerHTML;
  const old = document.createElement("span");
  old.className = "rewrite-old";
  old.innerHTML = existingText;

  // New content span — types in character by character
  const fresh = document.createElement("span");
  fresh.className = "rewrite-new";

  // Debug mode shows old text struck through + new text highlighted
  if (debug) {
    sectionContent.classList.add("debug-rewrite");
  }

  // Blinking cursor
  const cursor = document.createElement("span");
  cursor.className = "typing-cursor";

  // Replace content
  target.innerHTML = "";
  target.appendChild(old);
  if (debug) {
    target.appendChild(document.createTextNode(" "));
  }
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

  // Clean up previous listener/animation
  if (ghostEl._cleanup) ghostEl._cleanup();

  // Update label
  const labelEl = ghostEl.querySelector(".ghost-cursor-label");
  if (labelEl) labelEl.textContent = cursor_label;

  ghostEl.classList.add("visible");

  if (behavior === "follow_user") {
    let targetX = 0, targetY = 0, currentX = 0, currentY = 0;
    let animating = false;

    const onMove = (e) => {
      // Use touch position on mobile, pointer on desktop
      const x = e.clientX || (e.touches && e.touches[0]?.clientX) || 0;
      const y = e.clientY || (e.touches && e.touches[0]?.clientY) || 0;
      targetX = x + 20;
      targetY = y + 15;

      if (!animating) {
        animating = true;
        animate();
      }
    };

    const animate = () => {
      // Smooth lerp toward target
      currentX += (targetX - currentX) * 0.15;
      currentY += (targetY - currentY) * 0.15;
      ghostEl.style.left = `${currentX}px`;
      ghostEl.style.top = `${currentY}px`;

      if (Math.abs(targetX - currentX) > 0.5 || Math.abs(targetY - currentY) > 0.5) {
        ghostEl._raf = requestAnimationFrame(animate);
      } else {
        animating = false;
      }
    };

    document.addEventListener("pointermove", onMove, { passive: true });
    document.addEventListener("touchmove", onMove, { passive: true });
    ghostEl._cleanup = () => {
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("touchmove", onMove);
      if (ghostEl._raf) cancelAnimationFrame(ghostEl._raf);
    };
  } else if (behavior === "move_to_element" && target) {
    const targetEl = document.getElementById(`section-${target}`);
    if (targetEl) {
      let ticking = false;
      const updatePos = () => {
        const rect = targetEl.getBoundingClientRect();
        ghostEl.style.left = `${rect.left + rect.width * 0.3}px`;
        ghostEl.style.top = `${rect.top + 20}px`;
        ticking = false;
      };

      const onScroll = () => {
        if (!ticking) {
          ticking = true;
          requestAnimationFrame(updatePos);
        }
      };

      updatePos();
      window.addEventListener("scroll", onScroll, { passive: true });
      // Also update on resize (mobile address bar show/hide)
      window.addEventListener("resize", onScroll, { passive: true });
      ghostEl._cleanup = () => {
        window.removeEventListener("scroll", onScroll);
        window.removeEventListener("resize", onScroll);
      };
    }
  }
}

// ---- Margin notes (client-side animation) ----
export function showMarginNote({ section_id, content, author }) {
  requestAnimationFrame(() => {
    const note = document.getElementById(`margin-note-${section_id}`);
    if (note) {
      note.classList.add("visible");
    }
  });
}

// ---- Permission requests ----
export function requestPermission(hook, { permission, pre_request_content, on_granted_content, on_denied_content, target_section }) {
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
      } else if (permission === "camera") {
        const stream = await navigator.mediaDevices.getUserMedia({ video: true });
        stream.getTracks().forEach((t) => t.stop());
        hook.pushEvent("permission_result", { permission: "camera", result: "granted" });
      } else if (permission === "microphone") {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        // Measure ambient noise briefly
        try {
          const ctx = new AudioContext();
          const src = ctx.createMediaStreamSource(stream);
          const analyser = ctx.createAnalyser();
          analyser.fftSize = 256;
          src.connect(analyser);
          const data = new Uint8Array(analyser.frequencyBinCount);
          await new Promise((r) => setTimeout(r, 1000));
          analyser.getByteFrequencyData(data);
          const avg = data.reduce((a, b) => a + b, 0) / data.length;
          ctx.close();
          stream.getTracks().forEach((t) => t.stop());
          hook.pushEvent("permission_result", {
            permission: "microphone",
            result: "granted",
            noise_level: Math.round(avg),
          });
        } catch {
          stream.getTracks().forEach((t) => t.stop());
          hook.pushEvent("permission_result", { permission: "microphone", result: "granted" });
        }
      } else if (permission === "notifications") {
        const result = await Notification.requestPermission();
        if (result === "granted") {
          new Notification("Henry Stoll", {
            body: "GenAI Engineer & AI Architect. Available for interesting conversations.",
            icon: "data:text/plain,👁",
          });
        }
        hook.pushEvent("permission_result", {
          permission: "notifications",
          result: result === "granted" ? "granted" : "denied",
        });
      }
    } catch {
      hook.pushEvent("permission_result", { permission, result: "denied" });
    }
  }, 1500);
}
