defmodule Notiert.Director.AgentTest do
  use ExUnit.Case, async: true

  alias Notiert.Director.Agent

  describe "call/1 without API key" do
    test "returns do_nothing when no API key is configured" do
      context = build_test_context()
      assert {:ok, [%{"tool" => "do_nothing"}]} = Agent.call(context)
    end
  end

  # These tests verify prompt construction by calling the private build_prompt
  # through the public call/1 interface. The prompt is logged, so we can verify
  # it doesn't crash on various inputs.

  describe "prompt building with various contexts" do
    test "handles empty fingerprint" do
      context = build_test_context(%{fingerprint: %{}})
      assert {:ok, _} = Agent.call(context)
    end

    test "handles empty behavior" do
      context = build_test_context(%{behavior: %{}})
      assert {:ok, _} = Agent.call(context)
    end

    test "handles empty event log" do
      context = build_test_context(%{event_log: []})
      assert {:ok, _} = Agent.call(context)
    end

    test "handles populated event log" do
      events = [
        %{type: :fingerprint, tick: 0, elapsed_s: 0, timestamp: "2026-03-22T12:00:00Z", data: %{"userAgent" => "Test"}},
        %{type: :observation, tick: 1, elapsed_s: 5, timestamp: "2026-03-22T12:00:05Z", detail: "Attention changed: browsing -> reading"},
        %{type: :phase_change, tick: 2, elapsed_s: 10, timestamp: "2026-03-22T12:00:10Z", from: :silent, to: :subtle, reason: "visitor engaged"},
        %{type: :action, tick: 3, elapsed_s: 15, timestamp: "2026-03-22T12:00:15Z", tool: "add_margin_note", params: %{"anchor_section" => "about", "content" => "Nice browser."}, summary: "add_margin_note(about)"},
        %{type: :action, tick: 4, elapsed_s: 20, timestamp: "2026-03-22T12:00:20Z", tool: "do_nothing", params: %{"reason" => "letting note settle"}, summary: "do_nothing(letting note settle)"},
        %{type: :permission_result, tick: 5, elapsed_s: 50, elapsed_ms: 50_000, timestamp: "2026-03-22T12:00:50Z", permission: "geolocation", result: "denied", hesitation_ms: 8200, hesitation_desc: "considered (8200ms) — they thought about it", data: %{}}
      ]

      context = build_test_context(%{event_log: events})
      assert {:ok, _} = Agent.call(context)
    end

    test "handles full fingerprint" do
      fp = %{
        "userAgent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "platform" => "MacIntel",
        "language" => "en-US",
        "doNotTrack" => "1",
        "screenWidth" => 2560,
        "screenHeight" => 1440,
        "pixelRatio" => 2,
        "colorDepth" => 24,
        "timezone" => "Europe/Copenhagen",
        "timezoneOffset" => -60,
        "localHour" => 23,
        "dayOfWeek" => "Saturday",
        "referrer" => "https://linkedin.com/in/someone",
        "darkMode" => true,
        "reducedMotion" => false,
        "cpuCores" => 10,
        "deviceMemory" => 16,
        "maxTouchPoints" => 0,
        "webglRenderer" => "Apple M1 Pro",
        "canvasHash" => "a1b2c3d4",
        "connectionType" => "4g",
        "connectionDownlink" => 10,
        "connectionRtt" => 50,
        "viewportWidth" => 1200,
        "viewportHeight" => 800,
        "batteryLevel" => 87,
        "batteryCharging" => false
      }

      context = build_test_context(%{fingerprint: fp})
      assert {:ok, _} = Agent.call(context)
    end

    test "handles mutations" do
      context = build_test_context(%{
        mutations: %{
          "about" => "Data Scientist who noticed your Do Not Track header.",
          "skills" => "Python, Elixir, and knowing too much about your browser."
        }
      })

      assert {:ok, _} = Agent.call(context)
    end

    test "handles text selections in behavior" do
      context = build_test_context(%{
        behavior: %{
          "attentionPattern" => "reading",
          "currentSection" => "experience",
          "inputDevice" => "mouse",
          "scrollVelocity" => 30,
          "idleSeconds" => 0,
          "tabAwayCount" => 1,
          "tabAwayTotalMs" => 5000,
          "textSelections" => [%{"text" => "Data Scientist at Danske Bank"}],
          "viewportFocused" => true,
          "sectionDwells" => %{
            "header" => %{"totalMs" => 3000, "entries" => 1},
            "about" => %{"totalMs" => 12000, "entries" => 2}
          }
        }
      })

      assert {:ok, _} = Agent.call(context)
    end
  end

  defp build_test_context(overrides \\ %{}) do
    Map.merge(
      %{
        elapsed_seconds: 30,
        tick: 4,
        phase: :suspicious,
        suggested_phase: :suspicious,
        fingerprint: %{},
        behavior: %{},
        permissions: %{
          "geolocation" => "not_asked",
          "camera" => "not_asked",
          "microphone" => "not_asked",
          "notifications" => "not_asked"
        },
        enrichment: %{},
        mutations: %{},
        event_log: [],
        trigger: :interval,
        trigger_meta: %{},
        new_events: []
      },
      overrides
    )
  end
end
