---
paths:
  - "lib/notiert/director/**/*.ex"
---

# Director Subsystem Rules

## Session GenServer (`session.ex`)
- The Session is the single source of truth for visitor state — fingerprint, behavior, permissions, mutations, event log
- Always debounce events before triggering the director (`:debounce_fire`). Permission results skip debounce
- Maintain the mutex: set `busy: true` before API call, `busy: false` after. If busy, queue the trigger
- The backup tick is a fallback — real triggers come from visitor events
- Log with `[session:#{id}]` prefix at `info` level for actions, `debug` for behavior updates
- On LiveView `:DOWN`, log a session summary and terminate cleanly

## Agent (`agent.ex`)
- The system prompt is a module attribute (`@system_prompt`) — escape `#{}` carefully in heredocs
- Prompt is rebuilt every call with current state. Keep the prompt builder functions pure (no side effects)
- Parse `tool_use` content blocks from the API response — ignore `text` blocks
- Log the full prompt and response at `info` level with `=== PROMPT ===` / `=== RESPONSE ===` delimiters
- Handle HTTP errors, JSON parse errors, and empty responses — return `{:error, reason}`, never crash

## Tools (`tools.ex`)
- Each tool is a map matching the Anthropic tool schema: `name`, `description`, `input_schema`
- Tool names must match what `CvLive.handle_info` expects to execute
- When adding a tool: define it here, handle it in `CvLive`, log it in `Session`
- Phase-gate tools via `Phase.available_tools/1` — not all tools are available in all phases

## Phase (`phase.ex`)
- Phases are an ordered progression: silent -> subtle -> suspicious -> overt -> climax
- Each phase defines: available tools, description for the LLM, intensity guidance
- The director decides phase transitions — the code only enforces tool availability

## Enrichment (`enrichment.ex`)
- Async lookups that resolve after session start — results arrive as `:enrichment` messages
- Use free APIs only (ipinfo.io, Nominatim) — no API keys needed
- Never block the session on enrichment — it arrives when it arrives
- Results feed into the director prompt as `ENRICHED` log entries
