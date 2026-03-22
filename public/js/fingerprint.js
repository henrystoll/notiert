/**
 * fingerprint.js – Passive fingerprint collection
 * All browser API calls wrapped in try/catch. Nothing breaks the page.
 */

export function collectFingerprint() {
  const fp = {};

  try { fp.userAgent = navigator.userAgent; } catch {}
  try { fp.platform = navigator.platform; } catch {}
  try { fp.language = navigator.language; } catch {}
  try { fp.languages = Array.from(navigator.languages || []); } catch {}
  try { fp.doNotTrack = navigator.doNotTrack || window.doNotTrack || ''; } catch {}
  try { fp.cookieEnabled = navigator.cookieEnabled; } catch {}

  // Screen
  try {
    fp.screenWidth = screen.width;
    fp.screenHeight = screen.height;
    fp.screenAvailWidth = screen.availWidth;
    fp.screenAvailHeight = screen.availHeight;
    fp.pixelRatio = window.devicePixelRatio;
    fp.colorDepth = screen.colorDepth;
  } catch {}

  // Viewport
  try {
    fp.viewportWidth = window.innerWidth;
    fp.viewportHeight = window.innerHeight;
  } catch {}

  // Time
  try {
    fp.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    fp.timezoneOffset = new Date().getTimezoneOffset();
    fp.localHour = new Date().getHours();
    fp.dayOfWeek = new Date().toLocaleDateString('en', { weekday: 'long' });
  } catch {}

  // Hardware
  try { fp.deviceMemory = navigator.deviceMemory; } catch {}
  try { fp.hardwareConcurrency = navigator.hardwareConcurrency; } catch {}
  try { fp.maxTouchPoints = navigator.maxTouchPoints; } catch {}

  // Preferences
  try { fp.prefersColorScheme = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'; } catch {}
  try { fp.prefersReducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches; } catch {}
  try { fp.prefersHighContrast = matchMedia('(prefers-contrast: high)').matches; } catch {}

  // Connection
  try {
    const c = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    if (c) {
      fp.connectionType = c.effectiveType;
      fp.downlink = c.downlink;
      fp.rtt = c.rtt;
      fp.saveData = c.saveData;
    }
  } catch {}

  // Battery
  try {
    if (navigator.getBattery) {
      navigator.getBattery().then(b => {
        fp.batteryLevel = Math.round(b.level * 100);
        fp.batteryCharging = b.charging;
      }).catch(() => {});
    }
  } catch {}

  // Referrer
  try { fp.referrer = document.referrer || ''; } catch {}

  // URL params (link decoration)
  try {
    const params = new URLSearchParams(window.location.search);
    if (params.toString()) {
      fp.urlParams = Object.fromEntries(params.entries());
    }
  } catch {}

  // Canvas fingerprint
  try {
    const canvas = document.createElement('canvas');
    canvas.width = 200;
    canvas.height = 50;
    const ctx = canvas.getContext('2d');
    ctx.textBaseline = 'top';
    ctx.font = '14px Arial';
    ctx.fillStyle = '#f60';
    ctx.fillRect(0, 0, 100, 25);
    ctx.fillStyle = '#069';
    ctx.fillText('notiert', 2, 2);
    ctx.fillStyle = 'rgba(102,204,0,0.7)';
    ctx.fillText('notiert', 4, 4);
    fp.canvasHash = simpleHash(canvas.toDataURL());
  } catch {}

  // WebGL
  try {
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
    if (gl) {
      const ext = gl.getExtension('WEBGL_debug_renderer_info');
      if (ext) {
        fp.webglRenderer = gl.getParameter(ext.UNMASKED_RENDERER_WEBGL);
        fp.webglVendor = gl.getParameter(ext.UNMASKED_VENDOR_WEBGL);
      }
    }
  } catch {}

  return fp;
}

function simpleHash(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const c = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + c;
    hash |= 0;
  }
  return hash.toString(16);
}
