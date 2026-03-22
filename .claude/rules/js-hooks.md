---
paths:
  - "assets/js/**/*.js"
---

# JS Hooks Rules

## Architecture
- All hooks live in `assets/js/hooks/` as ES modules
- Hooks communicate with the server exclusively via `this.pushEvent(event, payload)`
- Server-to-client updates arrive via `this.handleEvent(event, callback)`
- No direct DOM manipulation for content changes — LiveView handles the DOM

## Behavior Hook (`behavior.js`)
- Sends periodic snapshots (every 2s) — keep payload small
- Tracks: pointer/touch input, scroll velocity, section dwell times, text selections, tab visibility, attention pattern
- Uses `IntersectionObserver` for section visibility — `data-section` attributes on section elements
- Attention pattern classification: reading / browsing / scanning / idle
- Must clean up all event listeners and observers on `destroyed()`

## Fingerprint Hook (`fingerprint.js`)
- Collects browser fingerprint on mount: screen, timezone, languages, UA, color scheme preference, connection type
- Sends once via `pushEvent("fingerprint", data)` — no repeated sends
- No external fingerprinting libraries — use native browser APIs only

## Tools Hook (`tools.js`)
- Executes director actions received from the server: typing animations, cursor movement, visual adjustments
- Typing animation: character-by-character reveal with variable speed
- CSS variable changes animate via transitions — set properties on `document.documentElement`

## General Rules
- No external JS dependencies — vanilla JS only
- Mobile-first: assume touch input, small viewport, Safari quirks
- High-frequency handlers (scroll, pointermove) must be throttled or passive
- Never store sensitive data in JS — all state lives server-side
