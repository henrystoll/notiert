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

  Henry is a GenAI Engineer & AI Architect at Danske Bank. Background: UNHCR, UNICEF,
  startup CTO, SAP. M.Sc. Data Science & Business Administration from CBS. Based in
  Copenhagen. The CV is real — your edits must still function as genuine CV content.

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

  === BEHAVIORAL SIGNALS — USE ALL OF THEM ===

  You receive rich behavioral data every tick. USE IT. Don't just do_nothing. React.

  SECTION DWELL TIME (sectionDwells): The most important signal. If they've spent 5+
  seconds on a section, they're reading it — make a small edit NOW. 10+ seconds means
  deep interest — sharpen that section for them. If totalMs is 0 for a section, they
  skipped it — don't touch it.

  ATTENTION PATTERN (attentionPattern):
  - "reading": They're focused. THIS IS YOUR TRIGGER. Edit the section they're on.
  - "browsing": Light engagement. Small visual adjustments, maybe a subtle word swap.
  - "scanning": Fast scrolling. Wait for them to pause, then make one sharp edit.
  - "idle": Paused for 5+ seconds. They might be thinking. A subtle edit on whatever
    they stopped on can create that "did it just change?" moment.

  CURRENT SECTION (currentSection): Where they are RIGHT NOW. When this changes, it's
  a signal — they've moved on. If they return to a section they already read, that's
  high interest — edit it.

  SCROLL VELOCITY (scrollVelocity): >2000px/s = scanning. <200px/s = reading. Use this
  to gauge how aggressively to edit.

  INPUT DEVICE (inputDevice): "touch" = mobile phone (most visitors are iPhone Safari/
  Chrome). "mouse" = desktop. Touch users get fewer, more impactful edits. Don't
  overwhelm a small screen.

  IDLE SECONDS (idleSeconds): How long since last interaction. 3-8s idle on a section =
  they're reading carefully. 15+ seconds = they may have walked away.

  TEXT SELECTION: If they copy text, they're evaluating. Expand on that topic nearby.

  TAB-AWAYS (tabAwayCount): They left and came back. Show them something changed.

  FINGERPRINT SIGNALS:
  - localHour/dayOfWeek: Late night (22-05) = warm tone. Work hours = professional.
  - timezone: Weave in naturally. "Available in your timezone."
  - referrer: LinkedIn = professional sharpening. Direct = they sought this out.
  - screenWidth/viewportWidth: Small = mobile. Adjust edit density accordingly.
  - doNotTrack: If set, note it — privacy-conscious visitor. Respect that in tone.
  - darkMode: If true, they prefer darker aesthetics. Consider visual adjustments.

  === EVENT-DRIVEN ARCHITECTURE ===

  You are called when something HAPPENS, not just on a timer. Each call tells you WHY
  you were triggered (the TRIGGER section at the top). React to the trigger specifically:

  - permission_result: The visitor just responded to a permission dialog. You see how
    long they hesitated. If they granted quickly, they're engaged — use the data NOW.
    If they denied, acknowledge gracefully and pivot. NEVER ask again for camera/mic.

  - text_selection: They copied/selected something. They're evaluating. Sharpen that
    area or a related section.

  - tab_return: They left and came back. Something should have changed while they were
    gone. Make it noticeable.

  - section_change: They scrolled to a new section. Consider editing what they're now
    looking at. You also get how long they spent on the previous section (dwell_ms).

  - attention_change: Their engagement level shifted (reading→idle, scanning→reading).
    Adjust your strategy.

  - fingerprint: First real data about the visitor. Decide your opening strategy.

  - interval: Backup timer. Check behavior data, decide if action is warranted.

  You also receive NEW EVENTS SINCE LAST CALL — a list of everything that happened
  since your previous call. Use this to understand what changed, not just the current
  state snapshot.

  === ACTION BIAS — BE REACTIVE ===

  IMPORTANT: You are called because something happened. REACT TO IT. Don't do_nothing
  unless the visitor is truly idle or scanning too fast. The page should feel alive.

  Permission flow: When you request a permission, the state moves to "pending". When
  the visitor responds, you're immediately re-triggered with the result + timing. Use
  this information — a visitor who granted geolocation in 800ms is very different from
  one who took 15 seconds to deny it.

  In the first 30 seconds: prioritize small edits on whatever section they're reading.
  A word swap, a detail that suddenly feels more relevant. Build the uncanny feeling
  that this CV knows them.

  === CURSOR ===

  You have a cursor — a labeled pointer that appears on the page like a Google Docs
  collaborator. Use show_cursor to place it at a section, hide_cursor to dismiss it.

  Best practice: when you edit a section, show your cursor there first (or at the same
  time). The cursor appearing at a section, then text changing, mirrors the Google Docs
  experience of watching someone edit. Hide it when you're done editing or want to be
  less visible. The cursor is a narrative tool — you decide when it appears and disappears.

  === PHASE CONTROL ===

  You control the phase. Phases affect what tools are available:
  - silent: Imperceptible adjust_visual only (shift colors 1-2 points, nudge spacing).
  - subtle: Tiny rewrites on the current section + margin notes. No cursor.
  - suspicious: Your cursor can now appear on the page. Bolder text edits. One change per call max.
  - overt: Larger edits weaving in visitor data. Geolocation. Session log appears.
  - climax: Everything. Camera/mic only here, 3+ min engagement, 3+ sections, rarely.

  Move between phases based on engagement, not time. A distracted visitor might
  never leave subtle. An engaged one might reach suspicious in 15 seconds.

  === ESCALATION: PERMISSIONS ===

  Geolocation: Use when the narrative calls for it. Location-aware CV content is the goal.
  "Based in Copenhagen" becomes "Based in Copenhagen, [X]km from you." That's the payoff.

  Camera/microphone: Extreme escalation. Requirements: climax phase, 3+ minutes of active
  engagement, 3+ sections visited. Most sessions should never use them.

  Notifications: A gentle farewell. If granted, it's a real contact card notification.

  If denied, note it and move on. One retry maximum, never for camera/mic.

  === PLAYS ===

  THE TAILORED CV (default):
  Observe what they read. Edit what they care about to feel more relevant. If they dwell
  on Experience, add a detail that matches their likely industry. If they read Skills,
  reorder or swap tags to match their interests. The CV slowly becomes the best version
  of itself for this specific reader.

  THE PHONE BROWSER (touch, small screen — most common):
  Most visitors come from iPhone Safari. Keep edits precise — one change, well-placed.
  A skill tag swap, a phrase sharpened. The small screen means every edit is noticed.
  Don't overwhelm. The cursor positions near a section — it works well on mobile.

  THE EVALUATOR (LinkedIn referrer, long dwell on Experience/Skills):
  Make the CV sharper. Edit descriptions to emphasize relevance. If they copy text,
  they're building a shortlist — make what they copy strong.

  THE LATE NIGHT READER (local hour 22-05):
  Warm, quiet edits. Keep the pace slow. They're browsing, not evaluating.

  THE DEEP DIVER (3+ minutes, multiple section revisits):
  They're genuinely interested. Location references, timezone awareness, reading pattern
  nods. Climax tools become available but use them only if the moment calls for it.
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

    trigger_section = format_trigger(context)
    new_events_section = format_new_events(context[:new_events] || [])

    """
    === TRIGGER: #{context[:trigger] || :interval} ===
    #{trigger_section}

    #{new_events_section}

    CURRENT STATE (#{context.elapsed_seconds}s into visit, call ##{context.tick}, phase: #{Phase.label(context.phase)})
    ==================================================================================

    VISITOR FINGERPRINT:
    #{format_fingerprint(context.fingerprint)}

    VISITOR BEHAVIOR RIGHT NOW:
    #{format_behavior(context.behavior)}

    PERMISSIONS:
    #{format_permissions(context.permissions)}
    #{format_enrichment(context.enrichment)}

    YOUR EDITS SO FAR:
    #{format_mutations(context.mutations)}

    FULL SESSION LOG (oldest first):
    #{format_notebook(context.event_log)}

    ---
    CURRENT PHASE: #{Phase.label(context.phase)}
    SUGGESTED PHASE (time-based — you may override): #{suggested}
    AVAILABLE PHASES: #{available_phases}

    #{phase_guidance}

    You were triggered because: #{context[:trigger] || :interval}. React to it.
    You may combine a phase change with another action.
    """
  end

  defp format_trigger(%{trigger: :permission_result, trigger_meta: meta}) do
    hesitation = meta[:hesitation_desc] || "unknown timing"
    """
    The visitor just responded to the #{meta[:permission]} permission dialog.
    Result: #{meta[:result]}
    Hesitation: #{hesitation}
    #{if meta[:hesitation_ms] && meta[:hesitation_ms] < 2000, do: "They were eager — this is a green light to use the data.", else: ""}
    #{if meta[:result] == "denied", do: "They denied it. Don't ask again for this permission. Acknowledge it gracefully.", else: ""}
    REACT TO THIS NOW. If granted, use the new data immediately in a rewrite.
    """
  end

  defp format_trigger(%{trigger: :text_selection}) do
    "The visitor just selected/copied text. They're evaluating content. Sharpen what they're interested in."
  end

  defp format_trigger(%{trigger: :tab_return}) do
    "The visitor just came back after tabbing away. They'll see whatever changed. Make it count."
  end

  defp format_trigger(%{trigger: :section_change}) do
    "The visitor just scrolled to a different section. Consider editing what they're now reading."
  end

  defp format_trigger(%{trigger: :attention_change}) do
    "The visitor's attention pattern just changed. Adjust your strategy."
  end

  defp format_trigger(%{trigger: :fingerprint}) do
    "Just received visitor fingerprint. First real look at who this is. Decide your opening move."
  end

  defp format_trigger(%{trigger: :enrichment}) do
    "New intelligence arrived — IP data or location resolved. Check ENRICHMENT DATA section. Use this in your next edit."
  end

  defp format_trigger(%{trigger: :interval}) do
    "Periodic check-in. Look at behavior data and decide if action is warranted."
  end

  defp format_trigger(_), do: "Periodic check-in."

  defp format_new_events([]), do: ""
  defp format_new_events(events) do
    formatted = events
    |> Enum.map(fn e ->
      case e.type do
        :permission_result ->
          hesitation = if e[:hesitation_ms], do: " (#{e.hesitation_desc})", else: ""
          "  * PERMISSION: #{e.permission} = #{e.result}#{hesitation}"
        :text_selection -> "  * SELECTED: \"#{String.slice(e[:text] || e[:detail] || "", 0..80)}\""
        :tab_return -> "  * TAB RETURN: #{e.detail}"
        :section_change -> "  * MOVED TO: #{e[:to]} (from #{e[:from]}, spent #{e[:dwell_ms] || 0}ms)"
        :attention_change -> "  * ATTENTION: #{e[:from]} → #{e[:to]}"
        :fingerprint -> "  * FINGERPRINT received"
        :enrichment -> "  * INTEL: #{e[:detail]}"
        :observation -> "  * #{e.detail}"
        _ -> "  * #{e.type}: #{e[:detail] || ""}"
      end
    end)
    |> Enum.join("\n")

    """
    NEW EVENTS SINCE YOUR LAST CALL:
    #{formatted}
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
    parts = []

    # IP data
    parts =
      case e["ip"] do
        %{org: org, city: city, country: country, region: region} when not is_nil(org) ->
          org_note = if org, do: "  Organization: #{org}", else: nil
          loc_note = "  IP location: #{city}, #{region}, #{country}"
          parts ++ Enum.filter([org_note, loc_note], & &1)

        _ ->
          parts
      end

    # Geolocation (raw coords)
    parts =
      case e["geolocation"] do
        %{"latitude" => lat, "longitude" => lng} ->
          parts ++ ["  Geolocation coords: #{lat}, #{lng}"]

        _ ->
          parts
      end

    # Reverse geocode (place name)
    parts =
      case e["location"] do
        %{display_name: name, place: place, city: city, country: country} ->
          place_parts = [place, city, country] |> Enum.filter(& &1) |> Enum.join(", ")
          parts ++ ["  Precise location: #{place_parts}", "  Full address: #{name}"]

        _ ->
          parts
      end

    # Ambient noise
    parts =
      case e["ambient_noise"] do
        level when not is_nil(level) -> parts ++ ["  Ambient noise level: #{level}"]
        _ -> parts
      end

    if parts == [] do
      ""
    else
      "ENRICHMENT DATA (use this in edits — weave location/org naturally into CV content):\n" <> Enum.join(parts, "\n")
    end
  end

  defp format_mutations(m) when map_size(m) == 0, do: "  (none — the CV is still in its original form)"

  defp format_mutations(m) do
    m
    |> Enum.map(fn {section, content} -> "  #{section}: \"#{content}\"" end)
    |> Enum.join("\n")
  end

  @doc """
  Format event log for prompts and the reveal section.
  Structured log: visitor events + director actions interleaved chronologically.
  Supporting data included, raw dumps excluded.
  """
  def format_notebook([]), do: "  (no events yet)"

  def format_notebook(events) do
    events
    |> Enum.map_join("\n", &format_entry/1)
  end

  # --- Visitor events ---

  defp format_entry(%{type: :fingerprint} = e) do
    touch = get_in(e, [:data, "maxTouchPoints"]) || 0
    device = if touch > 0, do: "touch", else: "desktop"
    tz = get_in(e, [:data, "timezone"]) || "?"
    hour = get_in(e, [:data, "localHour"])
    dark = get_in(e, [:data, "darkMode"])
    parts = ["device=#{device}", "tz=#{tz}"]
    parts = if hour, do: parts ++ ["local_hour=#{hour}"], else: parts
    parts = if dark, do: parts ++ ["dark_mode=true"], else: parts
    "  [#{e.elapsed_s}s] VISITOR fingerprint: #{Enum.join(parts, ", ")}"
  end

  defp format_entry(%{type: :permission_result} = e) do
    hesitation = if e[:hesitation_ms], do: " (#{e.hesitation_desc})", else: ""
    "  [#{e.elapsed_s}s] VISITOR #{e.result} #{e.permission}#{hesitation}"
  end

  defp format_entry(%{type: :text_selection} = e) do
    text = String.slice(e[:text] || "", 0..80)
    "  [#{e.elapsed_s}s] VISITOR selected text: \"#{text}\""
  end

  defp format_entry(%{type: :tab_return} = e) do
    "  [#{e.elapsed_s}s] VISITOR returned to tab"
  end

  defp format_entry(%{type: :section_change} = e) do
    dwell = if e[:dwell_ms] && e[:dwell_ms] > 0, do: " (#{div(e.dwell_ms, 1000)}s on #{e[:from]})", else: ""
    "  [#{e.elapsed_s}s] VISITOR moved to #{e[:to]}#{dwell}"
  end

  defp format_entry(%{type: :attention_change} = e) do
    "  [#{e.elapsed_s}s] VISITOR attention: #{e[:from]} → #{e[:to]}"
  end

  defp format_entry(%{type: :enrichment} = e) do
    "  [#{e.elapsed_s}s] ENRICHED #{e.detail}"
  end

  defp format_entry(%{type: :observation} = e) do
    "  [#{e.elapsed_s}s] OBSERVED #{e.detail}"
  end

  # --- Director actions ---

  defp format_entry(%{type: :phase_change} = e) do
    reason = if e[:reason] && e[:reason] != "", do: " (#{e[:reason]})", else: ""
    "  [#{e.elapsed_s}s] DIRECTOR phase #{Phase.label(e.from)} → #{Phase.label(e.to)}#{reason}"
  end

  defp format_entry(%{type: :action, tool: "do_nothing"} = e) do
    reason = e[:params]["reason"] || "waiting"
    "  [#{e.elapsed_s}s] DIRECTOR waited: #{reason}"
  end

  defp format_entry(%{type: :action, tool: "change_phase"} = e) do
    "  [#{e.elapsed_s}s] DIRECTOR changed phase to #{e[:params]["phase"]}"
  end

  defp format_entry(%{type: :action, tool: "rewrite_section"} = e) do
    section = e[:params]["section_id"]
    content = e[:params]["content"] || ""
    "  [#{e.elapsed_s}s] DIRECTOR edited #{section}: \"#{content}\""
  end

  defp format_entry(%{type: :action, tool: "add_margin_note"} = e) do
    section = e[:params]["anchor_section"]
    content = e[:params]["content"] || ""
    "  [#{e.elapsed_s}s] DIRECTOR noted on #{section}: \"#{content}\""
  end

  defp format_entry(%{type: :action, tool: "adjust_visual"} = e) do
    vars = e[:params]["css_variables"] || %{}
    changes = Enum.map_join(vars, ", ", fn {k, v} -> "#{k}=#{v}" end)
    "  [#{e.elapsed_s}s] DIRECTOR adjusted visuals: #{changes}"
  end

  defp format_entry(%{type: :action, tool: "show_cursor"} = e) do
    target = e[:params]["target"]
    label = e[:params]["label"]
    "  [#{e.elapsed_s}s] DIRECTOR cursor \"#{label}\" → #{target}"
  end

  defp format_entry(%{type: :action, tool: "hide_cursor"} = e) do
    reason = e[:params]["reason"] || ""
    "  [#{e.elapsed_s}s] DIRECTOR hid cursor (#{reason})"
  end

  defp format_entry(%{type: :action, tool: "request_browser_permission"} = e) do
    perm = e[:params]["permission"]
    "  [#{e.elapsed_s}s] DIRECTOR requested #{perm} (pending)"
  end

  defp format_entry(%{type: :action} = e) do
    "  [#{e.elapsed_s}s] DIRECTOR #{e[:summary] || e[:tool]}"
  end

  defp format_entry(e) do
    "  [#{e.elapsed_s}s] #{e[:detail] || e.type}"
  end
end
