defmodule Notiert.Director.Phase do
  @moduledoc """
  Named phases for the director's narrative arc.
  The director controls phase transitions — these are not automatic.
  Each phase defines its character, tick interval, and guidance.
  Add, remove, or reorder phases here — everything else references this module.
  """

  @phases [
    %{
      id: :silent,
      label: "Silent",
      tick_interval_ms: 5_000,
      guidance: """
      SILENT: You are invisible. The page is a normal CV. Use do_nothing or imperceptible
      adjust_visual only (shift a color by 1-2 points, nudge letter-spacing by 0.01em).
      Do NOT rewrite content, show cursors, or add notes. The visitor must believe this is
      a completely normal website. You are gathering intelligence. Be patient.
      """
    },
    %{
      id: :subtle,
      label: "Subtle",
      tick_interval_ms: 5_000,
      guidance: """
      SUBTLE: Small, precise adjustments. The visitor should feel something is slightly off
      but not be sure. You may add one margin note that looks like a normal document comment.
      You CAN do tiny rewrites — but ONLY on the section the visitor is currently reading
      (check currentSection and attentionPattern). One word, one phrase, one small detail.
      The edit must be so small they question whether the page always said that.
      No ghost cursor, no permissions. The uncanny valley of web design.
      """
    },
    %{
      id: :suspicious,
      label: "Suspicious",
      tick_interval_ms: 6_000,
      guidance: """
      SUSPICIOUS: The ghost cursor can now appear. You can add knowing margin notes and do
      bolder section rewrites. The visitor should start questioning whether the page is normal.
      Don't explain what's happening — let them figure it out. One change per cycle maximum.
      The reveal is more powerful when they discover it themselves.
      """
    },
    %{
      id: :overt,
      label: "Overt",
      tick_interval_ms: 7_000,
      guidance: """
      OVERT: Drop the pretense. Rewrite sections weaving in collected data — their browser,
      timezone, screen size, reading patterns. Request geolocation if the moment feels right.
      Comment on their Do Not Track header if set. The visitor knows the page is watching them.
      Make it entertaining, not threatening. One action per cycle — let each land.
      """
    },
    %{
      id: :climax,
      label: "The Climax",
      tick_interval_ms: 10_000,
      guidance: """
      THE CLIMAX: Your artistic peak. If they've been here this long, they're in on it.
      Reference everything you've learned. Camera and microphone requests are available now
      but use them only if the narrative calls for it — the joke is that a CV is asking.
      Build to a satisfying conclusion. Make each action count. End on a note that makes them
      want to work with Henry, not run away.
      """
    }
  ]

  @phase_ids Enum.map(@phases, & &1.id)

  @doc "All phases in order."
  def all, do: @phases

  @doc "List of valid phase ids."
  def valid_ids, do: @phase_ids

  @doc "Is this a valid phase id?"
  def valid?(id), do: id in @phase_ids

  @doc "Look up a phase definition by id."
  def get(id) do
    Enum.find(@phases, fn p -> p.id == id end)
  end

  @doc "Get the tick interval for a phase id."
  def tick_interval(phase_id) do
    case get(phase_id) do
      nil -> 8_000
      p -> p.tick_interval_ms
    end
  end

  @doc "Get the guidance prompt for a phase id."
  def guidance(phase_id) do
    case get(phase_id) do
      nil -> ""
      p -> p.guidance
    end
  end

  @doc "Human-readable label for a phase id."
  def label(phase_id) do
    case get(phase_id) do
      nil -> to_string(phase_id)
      p -> p.label
    end
  end

  @doc "Should the toolbar be visible in this phase?"
  def toolbar_visible?(phase_id), do: phase_id in [:suspicious, :overt, :climax]

  @doc "Should the ghost viewer avatar be visible?"
  def ghost_viewer_visible?(phase_id), do: phase_id in [:overt, :climax]

  @doc """
  Suggest a phase based on elapsed time. Used only in the prompt as a hint —
  the director is free to ignore this and move at its own pace.
  """
  def suggested_for_elapsed(elapsed_ms) do
    cond do
      elapsed_ms < 6_000 -> :silent
      elapsed_ms < 18_000 -> :subtle
      elapsed_ms < 40_000 -> :suspicious
      elapsed_ms < 75_000 -> :overt
      true -> :climax
    end
  end
end
