---
paths:
  - "lib/notiert_web/**/*.ex"
  - "lib/notiert_web/**/*.heex"
---

# Web Layer Rules

## CvLive (`cv_live.ex`)
- This is the main LiveView — it renders the CV and coordinates everything
- Start session processes only inside `connected?/1` guard — never on static render
- All client events from JS hooks arrive via `handle_event/3` — validate and forward to Session
- All director actions arrive via `handle_info/2` from the Session GenServer
- Keep assigns minimal: section content, mutations, visual overrides, cursor state
- The `session_id` is generated server-side per WebSocket connection
- Extract visitor IP from `get_connect_info` — never trust client-sent IPs

## Components
- Function components in `NotiertWeb.Components.Cv` for CV section rendering
- Sections use `data-section` attributes for JS hook intersection tracking
- Mutations overlay original content — render `mutations[section_id] || sections[section_id]`
- Debug mode (`?debug=1`) highlights mutated content in red

## Router & Endpoint
- Single route: `live "/", CvLive`
- Endpoint handles static assets, websocket upgrade, and session
- No authentication — the site is public

## Mobile-First UI
- Primary viewport is iPhone Safari/Chrome mobile
- All CSS and layout decisions must prioritize small screens
- Test visual changes mentally against ~375px width
- No Tailwind — use custom CSS with CSS custom properties
