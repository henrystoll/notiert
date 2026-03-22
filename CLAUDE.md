# notiert - Phoenix LiveView

## Project Overview
A living CV website that passively observes visitors and rewrites itself in real-time using an LLM director agent. Built with Phoenix LiveView for persistent WebSocket connections and server-side state management.

Most visitors access via **iPhone Safari/Chrome mobile**. All UI decisions should prioritize that viewport.

## Architecture

### Event-driven director loop
- **Phoenix LiveView** drives the UI via WebSocket
- **Per-visitor Session GenServer** holds all state, fires director on meaningful events
- **Director agent** calls Anthropic API, returns tool calls that push DOM updates
- **JS Hooks** collect fingerprint and behavior data, push to server via `pushEvent`

### Director trigger model
The director is **event-driven**, not purely interval-based:
- **Events trigger the director**: fingerprint received, section change, text selection, tab return, attention change, permission result
- **Events are debounced** (800ms) to coalesce nearby events into one call
- **Permission results fire immediately** (no debounce) with hesitation timing
- **Backup tick** every 10s as fallback when no events fire
- **One API call at a time** (mutex) — events queue while busy
- Each call receives: trigger reason, new events since last call, full event log, current state

### Event log
One continuous log of both visitor events and director actions, chronologically interleaved:
- `VISITOR` events: fingerprint, section_change, attention_change, text_selection, tab_return, permission granted/denied (with hesitation timing)
- `DIRECTOR` actions: edits, notes, visual adjustments, cursor moves, permission requests, phase changes, waits
- Supporting data included (dwell times, hesitation ms), raw data excluded

### Single cursor
One cursor element, fully director-controlled via `show_cursor` / `hide_cursor` tools. The code does nothing automatic — the director decides when to show/hide the cursor. System prompt instructs the director to pair cursor with edits (show cursor at section, then edit it).

### CSS variables for theming
The director can adjust visual presentation via CSS custom properties. Creative uses:
- `--accent`: shift to visitor's national colors (inferred from timezone/geolocation)
- `--bg`/`--fg`: adapt to dark mode preference
- `--fg-secondary`: warm up for late-night readers
- `--cursor-color`: make the cursor stand out
- Can target individual sections or the whole page
- All changes animate smoothly via CSS transitions

### Enrichment pipeline
Async lookups that resolve visitor signals into intelligence:
- **IP → org/location** via ipinfo.io (free, no key, 50k/month). Fires on session start. Returns company name, city, country.
- **Reverse geocode** via Nominatim/OSM (free, no key). Fires when geolocation granted. Returns place name (building, road, neighbourhood).
- Results arrive as `:enrichment` events that trigger the director with `ENRICHED` log entries.
- Director sees enrichment in both the event log and a dedicated ENRICHMENT DATA section in the prompt.

Future: homelab researcher agent for OSINT (LinkedIn, blog posts, data aggregators). Separate project.

## Key Modules
- `Notiert.Director.Agent` - Anthropic API integration, prompt building, event log formatting
- `Notiert.Director.Session` - Per-visitor GenServer, event-driven director loop, permission timing
- `Notiert.Director.Tools` - Tool definitions for the Anthropic API
- `Notiert.Director.Phase` - Phase definitions (silent → subtle → suspicious → overt → climax)
- `NotiertWeb.CvLive` - Main LiveView, renders CV, handles events from hooks and director
- `NotiertWeb.Components.Cv` - Function components for CV sections

## Development
```bash
mix deps.get
mix phx.server
# Visit http://localhost:4000
```

## Testing

### In a full environment (local or CI)
```bash
mix test                    # run all tests
mix test --only describe:"Session"  # run specific test group
mix compile --warnings-as-errors    # catch issues
mix format --check-formatted        # style check
```

### In Claude Code remote environment (no hex/deps available)
The remote environment has Elixir 1.14 + OTP 25 but **cannot download hex or deps** (network proxy blocks hex.pm). Use these alternatives:

```bash
# Syntax check — parse all modified files (catches syntax errors, not module refs)
elixir -e 'Code.string_to_quoted(File.read("lib/path/to/file.ex") |> elem(1))'

# Compile individual files (will warn about missing modules — that's expected)
elixir -e 'Code.compile_file("lib/notiert/director/agent.ex")'

# The warnings about "module X is not available" are EXPECTED in isolation —
# they resolve when the full project compiles with mix.
```

**What to verify in this environment:**
- No syntax errors in modified files
- No string interpolation issues in heredocs (e.g., `#{var}` inside `@system_prompt`)
- Pattern matches and function heads are correct
- Test files parse cleanly

**Full compilation and test runs happen in CI** (GitHub Actions) or via `fly deploy`.

## Environment Variables
- `ANTHROPIC_API_KEY` - Required for director agent
- `SECRET_KEY_BASE` - Phoenix secret (generated)
- `PHX_HOST` - Production hostname
- `PORT` - Server port (default 4000)

## Code Style
- Elixir: snake_case functions, PascalCase modules, `mix format`
- JS: ES modules, hooks in `assets/js/hooks/`
- CSS: CSS custom properties for theming, mobile-first (iPhone Safari primary)
- No Tailwind — custom clean CV aesthetic CSS

## Debug Mode
Add `?debug=1` to URL to see LLM-rewritten content highlighted in red.

## Development Constraints

**Everything must be testable and editable through Claude Code with instant deploy to Fly.io.**

- All code changes must be verifiable without a local browser — use `mix test`, `mix compile`, and `mix format --check-formatted` as the feedback loop
- Write ExUnit tests for all server-side logic (director agent, session process, tool definitions, LiveView events)
- Use LiveView test helpers (`Phoenix.LiveViewTest`) to test the full mount → fingerprint → behavior → director action cycle without a browser
- Keep the GitHub Actions deploy pipeline working: push to `main` → `flyctl deploy --remote-only` → live on henrystoll.de
- Fly.io secrets (`ANTHROPIC_API_KEY`, `SECRET_KEY_BASE`) are set via `fly secrets set` — never committed
- The Dockerfile must build the full release (multi-stage: compile → release → minimal runtime image)
- No manual steps required beyond `git push` — the deploy is fully automated
- When iterating, use `fly deploy` directly from Claude Code for instant deploys without waiting for CI

## Logging

All director prompts, API responses, and session interactions are logged extensively. Logs are the primary way to observe and debug the director's behavior from Claude Code (since we can't see the browser).

**Log prefixes:**
- `[session:<id>]` — per-visitor session lifecycle, fingerprint, behavior, permission results (with hesitation timing), triggers, phase transitions, actions, disconnect summary
- `[director]` — full prompt sent to Anthropic API (with `=== PROMPT ===` delimiters), full API response (with `=== RESPONSE ===` delimiters), timing, errors

**Log levels:**
- `info` — prompts, responses, actions executed, fingerprint received, phase changes, session start/stop, trigger events (the important stuff)
- `debug` — behavior updates (every 2s, high volume), debounce skips, backup tick scheduling
- `warning/error` — API failures, missing API key

**Reading logs in production:**
```bash
fly logs              # stream live
fly logs --app notiert  # if not in project dir
```

**Reading logs in dev:**
Logs print to stdout when running `mix phx.server`. Set `config :logger, level: :debug` in `config/dev.exs` to see behavior updates.
