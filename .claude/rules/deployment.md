---
paths:
  - "Dockerfile"
  - "fly.toml"
  - ".github/**/*"
  - "config/runtime.exs"
---

# Deployment Rules

## Fly.io
- Deploy via `fly deploy` for instant iteration, or `git push main` for CI pipeline
- Secrets managed via `fly secrets set` — never commit API keys
- Multi-stage Dockerfile: compile -> release -> minimal runtime image
- Health check: Phoenix endpoint serves on configured `PORT`

## CI/CD (GitHub Actions)
- Pipeline: push to `main` -> `flyctl deploy --remote-only` -> live on henrystoll.de
- CI runs: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`
- No manual steps — fully automated deploy

## Config
- `config/runtime.exs` reads env vars at boot: `ANTHROPIC_API_KEY`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`
- Dev config in `config/dev.exs` — logger level, endpoint settings
- Never hardcode environment-specific values in application code
