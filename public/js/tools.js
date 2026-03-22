/**
 * tools.js – Director tool implementations
 * Each function executes a tool action on the DOM.
 */

// ---- rewrite_section ----

export function rewriteSection({ section_id, content, tone, typing_speed }) {
  const section = document.getElementById(section_id);
  if (!section) return;

  // Find the <p> inside the section (or the section itself if no <p>)
  const target = section.querySelector('p') || section;
  const oldText = target.textContent;

  const speeds = { slow: 80, normal: 45, fast: 20, frantic: 8 };
  const charDelay = speeds[typing_speed] || speeds.normal;

  // Strikethrough old text
  const oldSpan = document.createElement('span');
  oldSpan.className = 'typing-old';
  oldSpan.textContent = oldText;

  const newSpan = document.createElement('span');
  newSpan.className = 'typing-new';

  const cursor = document.createElement('span');
  cursor.className = 'typing-cursor';

  target.textContent = '';
  target.appendChild(oldSpan);
  target.appendChild(document.createTextNode(' '));
  target.appendChild(newSpan);
  target.appendChild(cursor);

  // Type new text character by character
  let i = 0;
  return new Promise(resolve => {
    function typeChar() {
      if (i < content.length) {
        newSpan.textContent += content[i];
        i++;
        setTimeout(typeChar, charDelay + (Math.random() * charDelay * 0.4));
      } else {
        // Remove cursor after a pause
        setTimeout(() => {
          cursor.remove();
          resolve();
        }, 800);
      }
    }
    typeChar();
  });
}

// ---- adjust_visual ----

export function adjustVisual({ css_variables, transition_duration_ms, target }) {
  const el = (target && target !== 'global')
    ? document.getElementById(target) || document.documentElement
    : document.documentElement;

  if (transition_duration_ms != null) {
    el.style.setProperty('--transition-duration', `${transition_duration_ms}ms`);
  }

  for (const [key, value] of Object.entries(css_variables || {})) {
    el.style.setProperty(key, value);
  }
}

// ---- show_ghost_cursor ----

let ghostAnimFrame = null;

export function showGhostCursor({ cursor_label, behavior, target }) {
  const cursor = document.getElementById('ghost-cursor');
  const label = document.getElementById('ghost-cursor-label');
  if (!cursor || !label) return;

  label.textContent = cursor_label || 'Henry Stoll';
  cursor.classList.add('visible');

  // Cancel previous animation
  if (ghostAnimFrame) cancelAnimationFrame(ghostAnimFrame);

  if (behavior === 'follow_user') {
    let cx = 0, cy = 0;
    function follow(e) {
      cx = e.clientX + 30;
      cy = e.clientY + 10;
    }
    window.addEventListener('pointermove', follow, { passive: true });

    function animate() {
      cursor.style.left = cx + 'px';
      cursor.style.top = cy + 'px';
      ghostAnimFrame = requestAnimationFrame(animate);
    }
    animate();
  } else if (behavior === 'move_to_element') {
    const el = document.getElementById(target) || document.querySelector(target);
    if (el) {
      const rect = el.getBoundingClientRect();
      animateCursorTo(cursor, rect.left + rect.width * 0.3, rect.top + rect.height * 0.5);
    }
  }
}

function animateCursorTo(cursor, tx, ty) {
  const startX = parseFloat(cursor.style.left) || window.innerWidth / 2;
  const startY = parseFloat(cursor.style.top) || window.innerHeight / 2;
  const duration = 1200;
  const start = performance.now();

  function step(now) {
    const t = Math.min((now - start) / duration, 1);
    const ease = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
    cursor.style.left = (startX + (tx - startX) * ease) + 'px';
    cursor.style.top = (startY + (ty - startY) * ease) + 'px';
    if (t < 1) ghostAnimFrame = requestAnimationFrame(step);
  }
  ghostAnimFrame = requestAnimationFrame(step);
}

// ---- add_margin_note ----

let noteCount = 0;

export function addMarginNote({ anchor_section, content, author_name }) {
  const section = document.getElementById(anchor_section);
  if (!section) return;

  const note = document.createElement('div');
  note.className = 'margin-note';
  note.innerHTML = `
    <div class="margin-note-author">${escapeHtml(author_name || 'Henry Stoll')}</div>
    <div>${escapeHtml(content)}</div>
    <div class="margin-note-time">Just now</div>
  `;

  // Stack notes vertically
  note.style.top = (noteCount * 100) + 'px';
  noteCount++;

  section.style.position = 'relative';
  section.appendChild(note);

  // Fade in
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      note.classList.add('visible');
    });
  });
}

