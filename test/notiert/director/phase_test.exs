defmodule Notiert.Director.PhaseTest do
  use ExUnit.Case, async: true

  alias Notiert.Director.Phase

  describe "all/0" do
    test "returns all phases in order" do
      phases = Phase.all()
      assert length(phases) >= 3
      ids = Enum.map(phases, & &1.id)
      assert :silent in ids
      assert :climax in ids
    end
  end

  describe "valid?/1" do
    test "recognizes valid phase ids" do
      assert Phase.valid?(:silent)
      assert Phase.valid?(:subtle)
      assert Phase.valid?(:suspicious)
      assert Phase.valid?(:overt)
      assert Phase.valid?(:climax)
    end

    test "rejects invalid phase ids" do
      refute Phase.valid?(:nonexistent)
      refute Phase.valid?(:loud)
      refute Phase.valid?(nil)
    end
  end

  describe "get/1" do
    test "returns phase definition" do
      phase = Phase.get(:silent)
      assert phase.id == :silent
      assert phase.label == "Silent"
      assert is_integer(phase.tick_interval_ms)
      assert is_binary(phase.guidance)
    end

    test "returns nil for invalid phase" do
      assert Phase.get(:nonexistent) == nil
    end
  end

  describe "tick_interval/1" do
    test "returns interval for each phase" do
      for phase <- Phase.valid_ids() do
        interval = Phase.tick_interval(phase)
        assert is_integer(interval)
        assert interval > 0
      end
    end

    test "returns default for unknown phase" do
      assert Phase.tick_interval(:unknown) == 8_000
    end
  end

  describe "guidance/1" do
    test "returns non-empty guidance for each phase" do
      for phase <- Phase.valid_ids() do
        guidance = Phase.guidance(phase)
        assert is_binary(guidance)
        assert String.length(guidance) > 10
      end
    end
  end

  describe "label/1" do
    test "returns human-readable labels" do
      assert Phase.label(:silent) == "Silent"
      assert Phase.label(:climax) == "The Climax"
    end

    test "falls back to string for unknown phase" do
      assert Phase.label(:unknown) == "unknown"
    end
  end

  describe "toolbar_visible?/1" do
    test "toolbar hidden in early phases" do
      refute Phase.toolbar_visible?(:silent)
      refute Phase.toolbar_visible?(:subtle)
    end

    test "toolbar visible in later phases" do
      assert Phase.toolbar_visible?(:suspicious)
      assert Phase.toolbar_visible?(:overt)
      assert Phase.toolbar_visible?(:climax)
    end
  end

  describe "ghost_viewer_visible?/1" do
    test "ghost hidden until overt" do
      refute Phase.ghost_viewer_visible?(:silent)
      refute Phase.ghost_viewer_visible?(:subtle)
      refute Phase.ghost_viewer_visible?(:suspicious)
    end

    test "ghost visible in overt and climax" do
      assert Phase.ghost_viewer_visible?(:overt)
      assert Phase.ghost_viewer_visible?(:climax)
    end
  end

  describe "suggested_for_elapsed/1" do
    test "suggests silent early" do
      assert Phase.suggested_for_elapsed(0) == :silent
      assert Phase.suggested_for_elapsed(5_000) == :silent
    end

    test "suggests subtle after 10s" do
      assert Phase.suggested_for_elapsed(10_000) == :subtle
      assert Phase.suggested_for_elapsed(20_000) == :subtle
    end

    test "suggests climax after 90s" do
      assert Phase.suggested_for_elapsed(90_000) == :climax
      assert Phase.suggested_for_elapsed(300_000) == :climax
    end
  end
end
