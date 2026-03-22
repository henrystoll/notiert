---
paths:
  - "test/**/*.exs"
---

# Testing Rules

## Framework
- ExUnit with `Phoenix.LiveViewTest` helpers for LiveView integration tests
- Test files mirror source structure: `test/notiert/director/` for `lib/notiert/director/`
- Use `describe` blocks to group related tests — enables `mix test --only describe:"GroupName"`

## What to Test
- **Session GenServer**: event handling, debounce logic, mutex behavior, phase transitions, cleanup on `:DOWN`
- **Agent**: prompt building (unit test the pure functions), tool response parsing, error handling
- **Tools**: tool definition structure matches Anthropic schema, phase gating
- **CvLive**: mount assigns, `handle_event` dispatching, `handle_info` state updates, `connected?` guard behavior

## Test Patterns
- Mock the Anthropic API — never make real API calls in tests
- Use `start_supervised/1` for GenServers to ensure cleanup
- Test the Session → LiveView message flow end-to-end with `Phoenix.LiveViewTest`
- For timing-sensitive tests (debounce, backup tick), use `:erlang.send_after` or `Process.sleep` sparingly
- Keep tests fast — mock external HTTP calls, avoid unnecessary sleeps

## In Claude Code Remote Environment
- Full `mix test` is not available (no hex/deps). Use syntax checking:
  ```bash
  elixir -e 'Code.string_to_quoted(File.read!("test/path/to/test.exs"))'
  ```
- Full test runs happen in CI (GitHub Actions) or local dev