// ---- request_browser_permission ----

export async function requestBrowserPermission({ permission, pre_request_content, on_granted_content, on_denied_content, target_section }) {
  const section = document.getElementById(target_section);

  // Show pre-request content
  if (pre_request_content && section) {
    addMarginNote({ anchor_section: target_section, content: pre_request_content, author_name: 'Henry Stoll' });
    await delay(2000);
  }

  let granted = false;
  let result = {};

  try {
    if (permission === 'geolocation') {
      const pos = await new Promise((resolve, reject) => {
        navigator.geolocation.getCurrentPosition(resolve, reject, { timeout: 10000 });
      });
      granted = true;
      result = {
        latitude: pos.coords.latitude.toFixed(4),
        longitude: pos.coords.longitude.toFixed(4),
        accuracy: Math.round(pos.coords.accuracy),
      };
    } else if (permission === 'notifications') {
      const perm = await Notification.requestPermission();
      granted = perm === 'granted';
      if (granted) {
        try {
          new Notification('Henry Stoll – Data Scientist', {
            body: 'Available for interesting conversations.',
            icon: undefined,
          });
        } catch {}
      }
    } else if (permission === 'camera' || permission === 'microphone') {
      const constraints = permission === 'camera' ? { video: true } : { audio: true };
      const stream = await navigator.mediaDevices.getUserMedia(constraints);

      granted = true;

      if (permission === 'microphone') {
        // Detect ambient noise level
        try {
          const audioCtx = new AudioContext();
          const source = audioCtx.createMediaStreamSource(stream);
          const analyser = audioCtx.createAnalyser();
          analyser.fftSize = 256;
          source.connect(analyser);
          const data = new Uint8Array(analyser.frequencyBinCount);

          await delay(1000);
          analyser.getByteFrequencyData(data);
          const avg = data.reduce((a, b) => a + b, 0) / data.length;

          result.ambientLevel = avg < 10 ? 'silent' : avg < 40 ? 'quiet' : avg < 80 ? 'moderate' : 'loud';
          result.ambientAvg = Math.round(avg);
          audioCtx.close();
        } catch {}
      }

      // Release stream immediately
      stream.getTracks().forEach(t => t.stop());
    }
  } catch {
    granted = false;
  }

  // Show result
  const responseContent = granted ? on_granted_content : on_denied_content;
  if (responseContent && section) {
    addMarginNote({ anchor_section: target_section, content: responseContent, author_name: 'Henry Stoll' });
  }

  return { permission, granted, result };
}

// ---- reveal_collected_data ----

export function revealCollectedData({ data_type, presentation }, sessionState) {
  const paper = document.getElementById('paper');
  if (!paper) return;

  const reveal = document.createElement('div');
  reveal.className = 'data-reveal';

  let data = {};
  if (data_type === 'fingerprint') data = sessionState.fingerprint || {};
  else if (data_type === 'behavioral') data = sessionState.behavioral || {};
  else data = { ...sessionState.fingerprint, ...sessionState.behavioral };

  const title = {
    fingerprint: 'What Henry knows about your device',
    behavioral: 'What Henry noticed about your behavior',
    all: 'Everything Henry collected in this session',
  }[data_type] || 'Collected Data';

  let rowsHtml = '';
  for (const [key, value] of Object.entries(data)) {
    if (value == null || (typeof value === 'object' && !Array.isArray(value))) continue;
    const display = Array.isArray(value) ? value.join(', ') : String(value);
    rowsHtml += `<div class="data-reveal-row">
      <span class="data-reveal-label">${escapeHtml(formatLabel(key))}</span>
      <span class="data-reveal-value">${escapeHtml(display)}</span>
    </div>`;
  }

  reveal.innerHTML = `<div class="data-reveal-title">${escapeHtml(title)}</div>${rowsHtml}`;

  paper.appendChild(reveal);
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      reveal.classList.add('visible');
      reveal.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });
  });
}

// ---- do_nothing ----

export function doNothing() {
  // Intentional. Comedic timing needs silence.
}

// ---- Helpers ----

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

function formatLabel(key) {
  return key
    .replace(/([A-Z])/g, ' $1')
    .replace(/[_-]/g, ' ')
    .replace(/^./, c => c.toUpperCase())
    .replace(/Ms$/, '(ms)')
    .trim();
}

function delay(ms) {
  return new Promise(r => setTimeout(r, ms));
}
