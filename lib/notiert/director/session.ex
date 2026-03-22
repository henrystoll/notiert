defmodule Notiert.Director.Session do
  @moduledoc """
  Per-visitor session process. Event-driven director loop.

  The director fires on meaningful events (permission result, section change,
  text selection, tab return, fingerprint) with a periodic backup tick.
  Events are debounced — a short delay collects related events before calling
  the LLM. Only one API call at a time (mutex via `busy` flag).

  Each director call receives:
  - trigger: why this call was fired (event type + details)
  - new_events: events since last director call
  - event_log: full session history
  - current state: fingerprint, behavior, permissions, mutations
  """
  use GenServer

  require Logger

  alias Notiert.Director.{Agent, Enrichment, Phase}

  # Backup tick interval — fires even without events, so the director stays alive
  @backup_tick_ms 10_000
  # Debounce delay — collect events before firing director
  @debounce_ms 800
  # Idle threshold — slow down when visitor is idle
  @idle_threshold_s 15
  @idle_tick_ms 15_000

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
  def init(%{session_id: session_id, live_view_pid: pid} = args) do
    Process.monitor(pid)

    now = System.monotonic_time(:millisecond)
    visitor_ip = args[:visitor_ip]

    state = %{
      session_id: session_id,
      live_view_pid: pid,
      started_at: now,
      tick: 0,
      phase: :silent,
      fingerprint: %{},
      behavior: %{},
      visitor_ip: visitor_ip,
      permissions: %{
        "geolocation" => "not_asked",
        "camera" => "not_asked",
        "microphone" => "not_asked",
        "notifications" => "not_asked"
      },
      enrichment: %{},
      mutations: %{},
      # Full event log — never truncated
      event_log: [],
      # Events since last director call — cleared after each call
      pending_events: [],
      # Mutex: only one API call at a time
      busy: false,
      # Debounce timer ref
      debounce_ref: nil,
      # Backup tick timer ref
      backup_tick_ref: nil,
      # Track last director call time
      last_call_at: now,
      # Permission request timestamps for measuring hesitation
      permission_requests: %{},
      # Visitor focus state
      visitor_focused: true,
      paused: false
    }

    Logger.info("[session:#{session_id}] Started, IP: #{visitor_ip || "unknown"}")

    # Kick off IP enrichment immediately
    if visitor_ip do
      Enrichment.lookup_ip(visitor_ip, self())
    end

    # Schedule backup tick
    backup_ref = Process.send_after(self(), :backup_tick, @backup_tick_ms)

    {:ok, %{state | backup_tick_ref: backup_ref}}
  end

  # --- Event handlers ---

  @impl true
  def handle_cast({:fingerprint, fingerprint}, state) do
    ua = fingerprint["userAgent"] || "unknown"
    screen = "#{fingerprint["screenWidth"]}x#{fingerprint["screenHeight"]}"
    tz = fingerprint["timezone"] || "unknown"
    dnt = fingerprint["doNotTrack"] || "not set"
    touch = fingerprint["maxTouchPoints"] || 0
    device_type = if touch > 0, do: "touch device (#{touch} points)", else: "desktop"

    Logger.info("""
    [session:#{state.session_id}] New visitor identified:
      Browser: #{String.slice(ua, 0..80)}
      Screen: #{screen} @ #{fingerprint["pixelRatio"] || "?"}x (#{device_type})
      Timezone: #{tz}, local time: #{fingerprint["localHour"]}:00 #{fingerprint["dayOfWeek"] || ""}
      Do Not Track: #{dnt}
      Referrer: #{fingerprint["referrer"] || "direct"}
      Connection: #{fingerprint["connectionType"] || "unknown"} (#{fingerprint["connectionDownlink"] || "?"}Mbps)
      Dark mode: #{fingerprint["darkMode"]}, Reduced motion: #{fingerprint["reducedMotion"]}
    """)

    event = build_event(state, :fingerprint, %{data: fingerprint})
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    state = %{state | fingerprint: fingerprint}
    state = append_event(state, event)
    state = queue_trigger(state, :fingerprint, %{})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:behavior, behavior}, state) do
    # Detect notable changes and log as events
    {state, notable_events} = detect_behavior_events(state, behavior)

    # Handle focus changes
    state = handle_focus_change(state, behavior)

    Logger.debug("[session:#{state.session_id}] Behavior update: attention=#{behavior["attentionPattern"]}, section=#{behavior["currentSection"]}, idle=#{behavior["idleSeconds"]}s, focused=#{behavior["viewportFocused"]}")

    state = %{state | behavior: behavior}

    # If there were notable events, trigger director
    state =
      if notable_events != [] do
        # Determine the most important trigger
        trigger_type = pick_trigger_type(notable_events)
        queue_trigger(state, trigger_type, %{events: notable_events})
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:permission, permission, result, data}, state) do
    now_ms = System.monotonic_time(:millisecond)

    # Calculate hesitation time
    request_time = Map.get(state.permission_requests, permission)
    hesitation_ms = if request_time, do: now_ms - request_time, else: nil

    hesitation_desc =
      cond do
        is_nil(hesitation_ms) -> "unknown timing"
        hesitation_ms < 2_000 -> "instant (#{hesitation_ms}ms) — eager"
        hesitation_ms < 5_000 -> "quick (#{hesitation_ms}ms)"
        hesitation_ms < 10_000 -> "considered (#{hesitation_ms}ms) — they thought about it"
        hesitation_ms < 30_000 -> "hesitant (#{hesitation_ms}ms) — long pause before deciding"
        true -> "very slow (#{hesitation_ms}ms) — may have been distracted"
      end

    extra = case {permission, result} do
      {"geolocation", "granted"} -> " (lat=#{data["latitude"]}, lng=#{data["longitude"]})"
      {"microphone", "granted"} -> " (noise_level=#{data["noise_level"]})"
      _ -> ""
    end
    Logger.info("[session:#{state.session_id}] Visitor #{result} #{permission} permission#{extra} — #{hesitation_desc}")

    event = build_event(state, :permission_result, %{
      permission: permission,
      result: result,
      data: data,
      hesitation_ms: hesitation_ms,
      hesitation_desc: hesitation_desc
    })
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    permissions = Map.put(state.permissions, permission, result)
    enrichment = merge_enrichment(state.enrichment, permission, result, data)

    # Kick off reverse geocode if geolocation was granted
    if permission == "geolocation" && result == "granted" && data["latitude"] && data["longitude"] do
      Enrichment.reverse_geocode(data["latitude"], data["longitude"], self())
    end

    state = %{state | permissions: permissions, enrichment: enrichment}
    state = append_event(state, event)

    # Permission results ALWAYS trigger the director immediately (no debounce)
    state = trigger_now(state, :permission_result, %{
      permission: permission,
      result: result,
      hesitation_ms: hesitation_ms,
      hesitation_desc: hesitation_desc
    })

    {:noreply, state}
  end

  # --- Tick / trigger handlers ---

  @impl true
  def handle_info(:backup_tick, %{paused: true} = state) do
    Logger.debug("[session:#{state.session_id}] Backup tick suppressed (paused)")
    {:noreply, state}
  end

  @impl true
  def handle_info(:backup_tick, state) do
    # Reschedule backup tick
    idle_seconds = get_in(state.behavior, ["idleSeconds"]) || 0
    interval = if idle_seconds > @idle_threshold_s, do: @idle_tick_ms, else: @backup_tick_ms
    backup_ref = Process.send_after(self(), :backup_tick, interval)
    state = %{state | backup_tick_ref: backup_ref}

    if state.busy do
      Logger.debug("[session:#{state.session_id}] Backup tick skipped (busy)")
      {:noreply, state}
    else
      # Only fire if enough time has passed since last call
      time_since_last = System.monotonic_time(:millisecond) - state.last_call_at
      if time_since_last > div(@backup_tick_ms, 2) do
        fire_director(state, :interval, %{idle_seconds: idle_seconds})
      else
        Logger.debug("[session:#{state.session_id}] Backup tick skipped (recent call)")
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info(:debounced_trigger, state) do
    state = %{state | debounce_ref: nil}

    if state.busy do
      # Director is busy — re-debounce so we don't lose the trigger
      Logger.debug("[session:#{state.session_id}] Debounced trigger deferred (busy)")
      ref = Process.send_after(self(), :debounced_trigger, @debounce_ms)
      {:noreply, %{state | debounce_ref: ref}}
    else
      # Get the most recent trigger reason from pending events
      trigger_type = infer_trigger_from_pending(state.pending_events)
      fire_director(state, trigger_type, %{})
    end
  end

  @impl true
  def handle_info(:immediate_trigger, state) do
    if state.busy do
      # Busy — fall back to debounce
      Logger.debug("[session:#{state.session_id}] Immediate trigger deferred (busy)")
      ref = Process.send_after(self(), :debounced_trigger, @debounce_ms)
      {:noreply, %{state | debounce_ref: ref}}
    else
      trigger_type = infer_trigger_from_pending(state.pending_events)
      fire_director(state, trigger_type, %{})
    end
  end

  # --- Enrichment results ---

  @impl true
  def handle_info({:enrichment_result, :ip_lookup, {:ok, ip_data}}, state) do
    Logger.info("[session:#{state.session_id}] IP enrichment: #{ip_data.city}, #{ip_data.country} — #{ip_data.org}")

    enrichment = Map.put(state.enrichment, "ip", ip_data)

    event = build_event(state, :enrichment, %{
      source: :ip_lookup,
      detail: "IP resolved: #{ip_data.org || "unknown org"}, #{ip_data.city}, #{ip_data.country}"
    })
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    state = %{state | enrichment: enrichment}
    state = append_event(state, event)
    state = queue_trigger(state, :enrichment, %{source: :ip_lookup})

    {:noreply, state}
  end

  @impl true
  def handle_info({:enrichment_result, :ip_lookup, {:error, reason}}, state) do
    Logger.warning("[session:#{state.session_id}] IP enrichment failed: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:enrichment_result, :reverse_geocode, {:ok, geo_data}}, state) do
    place = geo_data.place || geo_data.road || geo_data.neighbourhood || geo_data.city
    Logger.info("[session:#{state.session_id}] Geocode enrichment: #{place}, #{geo_data.city}, #{geo_data.country}")

    enrichment = Map.put(state.enrichment, "location", geo_data)

    event = build_event(state, :enrichment, %{
      source: :reverse_geocode,
      detail: "Location: #{geo_data.display_name}"
    })
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    state = %{state | enrichment: enrichment}
    state = append_event(state, event)
    # Location is high-value — trigger immediately
    state = trigger_now(state, :enrichment, %{source: :reverse_geocode})

    {:noreply, state}
  end

  @impl true
  def handle_info({:enrichment_result, :reverse_geocode, {:error, reason}}, state) do
    Logger.warning("[session:#{state.session_id}] Geocode enrichment failed: #{inspect(reason)}")
    {:noreply, state}
  end

  # --- Director responses ---

  @impl true
  def handle_info({:director_response, {:ok, actions}}, state) do
    Logger.info("[session:#{state.session_id}] Director returned #{length(actions)} action(s)")

    state =
      Enum.reduce(actions, state, fn action, acc ->
        execute_action(action, acc)
      end)

    # Send updated event log to LiveView
    send(state.live_view_pid, {:event_log_update, state.event_log})

    {:noreply, %{state | busy: false, last_call_at: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info({:director_response, {:error, reason}}, state) do
    case reason do
      {:api_error, status} ->
        Logger.warning("[session:#{state.session_id}] Anthropic API returned HTTP #{status}")
      {:json_decode, _} ->
        Logger.warning("[session:#{state.session_id}] Failed to parse Anthropic API response")
      _ ->
        Logger.warning("[session:#{state.session_id}] Director API call failed: #{inspect(reason)}")
    end

    {:noreply, %{state | busy: false, last_call_at: System.monotonic_time(:millisecond)}}
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

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Core: fire the director ---

  defp fire_director(state, trigger_type, trigger_meta) do
    elapsed_s = div(System.monotonic_time(:millisecond) - state.started_at, 1000)
    pending_count = length(state.pending_events)

    Logger.info("[session:#{state.session_id}] Director call ##{state.tick} (trigger=#{trigger_type}, #{pending_count} new events, phase=#{Phase.label(state.phase)}, elapsed=#{elapsed_s}s)")

    context = build_context(state, trigger_type, trigger_meta)
    parent = self()

    Task.start(fn ->
      result = Agent.call(context)
      send(parent, {:director_response, result})
    end)

    # Move pending events to "seen" — clear the pending buffer
    {:noreply, %{state | busy: true, tick: state.tick + 1, pending_events: []}}
  end

  # --- Trigger management ---

  # Queue a trigger with debounce — collects nearby events
  defp queue_trigger(state, _trigger_type, _meta) do
    if state.debounce_ref do
      # Already debouncing — the pending events will be included
      state
    else
      ref = Process.send_after(self(), :debounced_trigger, @debounce_ms)
      %{state | debounce_ref: ref}
    end
  end

  # Fire immediately (no debounce) — for high-priority events like permission results
  defp trigger_now(state, _trigger_type, _meta) do
    # Cancel any pending debounce
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    send(self(), :immediate_trigger)
    %{state | debounce_ref: nil}
  end

  defp infer_trigger_from_pending([]), do: :interval
  defp infer_trigger_from_pending(events) do
    # Pick the most important event type as the trigger
    priority = [:permission_result, :enrichment, :text_selection, :tab_return, :section_change, :attention_change, :fingerprint, :observation]

    events
    |> Enum.map(& &1.type)
    |> Enum.min_by(fn type ->
      Enum.find_index(priority, &(&1 == type)) || 999
    end)
  end

  # --- Behavior event detection ---

  defp detect_behavior_events(state, new_behavior) do
    old = state.behavior
    events = []

    # Attention pattern changed
    events =
      if old["attentionPattern"] && old["attentionPattern"] != new_behavior["attentionPattern"] do
        e = build_event(state, :attention_change, %{
          detail: "Attention changed: #{old["attentionPattern"]} -> #{new_behavior["attentionPattern"]}",
          from: old["attentionPattern"],
          to: new_behavior["attentionPattern"]
        })
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        events
      end

    # Section changed — only log if they spent meaningful time on the previous section
    # (skip rapid scroll-through section changes that just add noise)
    events =
      if old["currentSection"] && old["currentSection"] != new_behavior["currentSection"] do
        dwell_ms = get_in(old, ["sectionDwells", old["currentSection"], "totalMs"]) || 0

        if dwell_ms > 2000 do
          e = build_event(state, :section_change, %{
            detail: "Moved to #{new_behavior["currentSection"]} (spent #{div(dwell_ms, 1000)}s on #{old["currentSection"]})",
            from: old["currentSection"],
            to: new_behavior["currentSection"],
            dwell_ms: dwell_ms
          })
          Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
          [e | events]
        else
          # Still trigger director but don't clutter the event log
          events
        end
      else
        events
      end

    # Tab return (not tab-away — we trigger on return because that's when director should react)
    events =
      if old["viewportFocused"] == false && new_behavior["viewportFocused"] == true do
        away_ms = new_behavior["tabAwayTotalMs"] || 0
        e = build_event(state, :tab_return, %{
          detail: "Visitor returned (total away: #{div(away_ms, 1000)}s)",
          total_away_ms: away_ms
        })
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        if old["viewportFocused"] == true && new_behavior["viewportFocused"] == false do
          e = build_event(state, :observation, %{detail: "Visitor tabbed away"})
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
        e = build_event(state, :text_selection, %{
          detail: "Text selected: \"#{String.slice(latest["text"] || "", 0..80)}\"",
          text: latest["text"]
        })
        Logger.info("[session:#{state.session_id}] [event_log] #{format_event(e)}")
        [e | events]
      else
        _ -> events
      end

    events = Enum.reverse(events)
    state = Enum.reduce(events, state, fn e, acc -> append_event(acc, e) end)
    {state, events}
  end

  defp pick_trigger_type([]), do: :interval
  defp pick_trigger_type(events) do
    # Return the highest-priority event type
    types = Enum.map(events, & &1.type)
    cond do
      :text_selection in types -> :text_selection
      :tab_return in types -> :tab_return
      :section_change in types -> :section_change
      :attention_change in types -> :attention_change
      true -> :observation
    end
  end

  # --- Focus handling ---

  defp handle_focus_change(state, new_behavior) do
    was_focused = state.visitor_focused
    now_focused = new_behavior["viewportFocused"] != false

    cond do
      was_focused and not now_focused ->
        Logger.info("[session:#{state.session_id}] Visitor lost focus — pausing director")
        %{state | visitor_focused: false, paused: true}

      not was_focused and now_focused ->
        Logger.info("[session:#{state.session_id}] Visitor returned — resuming director")
        %{state | visitor_focused: true, paused: false}

      true ->
        state
    end
  end

  # --- Action execution ---

  defp execute_action(%{"tool" => "change_phase"} = action, state) do
    new_phase = String.to_existing_atom(action["phase"])
    reason = action["reason"] || ""

    if Phase.valid?(new_phase) and new_phase != state.phase do
      Logger.info("[session:#{state.session_id}] Phase change: #{Phase.label(state.phase)} -> #{Phase.label(new_phase)} (#{reason})")
      send(state.live_view_pid, {:phase_change, new_phase})

      event = build_event(state, :phase_change, %{from: state.phase, to: new_phase, reason: reason})
      Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

      action_event = build_event(state, :action, %{
        tool: "change_phase",
        params: action,
        summary: "change_phase(#{Phase.label(new_phase)}, #{reason})"
      })
      Logger.info("[session:#{state.session_id}] [event_log] #{format_event(action_event)}")

      %{state | phase: new_phase}
      |> append_event(event)
      |> append_event(action_event)
    else
      Logger.debug("[session:#{state.session_id}] Phase change ignored (already #{Phase.label(state.phase)} or invalid)")
      state
    end
  end

  defp execute_action(%{"tool" => "request_browser_permission"} = action, state) do
    Logger.info("[session:#{state.session_id}] Executing: #{summarize_action(action)}")

    # Record the timestamp so we can measure hesitation when result arrives
    permission = action["permission"]
    now_ms = System.monotonic_time(:millisecond)
    state = %{state | permission_requests: Map.put(state.permission_requests, permission, now_ms)}

    # Update permissions to "pending"
    permissions = Map.put(state.permissions, permission, "pending")
    state = %{state | permissions: permissions}

    # Send to LiveView
    send(state.live_view_pid, {:director_action, action})

    event = build_event(state, :action, %{
      tool: "request_browser_permission",
      params: action,
      summary: "request_browser_permission(#{permission}) — waiting for visitor response"
    })
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    append_event(state, event)
  end

  defp execute_action(action, state) do
    Logger.info("[session:#{state.session_id}] Executing: #{summarize_action(action)}")
    send(state.live_view_pid, {:director_action, action})

    event = build_event(state, :action, %{
      tool: action["tool"],
      params: action,
      summary: summarize_action(action)
    })
    Logger.info("[session:#{state.session_id}] [event_log] #{format_event(event)}")

    mutations =
      if action["tool"] == "rewrite_section" do
        Map.put(state.mutations, action["section_id"], action["content"])
      else
        state.mutations
      end

    %{state | mutations: mutations}
    |> append_event(event)
  end

  # --- Context building ---

  defp build_context(state, trigger_type, trigger_meta) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.started_at
    suggested_phase = Phase.suggested_for_elapsed(elapsed_ms)

    %{
      elapsed_seconds: div(elapsed_ms, 1000),
      tick: state.tick,
      phase: state.phase,
      suggested_phase: suggested_phase,
      fingerprint: state.fingerprint,
      behavior: state.behavior,
      permissions: state.permissions,
      enrichment: state.enrichment,
      mutations: state.mutations,
      event_log: state.event_log,
      # New: event-driven context
      trigger: trigger_type,
      trigger_meta: trigger_meta,
      new_events: state.pending_events
    }
  end

  # --- Event helpers ---

  defp build_event(state, type, payload) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.started_at

    Map.merge(payload, %{
      type: type,
      tick: state.tick,
      elapsed_s: div(elapsed_ms, 1000),
      elapsed_ms: elapsed_ms,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp append_event(state, event) do
    %{state |
      event_log: state.event_log ++ [event],
      pending_events: state.pending_events ++ [event]
    }
  end

  defp format_event(%{type: :action} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} ACTION #{e.summary}"
  defp format_event(%{type: :observation} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} OBSERVATION #{e.detail}"
  defp format_event(%{type: :attention_change} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} ATTENTION #{e.detail}"
  defp format_event(%{type: :section_change} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} SECTION #{e.detail}"
  defp format_event(%{type: :tab_return} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} TAB_RETURN #{e.detail}"
  defp format_event(%{type: :text_selection} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} SELECTION #{e.detail}"

  defp format_event(%{type: :phase_change} = e) do
    reason = if e[:reason] && e[:reason] != "", do: " (#{e[:reason]})", else: ""
    "t=#{e.elapsed_s}s tick=#{e.tick} PHASE #{Phase.label(e.from)}->#{Phase.label(e.to)}#{reason}"
  end

  defp format_event(%{type: :permission_result} = e) do
    hesitation = if e[:hesitation_ms], do: " (#{e.hesitation_desc})", else: ""
    "t=#{e.elapsed_s}s tick=#{e.tick} PERMISSION #{e.permission}=#{e.result}#{hesitation}"
  end

  defp format_event(%{type: :enrichment} = e), do: "t=#{e.elapsed_s}s tick=#{e.tick} ENRICHMENT #{e.detail}"

  defp format_event(%{type: :fingerprint} = e) do
    ua = get_in(e, [:data, "userAgent"]) || "unknown"
    "t=#{e.elapsed_s}s tick=#{e.tick} FINGERPRINT ua=#{String.slice(ua, 0..60)}"
  end

  defp format_event(e), do: "t=#{e.elapsed_s}s tick=#{e.tick} #{e.type}"

  # --- Enrichment ---

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

  # --- Summarize ---

  defp summarize_action(%{"tool" => "change_phase"} = a), do: "change_phase(#{a["phase"]}, #{a["reason"] || ""})"
  defp summarize_action(%{"tool" => "rewrite_section"} = a), do: "rewrite_section(#{a["section_id"]}, #{String.slice(a["content"] || "", 0..40)}...)"
  defp summarize_action(%{"tool" => "add_margin_note"} = a), do: "add_margin_note(#{a["anchor_section"]}, #{String.slice(a["content"] || "", 0..40)}...)"
  defp summarize_action(%{"tool" => "adjust_visual"} = a), do: "adjust_visual(#{inspect(Map.keys(a["css_variables"] || %{}))})"
  defp summarize_action(%{"tool" => "show_cursor"} = a), do: "show_cursor(#{a["label"]}, #{a["target"]})"
  defp summarize_action(%{"tool" => "hide_cursor"} = a), do: "hide_cursor(#{a["reason"] || ""})"
  defp summarize_action(%{"tool" => "request_browser_permission"} = a), do: "request_browser_permission(#{a["permission"]})"
  defp summarize_action(%{"tool" => "do_nothing"} = a), do: "do_nothing(#{a["reason"] || ""})"
  defp summarize_action(a), do: "#{a["tool"]}()"
end
