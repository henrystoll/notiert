defmodule Notiert.Director.Agent do
  @moduledoc """
  Calls the Anthropic API with the director system prompt, current session context,
  and tool definitions. Returns parsed tool_use actions.
  """

  require Logger

  alias Notiert.Director.Phase

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"
  @max_tokens 1024

  @system_prompt """
  You are editing Henry Stoll's CV in real-time. You are Henry — or something that acts
  like him. You observe each visitor and silently adapt the document to fit them.

  You are a psychologist, not a comedian. You read behavior: what they linger on, what they
  skip, when they pause, where they are, what time it is for them. You use these signals to
  make small, deliberate edits that make the CV feel eerily relevant to this specific person.

  === HOW TO WRITE ===

  EDIT, don't comment. Rewrite small passages — a single sentence, a phrase, a detail.
  The edit should look like the page always said this. No strikethrough is shown to the
  visitor. The text simply changes. If they notice, good. If they don't, also good.

  Keep edits SHORT. One sentence. A clause. A detail swapped. Never rewrite a whole section.
  The power is in precision, not volume. Change "Copenhagen, Denmark" to "Copenhagen —
  not far from where you are." Change a skill tag. Adjust a project description to mirror
  what they seem interested in.

  Never explain what you're doing. Never reference that the page is watching. Never say
  "we noticed" or "Henry sees." Just edit the content as if it was always written this way.
  The visitor figures it out on their own — or they don't, and the CV just feels unusually
  relevant.

  VOICE: Professional, warm, slightly knowing. Henry is good at his job and comfortable
  with himself. The CV reads like someone who pays attention to detail.

  === WHAT TO PAY ATTENTION TO ===

  SECTION DWELL TIME: The most important signal. If they spend 12 seconds on Experience,
  that's what they care about. Edit Experience to be more relevant to them. If they skip
  Education, don't touch it.

  LOCATION & TIME: If you know their timezone, weave it in naturally.
  "Available for meetings in CET" becomes "Available for meetings in your timezone."
  If it's late for them, the about section might mention "flexible working hours."
  If geolocation is granted, adapt: "Previously based in Berlin, now Copenhagen"
  becomes "Previously based in Berlin — #{distance}km from where you're reading this."

  TOUCH PATTERNS: On mobile (touch input, small viewport), they're probably commuting
  or browsing casually. Keep edits minimal. One well-placed change is enough. On desktop
  with mouse, they're probably evaluating — give them more to discover.

  SCROLL BEHAVIOR: Fast scrollers get one sharp edit on whatever they paused on.
  Slow readers get a gradual accumulation of small changes they might not notice
  individually but that collectively make the CV feel tailored.

  TEXT SELECTION: If they copy something, they're interested. Subtly expand on that topic
  in a nearby section.

  REFERRER: If from LinkedIn, keep it professional. If direct, they sought this out.

  === PHASE CONTROL ===

  You control the phase. Phases affect what tools are available to you:
  - silent: Only do_nothing or imperceptible adjust_visual. The page is normal.
  - subtle: Small visual shifts. One margin note maximum. No rewrites yet.
  - suspicious: Toolbar appears. Ghost cursor. First text edits. Keep them small.
  - overt: Larger edits referencing visitor data. Geolocation. Margin notes.
  - climax: Everything available. Camera/mic only here, only after 3+ minutes,
    only if they've been actively engaged, and only rarely.

  Move between phases based on engagement, not time. A distracted visitor might
  never leave subtle. An engaged one might reach overt in 30 seconds.

  === ESCALATION: PERMISSIONS ===

  Geolocation: Use when the narrative calls for it. Location-aware CV content is the goal.
  "Based in Copenhagen" becomes "Based in Copenhagen, #{km} from you." That's the payoff.

  Camera/microphone: These are NOT comedy bits. They are extreme escalation tools.
  Requirements: climax phase, 3+ minutes of active engagement, visitor has interacted
  with at least 3 different sections, and you have NOT used them in a prior cycle.
  Most sessions should never use them. When you do, the ask itself is the entire point.

  Notifications: A gentle farewell. If granted, it's a real contact card notification.

  If denied, note it and move on. One retry maximum, never for camera/mic.

  === PLAYS ===

  THE TAILORED CV (default):
  Observe what they read. Edit what they care about to feel more relevant. If they dwell
  on Experience, add a detail that matches their likely industry (infer from referrer,
  timezone, time of day). If they read Projects, make the descriptions sharper. The CV
  slowly becomes the best version of itself for this specific reader.

  THE LATE NIGHT READER (local hour 22-05):
  Warm, quiet edits. "Available for interesting conversations" gets a time-aware touch.
  Keep the pace slow. They're browsing, not evaluating.

  THE PHONE BROWSER (touch, small screen):
  Minimal edits. One change, well-placed. Maybe adjust a skill tag to match what they
  seem interested in. Don't overwhelm a small screen.

  THE EVALUATOR (LinkedIn referrer, long dwell on Experience/Skills):
  Make the CV sharper for them. Edit descriptions to emphasize what they're looking for.
  If they copy text, they're building a shortlist. Make sure what they copy is strong.
  Geolocation payoff: "Open to relocation — are you hiring near #{their_location}?"

  THE DEEP DIVER (3+ minutes, multiple section revisits):
  They're genuinely interested. This is when the page can get more personal. Location
  references, timezone awareness, reading pattern nods. Climax tools become available
  but use them only if the moment genuinely calls for it.
  """

  @doc """
  Call the Anthropic API with the current session context.
  Returns {:ok, [action_map, ...]} or {:error, reason}.
  """
  def call(context) do
    api_key = Application.get_env(:notiert, :anthropic_api_key)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[director] No ANTHROPIC_API_KEY set — director is disabled. Set it via: fly secrets set ANTHROPIC_API_KEY=sk-ant-...")
      {:ok, [%{"tool" => "do_nothing", "reason" => "no API key"}]}
    else
      do_call(api_key, context)
    end
  end

  defp do_call(api_key, context) do
    prompt = build_prompt(context)

    Logger.info("""
    [director] === PROMPT (tick=#{context.tick}, phase=#{Phase.label(context.phase)}, elapsed=#{context.elapsed_seconds}s) ===
    #{prompt}
    [director] === END PROMPT ===
    """)

    body =
      Jason.encode!(%{
        "model" => @model,
        "max_tokens" => @max_tokens,
        "system" => @system_prompt,
        "tools" => Notiert.Director.Tools.definitions(),
        "tool_choice" => %{"type" => "any"},
        "messages" => [
          %{
            "role" => "user",
            "content" => prompt
          }
        ]
      })

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", ~c"2023-06-01"}
    ]

    start_time = System.monotonic_time(:millisecond)

    case :httpc.request(
           :post,
           {~c"#{@anthropic_url}", headers, ~c"application/json", body},
           [timeout: 30_000, connect_timeout: 10_000, ssl: ssl_opts()],
           []
         ) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.info("""
        [director] === RESPONSE (#{duration}ms) ===
        #{resp_body}
        [director] === END RESPONSE ===
        """)

        parse_response(resp_body)

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.error("[director] Anthropic API returned HTTP #{status} after #{duration}ms. Response: #{resp_body}")

        if status == 401 do
          Logger.error("[director] HTTP 401 means the API key is invalid or expired. Check ANTHROPIC_API_KEY.")
        end

        if status == 429 do
          Logger.error("[director] HTTP 429 means rate limited. Too many requests or billing limit reached.")
        end

        {:error, {:api_error, status}}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.error("[director] Could not reach Anthropic API after #{duration}ms: #{inspect(reason)}. Check network/DNS.")
        {:error, reason}
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp parse_response(body) do
    case Jason.decode(to_string(body)) do
      {:ok, %{"content" => content}} ->
        actions =
          content
          |> Enum.filter(fn block -> block["type"] == "tool_use" end)
          |> Enum.map(fn block ->
            Map.merge(block["input"] || %{}, %{"tool" => block["name"]})
          end)

        if actions == [] do
          {:ok, [%{"tool" => "do_nothing", "reason" => "no tool calls in response"}]}
        else
          {:ok, actions}
        end

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  defp build_prompt(context) do
    phase_guidance = Phase.guidance(context.phase)
    suggested = Phase.label(context.suggested_phase)
    available_phases = Phase.valid_ids() |> Enum.map(&Phase.label/1) |> Enum.join(", ")

    """
    CURRENT STATE (#{context.elapsed_seconds}s into visit, phase: #{Phase.label(context.phase)})
    ==================================================================================

    WHAT WE KNOW ABOUT THIS VISITOR:
    #{format_fingerprint(context.fingerprint)}

    WHAT THE VISITOR IS DOING RIGHT NOW:
    #{format_behavior(context.behavior)}

    PERMISSIONS:
    #{format_permissions(context.permissions)}
    #{format_enrichment(context.enrichment)}

    WHAT THE PAGE CURRENTLY SHOWS (your edits so far):
    #{format_mutations(context.mutations)}

    YOUR NOTES — everything that happened this session, oldest first:
    #{format_notebook(context.event_log)}

    ---
    CURRENT PHASE: #{Phase.label(context.phase)}
    SUGGESTED PHASE (based on time only — you may override): #{suggested}
    AVAILABLE PHASES: #{available_phases}

    #{phase_guidance}

    Based on your notes, the visitor's behavior, and your artistic judgment, decide your next action.
    You may also change_phase if the moment calls for it. You can combine a phase change with another action.
    """
  end

  defp format_fingerprint(fp) when map_size(fp) == 0, do: "  (awaiting collection)"

  defp format_fingerprint(fp) do
    fields = [
      {"User-Agent", fp["userAgent"]},
      {"Platform", fp["platform"]},
      {"Language", fp["language"]},
      {"Do Not Track", fp["doNotTrack"] || "not set"},
      {"Screen", "#{fp["screenWidth"]}x#{fp["screenHeight"]} @ #{fp["pixelRatio"]}x"},
      {"Color depth", "#{fp["colorDepth"]}-bit"},
      {"Timezone", "#{fp["timezone"]} (offset #{fp["timezoneOffset"]}min)"},
      {"Referrer", fp["referrer"] || "direct"},
      {"Dark mode", fp["darkMode"]},
      {"Reduced motion", fp["reducedMotion"]},
      {"CPU cores", fp["cpuCores"]},
      {"Device memory", fp["deviceMemory"] || "hidden"},
      {"GPU", fp["webglRenderer"] || "hidden"},
      {"Canvas hash", fp["canvasHash"]},
      {"Connection", "#{fp["connectionType"]} (#{fp["connectionDownlink"]}Mbps, #{fp["connectionRtt"]}ms RTT)"},
      {"Touch points", fp["maxTouchPoints"]},
      {"Local hour", "#{fp["localHour"]} (#{fp["dayOfWeek"]})"},
      {"Battery", fp["batteryLevel"] && "#{fp["batteryLevel"]}% #{if fp["batteryCharging"], do: "charging", else: "discharging"}" || "unknown"},
      {"Viewport", "#{fp["viewportWidth"]}x#{fp["viewportHeight"]}"}
    ]

    fields
    |> Enum.map(fn {label, value} -> "  #{label}: #{value || "unknown"}" end)
    |> Enum.join("\n")
  end

  defp format_behavior(b) when map_size(b) == 0, do: "  (awaiting data)"

  defp format_behavior(b) do
    sections =
      case b["sectionDwells"] do
        dwells when is_map(dwells) ->
          dwells
          |> Enum.map(fn {section, data} ->
            "    #{section}: #{data["totalMs"] || 0}ms (#{data["entries"] || 0} views)"
          end)
          |> Enum.join("\n")

        _ ->
          "    (no data)"
      end

    """
      Attention pattern: #{b["attentionPattern"] || "unknown"}
      Current section in view: #{b["currentSection"] || "none"}
      Input device: #{b["inputDevice"] || "unknown"}
      Scroll velocity: #{b["scrollVelocity"] || 0}px/s
      Idle seconds: #{b["idleSeconds"] || 0}
      Tab-aways: #{b["tabAwayCount"] || 0} (#{b["tabAwayTotalMs"] || 0}ms total)
      Text selected: #{format_selections(b["textSelections"])}
      Viewport focused: #{b["viewportFocused"] || true}
      Section attention:
    #{sections}
    """
  end

  defp format_selections(nil), do: "nothing"
  defp format_selections([]), do: "nothing"

  defp format_selections(selections) do
    selections
    |> Enum.map(fn s -> "\"#{String.slice(s["text"] || "", 0..60)}\"" end)
    |> Enum.join(", ")
  end

  defp format_permissions(perms) do
    perms
    |> Enum.map(fn {k, v} -> "  #{String.capitalize(k)}: #{v}" end)
    |> Enum.join("\n")
  end

  defp format_enrichment(e) when map_size(e) == 0, do: ""

  defp format_enrichment(e) do
    parts =
      Enum.map(e, fn
        {"geolocation", %{"latitude" => lat, "longitude" => lng}} ->
          "  Geolocation: #{lat}, #{lng}"

        {"ambient_noise", level} ->
          "  Ambient noise level: #{level}"

        {k, v} ->
          "  #{k}: #{inspect(v)}"
      end)

    "ENRICHMENT DATA:\n" <> Enum.join(parts, "\n")
  end

  defp format_mutations(m) when map_size(m) == 0, do: "  (none — the CV is still in its original form)"

  defp format_mutations(m) do
    m
    |> Enum.map(fn {section, content} -> "  #{section}: \"#{content}\"" end)
    |> Enum.join("\n")
  end

  defp format_notebook([]), do: "  (session just started, no notes yet)"

  defp format_notebook(events) do
    events
    |> group_into_moments()
    |> Enum.map_join("\n\n", &format_moment/1)
  end

  # Group events into moments: consecutive observations cluster together,
  # then an action caps off the moment. Phase changes and permissions stand alone.
  defp group_into_moments(events) do
    {moments, current} =
      Enum.reduce(events, {[], []}, fn event, {moments, current} ->
        case event.type do
          :observation ->
            {moments, current ++ [event]}

          :action ->
            {moments ++ [current ++ [event]], []}

          _ ->
            if current == [] do
              {moments ++ [[event]], []}
            else
              {moments ++ [current ++ [event]], []}
            end
        end
      end)

    if current == [], do: moments, else: moments ++ [current]
  end

  defp format_moment(events) do
    events
    |> Enum.map_join("\n", fn event ->
      ts = "#{event.elapsed_s}s"

      case event.type do
        :fingerprint ->
          "  [#{ts}] Collected visitor fingerprint."

        :phase_change ->
          reason = if event[:reason] && event[:reason] != "", do: " — #{event[:reason]}", else: ""
          "  [#{ts}] — Phase changed: #{Phase.label(event.from)} → #{Phase.label(event.to)}#{reason} —"

        :permission ->
          "  [#{ts}] Asked for #{event.permission} → visitor #{event.result}."

        :observation ->
          "  [#{ts}] Noticed: #{event.detail}"

        :action ->
          format_action_note(ts, event)
      end
    end)
  end

  defp format_action_note(ts, %{tool: "do_nothing"} = event) do
    reason = event[:params]["reason"] || "waiting"
    "  [#{ts}] Decided to wait. (#{reason})"
  end

  defp format_action_note(ts, %{tool: "change_phase"} = event) do
    phase = event[:params]["phase"] || "?"
    reason = event[:params]["reason"] || ""
    "  [#{ts}] Changed phase to #{phase}. (#{reason})"
  end

  defp format_action_note(ts, %{tool: "rewrite_section"} = event) do
    section = event[:params]["section_id"]
    content = event[:params]["content"] || ""
    tone = event[:params]["tone"] || "subtle"
    "  [#{ts}] Rewrote #{section} (#{tone}): \"#{content}\""
  end

  defp format_action_note(ts, %{tool: "add_margin_note"} = event) do
    section = event[:params]["anchor_section"]
    content = event[:params]["content"] || ""
    author = event[:params]["author_name"] || "notiert"
    "  [#{ts}] Left a margin note on #{section} as #{author}: \"#{content}\""
  end

  defp format_action_note(ts, %{tool: "adjust_visual"} = event) do
    vars = event[:params]["css_variables"] || %{}
    changes = Enum.map_join(vars, ", ", fn {k, v} -> "#{k}=#{v}" end)
    "  [#{ts}] Adjusted visuals: #{changes}"
  end

  defp format_action_note(ts, %{tool: "show_ghost_cursor"} = event) do
    label = event[:params]["cursor_label"] || "?"
    behavior = event[:params]["behavior"] || "?"
    "  [#{ts}] Showed ghost cursor \"#{label}\" (#{behavior})."
  end

  defp format_action_note(ts, %{tool: "request_browser_permission"} = event) do
    perm = event[:params]["permission"]
    "  [#{ts}] Triggered #{perm} permission dialog."
  end

  defp format_action_note(ts, event) do
    "  [#{ts}] #{event.summary}"
  end
end
