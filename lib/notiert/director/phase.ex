defmodule Notiert.Director.Phase do
  @moduledoc """
  Named phases for the director's narrative arc.
  Each phase defines its name, time threshold, tick interval, and guidance prompt.
  Add, remove, or reorder phases here — everything else references this module.
  """

  @phases [
    %{
      id: :silent,
      label: "Silent",
      threshold_ms: 0,
      tick_interval_ms: 8_000,
      guidance:
        "SILENT: You are invisible. Collect data. Use do_nothing or imperceptible adjust_visual only. Do NOT rewrite content, show cursors, or add notes. The visitor must believe this is a normal website."
    },
    %{
      id: :subtle,
      label: "Subtle",
      threshold_ms: 10_000,
      tick_interval_ms: 7_000,
      guidance:
        "SUBTLE: Micro adjustments only. The visitor should feel something is slightly off but not be sure. One margin note maximum, and it should look like a normal document comment. No rewrites, no ghost cursor, no permissions."
    },
    %{
      id: :suspicious,
      label: "Suspicious",
      threshold_ms: 25_000,
      tick_interval_ms: 7_000,
      guidance:
        "SUSPICIOUS: The toolbar is now visible. You can show the ghost cursor, add knowing margin notes, and do your first section rewrite. The visitor should start questioning whether the page is normal. Don't explain — let them figure it out. Keep it slow — one change per cycle maximum."
    },
    %{
      id: :overt,
      label: "Overt",
      threshold_ms: 50_000,
      tick_interval_ms: 8_000,
      guidance:
        "OVERT: Drop the pretense. Rewrite sections with direct references to collected data. Request geolocation. Comment on their Do Not Track header, browser, screen size, reading patterns. The visitor knows the page is watching — make it entertaining. Still only one action per cycle."
    },
    %{
      id: :climax,
      label: "The Climax",
      threshold_ms: 90_000,
      tick_interval_ms: 10_000,
      guidance:
        "THE CLIMAX: Your artistic peak. Be bold but measured. If they've been here this long, they're in on it. Reference what you've learned. Build to a satisfying conclusion. One action per cycle — make each one count."
    }
  ]

  @doc "All phases in order."
  def all, do: @phases

  @doc "Look up a phase definition by id."
  def get(id) do
    Enum.find(@phases, fn p -> p.id == id end)
  end

  @doc "Determine which phase applies for a given elapsed time in ms."
  def for_elapsed(elapsed_ms) do
    @phases
    |> Enum.reverse()
    |> Enum.find(List.first(@phases), fn p -> elapsed_ms >= p.threshold_ms end)
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
end
