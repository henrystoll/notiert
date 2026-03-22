defmodule Notiert.Director.Session do
  @moduledoc """
  Per-visitor session process. Holds all fingerprint, behavior, and director state.
  Runs the director loop server-side, pushing actions to the LiveView.
  Dies when the visitor disconnects.
  """
  use GenServer

  require Logger

  alias Notiert.Director.Agent

  @phase_thresholds [
    {0, 0},
    {1, 10_000},
    {2, 25_000},
    {3, 50_000},
    {4, 90_000}
  ]

  # Tick intervals per phase (ms) - slower pacing as requested
  @tick_intervals %{
    0 => 8_000,
    1 => 7_000,
    2 => 7_000,
    3 => 8_000,
    4 => 10_000
  }

  @idle_interval 15_000
  @unfocused_interval 20_000

  # --- Public API ---

  def start_link(%{session_id: session_id} = init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: via(session_id))
  end

  def update_fingerprint(session_id, fingerprint) do
    GenServer.cast(via(session_id), {:fingerprint, fingerprint})
  end

  def update_behavior(session_id, behavior) do
    GenServer.cast(via(session_id), {:behavior, behavior})
  end

  def update_permission(session_id, permission, result, data) do
    GenServer.cast(via(session_id), {:permission, permission, result, data})
  end

  defp via(session_id) do
    {:via, Registry, {Notiert.SessionRegistry, session_id}}
  end

  # --- Callbacks ---

  @impl true
  def init(%{session_id: session_id, live_view_pid: pid}) do
    Process.monitor(pid)

    state = %{
      session_id: session_id,
      live_view_pid: pid,
      started_at: System.monotonic_time(:millisecond),
      tick: 0,
      phase: 0,
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
      action_history: [],
      busy: false
    }

    Logger.info("[session:#{session_id}] Started, first tick in 3s")

    # Start the director loop after a brief delay to let fingerprint data arrive
    Process.send_after(self(), :director_tick, 3_000)

    {:ok, state}
  end

  @impl true
  def handle_cast({:fingerprint, fingerprint}, state) do
    Logger.info("[session:#{state.session_id}] Fingerprint received: #{inspect(fingerprint, pretty: true, limit: :infinity)}")
    {:noreply, %{state | fingerprint: fingerprint}}
  end

  @impl true
  def handle_cast({:behavior, behavior}, state) do
    Logger.debug("[session:#{state.session_id}] Behavior update: attention=#{behavior["attentionPattern"]}, section=#{behavior["currentSection"]}, idle=#{behavior["idleSeconds"]}s, focused=#{behavior["viewportFocused"]}")
    {:noreply, %{state | behavior: behavior}}
  end

  @impl true
  def handle_cast({:permission, permission, result, data}, state) do
    Logger.info("[session:#{state.session_id}] Permission #{permission}: #{result}, data=#{inspect(data)}")
    permissions = Map.put(state.permissions, permission, result)
    enrichment = merge_enrichment(state.enrichment, permission, result, data)
    {:noreply, %{state | permissions: permissions, enrichment: enrichment}}
  end

  @impl true
  def handle_info(:director_tick, %{busy: true} = state) do
    Logger.debug("[session:#{state.session_id}] Tick #{state.tick} skipped (busy)")
    schedule_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:director_tick, state) do
    state = update_phase(state)
    elapsed_s = div(System.monotonic_time(:millisecond) - state.started_at, 1000)

    Logger.info("[session:#{state.session_id}] Tick #{state.tick} firing (phase=#{state.phase}, elapsed=#{elapsed_s}s)")

    # Run director call async to not block the process
    parent = self()

    Task.start(fn ->
      result = Agent.call(build_context(state))
      send(parent, {:director_response, result})
    end)

    {:noreply, %{state | busy: true, tick: state.tick + 1}}
  end

  @impl true
  def handle_info({:director_response, {:ok, actions}}, state) do
    Logger.info("[session:#{state.session_id}] Director returned #{length(actions)} action(s)")

    state =
      Enum.reduce(actions, state, fn action, acc ->
        Logger.info("[session:#{acc.session_id}] Executing: #{summarize_action(action)}")

        # Send action to LiveView
        send(acc.live_view_pid, {:director_action, action})

        # Track in history
        history_entry = %{
          tick: acc.tick,
          tool: action["tool"],
          summary: summarize_action(action)
        }

        mutations =
          if action["tool"] == "rewrite_section" do
            Map.put(acc.mutations, action["section_id"], action["content"])
          else
            acc.mutations
          end

        %{
          acc
          | action_history: [history_entry | acc.action_history] |> Enum.take(8),
            mutations: mutations
        }
      end)

    interval = compute_interval(state)
    Logger.debug("[session:#{state.session_id}] Next tick in #{interval}ms")
    schedule_tick(state)
    {:noreply, %{state | busy: false}}
  end

  @impl true
  def handle_info({:director_response, {:error, reason}}, state) do
    Logger.warning("[session:#{state.session_id}] Director API error: #{inspect(reason)}")
    schedule_tick(state)
    {:noreply, %{state | busy: false}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{live_view_pid: pid} = state) do
    elapsed_s = div(System.monotonic_time(:millisecond) - state.started_at, 1000)
    Logger.info("[session:#{state.session_id}] Visitor disconnected after #{elapsed_s}s, #{state.tick} ticks, #{length(state.action_history)} actions")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp update_phase(state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    new_phase =
      @phase_thresholds
      |> Enum.reverse()
      |> Enum.find_value(0, fn {phase, threshold} ->
        if elapsed >= threshold, do: phase
      end)

    if new_phase != state.phase do
      Logger.info("[session:#{state.session_id}] Phase transition: #{state.phase} -> #{new_phase}")
      send(state.live_view_pid, {:phase_change, new_phase})
    end

    %{state | phase: new_phase}
  end

  defp schedule_tick(state) do
    interval = compute_interval(state)
    Process.send_after(self(), :director_tick, interval)
  end

  defp compute_interval(state) do
    base = Map.get(@tick_intervals, state.phase, 8_000)

    idle_seconds = get_in(state.behavior, ["idle_seconds"]) || 0
    focused = get_in(state.behavior, ["viewport_focused"])

    cond do
      focused == false -> @unfocused_interval
      idle_seconds > 15 -> @idle_interval
      true -> base
    end
  end

  defp build_context(state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.started_at

    %{
      elapsed_seconds: div(elapsed_ms, 1000),
      tick: state.tick,
      phase: state.phase,
      fingerprint: state.fingerprint,
      behavior: state.behavior,
      permissions: state.permissions,
      enrichment: state.enrichment,
      mutations: state.mutations,
      recent_actions: Enum.take(state.action_history, 6)
    }
  end

  defp merge_enrichment(enrichment, "geolocation", "granted", data) do
    Map.put(enrichment, "geolocation", %{
      "latitude" => data["latitude"],
      "longitude" => data["longitude"],
      "accuracy" => data["accuracy"]
    })
  end

  defp merge_enrichment(enrichment, "microphone", "granted", data) do
    Map.put(enrichment, "ambient_noise", data["noise_level"])
  end

  defp merge_enrichment(enrichment, _permission, _result, _data), do: enrichment

  defp summarize_action(%{"tool" => "rewrite_section"} = a) do
    "rewrite_section(#{a["section_id"]}, #{String.slice(a["content"] || "", 0..40)}...)"
  end

  defp summarize_action(%{"tool" => "add_margin_note"} = a) do
    "add_margin_note(#{a["anchor_section"]}, #{String.slice(a["content"] || "", 0..40)}...)"
  end

  defp summarize_action(%{"tool" => "adjust_visual"} = a) do
    vars = a["css_variables"] || %{}
    "adjust_visual(#{inspect(Map.keys(vars))})"
  end

  defp summarize_action(%{"tool" => "show_ghost_cursor"} = a) do
    "show_ghost_cursor(#{a["cursor_label"]}, #{a["behavior"]})"
  end

  defp summarize_action(%{"tool" => "request_browser_permission"} = a) do
    "request_browser_permission(#{a["permission"]})"
  end

  defp summarize_action(%{"tool" => "do_nothing"} = a) do
    "do_nothing(#{a["reason"] || ""})"
  end

  defp summarize_action(a), do: "#{a["tool"]}()"
end
