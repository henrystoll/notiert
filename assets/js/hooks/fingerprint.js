/**
 * Fingerprint collection hook.
 * Collects passive browser signals and pushes to server.
 * Every API call is individually try/caught — a failure must never break the page.
 */
export function collectFingerprint(hook) {
  const fp = {};

  try { fp.userAgent = navigator.userAgent; } catch {}
  try { fp.platform = navigator.platform; } catch {}
  try { fp.language = navigator.language; } catch {}
  try { fp.languages = navigator.languages?.join(", "); } catch {}
  try { fp.cookieEnabled = navigator.cookieEnabled; } catch {}
  try { fp.doNotTrack = navigator.doNotTrack || window.doNotTrack || "not set"; } catch {}
  try { fp.cpuCores = navigator.hardwareConcurrency; } catch {}
  try { fp.deviceMemory = navigator.deviceMemory; } catch {}
  try { fp.maxTouchPoints = navigator.maxTouchPoints; } catch {}

  try {
    fp.screenWidth = screen.width;
    fp.screenHeight = screen.height;
    fp.colorDepth = screen.colorDepth;
  } catch {}

  try { fp.pixelRatio = window.devicePixelRatio; } catch {}

  try {
    fp.viewportWidth = window.innerWidth;
    fp.viewportHeight = window.innerHeight;
  } catch {}

  try { fp.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; } catch {}
  try { fp.timezoneOffset = new Date().getTimezoneOffset(); } catch {}
  try { fp.localHour = new Date().getHours(); } catch {}
  try {
    fp.dayOfWeek = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][new Date().getDay()];
  } catch {}

  try { fp.referrer = document.referrer || "direct"; } catch {}
  try {
    const params = Object.fromEntries(new URLSearchParams(window.location.search));
    if (Object.keys(params).length > 0) fp.urlParams = JSON.stringify(params);
  } catch {}

  try { fp.darkMode = window.matchMedia("(prefers-color-scheme: dark)").matches; } catch {}
  try { fp.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch {}
  try { fp.highContrast = window.matchMedia("(prefers-contrast: high)").matches; } catch {}

  try {
    const conn = navigator.connection;
    if (conn) {
      fp.connectionType = conn.effectiveType;
      fp.connectionDownlink = conn.downlink;
      fp.connectionRtt = conn.rtt;
      fp.saveData = conn.saveData;
    }
  } catch {}

  // Battery (async, sent as update)
  try {
    if (navigator.getBattery) {
      navigator.getBattery().then(battery => {
        fp.batteryLevel = Math.round(battery.level * 100);
        fp.batteryCharging = battery.charging;
        hook.pushEvent("fingerprint", fp);
      }).catch(() => {});
    }
  } catch {}

  // Canvas fingerprint
  try {
    const canvas = document.createElement("canvas");
    canvas.width = 200;
    canvas.height = 50;
    const ctx = canvas.getContext("2d");
    ctx.textBaseline = "alphabetic";
    ctx.font = "14px Arial";
    ctx.fillStyle = "#f60";
    ctx.fillRect(0, 0, 200, 50);
    ctx.fillStyle = "#069";
    ctx.fillText("notiert fingerprint", 2, 15);
    ctx.fillStyle = "rgba(102, 204, 0, 0.7)";
    ctx.fillText("notiert fingerprint", 4, 17);
    fp.canvasHash = simpleHash(canvas.toDataURL());
  } catch {
    fp.canvasHash = "blocked";
  }

  // WebGL renderer
  try {
    const gl = document.createElement("canvas").getContext("webgl");
    const dbg = gl?.getExtension("WEBGL_debug_renderer_info");
    if (dbg) {
      fp.webglRenderer = gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL);
      fp.webglVendor = gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL);
    }
  } catch {}

  // Push initial fingerprint (battery update may follow)
  hook.pushEvent("fingerprint", fp);
}

function simpleHash(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash; // Convert to 32-bit integer
  }
  return hash.toString(16);
}
