# notiert - Phoenix LiveView

## Project Overview
A living CV website that passively observes visitors and rewrites itself in real-time using an LLM director agent. Built with Phoenix LiveView for persistent WebSocket connections and server-side state management.

## Architecture
- **Phoenix LiveView** drives the UI via WebSocket
- **Per-visitor session process** holds fingerprint, behavior, and director state
- **Director agent** calls Anthropic API server-side, returns tool calls that push DOM updates
- **JS Hooks** collect fingerprint and behavior data, push to server via `pushEvent`

## Key Modules
- `Notiert.Director.Agent` - Anthropic API integration, prompt building, tool definitions
- `Notiert.Director.Session` - Per-visitor GenServer holding all state, runs director loop
- `Notiert.Director.Tools` - Tool definitions for the Anthropic API
- `NotiertWeb.CvLive` - Main LiveView, renders CV, handles events from hooks and director
- `NotiertWeb.Components.Cv` - Function components for CV sections

## Development
```bash
mix deps.get
mix phx.server
# Visit http://localhost:4000
```

## Environment Variables
- `ANTHROPIC_API_KEY` - Required for director agent
- `SECRET_KEY_BASE` - Phoenix secret (generated)
- `PHX_HOST` - Production hostname
- `PORT` - Server port (default 4000)

## Code Style
- Elixir: snake_case functions, PascalCase modules, `mix format`
- JS: ES modules, hooks in `assets/js/hooks/`
- CSS: CSS custom properties for theming, mobile-first
- No Tailwind - custom Google Docs aesthetic CSS

## Testing
```bash
mix test
```

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
