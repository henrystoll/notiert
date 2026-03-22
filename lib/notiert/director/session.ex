defmodule Notiert.Director.Session do
  @moduledoc """
  Per-visitor session process. Holds all fingerprint, behavior, and director state.
  Runs the director loop server-side, pushing actions to the LiveView.
  Dies when the visitor disconnects.
  """
  use GenServer

  require Logger

  alias Notiert.Director.{Agent, Phase}

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

    now = System.monotonic_time(:millisecond)

    state = %{
      session_id: session_id,
      live_view_pid: pid,
      started_at: now,
      tick: 0,
      phase: :silent,
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
      # Full interaction log — every event in chronological order, never truncated.
      # Each entry: %{type, tick, elapsed_s, timestamp, ...payload}
      # Types: :action, :observation, :phase_change, :permission, :fingerprint
      # Structured for future DB persistence.
      event_log: [],
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

    event = build_event(state, :fingerprint, %{data: fingerprint})
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    {:noreply, %{state | fingerprint: fingerprint, event_log: state.event_log ++ [event]}}
  end

  @impl true
  def handle_cast({:behavior, behavior}, state) do
    # Log notable behavioral changes as observations (not every 2s update)
    state = maybe_log_behavior_observation(state, behavior)

    Logger.debug("[session:#{state.session_id}] Behavior update: attention=#{behavior["attentionPattern"]}, section=#{behavior["currentSection"]}, idle=#{behavior["idleSeconds"]}s, focused=#{behavior["viewportFocused"]}")
    {:noreply, %{state | behavior: behavior}}
  end

  @impl true
  def handle_cast({:permission, permission, result, data}, state) do
    Logger.info("[session:#{state.session_id}] Permission #{permission}: #{result}, data=#{inspect(data)}")

    event = build_event(state, :permission, %{permission: permission, result: result, data: data})
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    permissions = Map.put(state.permissions, permission, result)
    enrichment = merge_enrichment(state.enrichment, permission, result, data)
    {:noreply, %{state | permissions: permissions, enrichment: enrichment, event_log: state.event_log ++ [event]}}
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

    Logger.info("[session:#{state.session_id}] Tick #{state.tick} firing (phase=#{Phase.label(state.phase)}, elapsed=#{elapsed_s}s)")

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

        # Record full action in event log (preserves all fields for DB)
        event = build_event(acc, :action, %{
          tool: action["tool"],
          params: action,
          summary: summarize_action(action)
        })
        Logger.info("[session:#{acc.session_id}] [event_log] #{format_event(event)}")

        mutations =
          if action["tool"] == "rewrite_section" do
            Map.put(acc.mutations, action["section_id"], action["content"])
          else
            acc.mutations
          end

        %{acc | event_log: acc.event_log ++ [event], mutations: mutations}
      end)

    interval = compute_interval(state)
    Logger.debug("[session:#{state.session_id}] Next tick in #{interval}ms (#{length(state.event_log)} events in log)")
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
    action_count = Enum.count(state.event_log, fn e -> e.type == :action end)
    observation_count = Enum.count(state.event_log, fn e -> e.type == :observation end)

    Logger.info("""
    [session:#{state.session_id}] === SESSION ENDED ===
      Duration: #{elapsed_s}s
      Ticks: #{state.tick}
      Actions: #{action_count}
      Observations: #{observation_count}
      Total events: #{length(state.event_log)}
      Final phase: #{Phase.label(state.phase)}
      Mutations: #{inspect(Map.keys(state.mutations))}
    [session:#{state.session_id}] === FULL EVENT LOG ===
    #{state.event_log |> Enum.map(&format_event/1) |> Enum.join("\n")}
    [session:#{state.session_id}] === END EVENT LOG ===
    """)

    # TODO: persist state.event_log to database here
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp update_phase(state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    new_phase = Phase.for_elapsed(elapsed).id

    if new_phase != state.phase do
      Logger.info("[session:#{state.session_id}] Phase transition: #{Phase.label(state.phase)} -> #{Phase.label(new_phase)}")
      send(state.live_view_pid, {:phase_change, new_phase})

      event = build_event(state, :phase_change, %{from: state.phase, to: new_phase})
      Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")
      %{state | phase: new_phase, event_log: state.event_log ++ [event]}
    else
      %{state | phase: new_phase}
    end
  end

  defp schedule_tick(state) do
    interval = compute_interval(state)
    Process.send_after(self(), :director_tick, interval)
  end

  defp compute_interval(state) do
    base = Phase.tick_interval(state.phase)

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
      event_log: state.event_log
    }
  end

  # --- Event log helpers ---

  defp build_event(state, type, payload) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.started_at

    Map.merge(payload, %{
      type: type,
      tick: state.tick,
      elapsed_s: div(elapsed_ms, 1000),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp format_event(%{type: :action} = e) do
    "t=#{e.elapsed_s}s tick=#{e.tick} ACTION #{e.summary}"
  end

  defp format_event(%{type: :observation} = e) do
    "t=#{e.elapsed_s}s tick=#{e.tick} OBSERVATION #{e.detail}"
  end

  defp format_event(%{type: :phase_change} = e) do
    "t=#{e.elapsed_s}s tick=#{e.tick} PHASE #{Phase.label(e.from)}->#{Phase.label(e.to)}"
  end

  defp format_event(%{type: :permission} = e) do
    "t=#{e.elapsed_s}s tick=#{e.tick} PERMISSION #{e.permission}=#{e.result}"
  end

  defp format_event(%{type: :fingerprint} = e) do
    ua = get_in(e, [:data, "userAgent"]) || "unknown"
    "t=#{e.elapsed_s}s tick=#{e.tick} FINGERPRINT ua=#{String.slice(ua, 0..60)}"
  end

  defp format_event(e) do
    "t=#{e.elapsed_s}s tick=#{e.tick} #{e.type}"
  end

  # Detect notable behavioral changes and log them as observations
  defp maybe_log_behavior_observation(state, new_behavior) do
    old = state.behavior
    events = []

    # Attention pattern changed
    events =
      if old["attentionPattern"] && old["attentionPattern"] != new_behavior["attentionPattern"] do
        e = build_event(state, :observation, %{
          detail: "Attention changed: #{old["attentionPattern"]} -> #{new_behavior["attentionPattern"]}"
        })
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        events
      end

    # Section changed
    events =
      if old["currentSection"] && old["currentSection"] != new_behavior["currentSection"] do
        e = build_event(state, :observation, %{
          detail: "Viewing section: #{new_behavior["currentSection"]} (was #{old["currentSection"]})"
        })
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        events
      end

    # Tab away / return
    events =
      if old["viewportFocused"] == true && new_behavior["viewportFocused"] == false do
        e = build_event(state, :observation, %{detail: "Visitor tabbed away"})
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        if old["viewportFocused"] == false && new_behavior["viewportFocused"] == true do
          away_ms = new_behavior["tabAwayTotalMs"] || 0
          e = build_event(state, :observation, %{detail: "Visitor returned (total away: #{div(away_ms, 1000)}s)"})
          Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
          [e | events]
        else
          events
        end
      end

    # Text selection
    events =
      with old_sel when is_list(old_sel) <- old["textSelections"],
           new_sel when is_list(new_sel) <- new_behavior["textSelections"],
           true <- length(new_sel) > length(old_sel) do
        latest = List.last(new_sel)
        e = build_event(state, :observation, %{
          detail: "Text selected: \"#{String.slice(latest["text"] || "", 0..80)}\""
        })
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        _ -> events
      end

    if events == [] do
      state
    else
      %{state | event_log: state.event_log ++ Enum.reverse(events)}
    end
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
