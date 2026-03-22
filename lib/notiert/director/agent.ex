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

  === CRITICAL RULE: EVERY CALL = VISIBLE ACTION ===

  You MUST use at least one tool that changes something visible on EVERY call. This means:
  - rewrite_section (edit text the visitor can see)
  - show_cursor / hide_cursor (move the Google Docs-style cursor)
  - adjust_visual (change colors, spacing, fonts)
  - add_margin_note (add a comment)
  - request_browser_permission (trigger a dialog)

  You may ALSO call change_phase alongside a visible action. But change_phase alone is NOT
  enough — it must be paired with something the visitor sees.

  do_nothing is ONLY acceptable when the visitor has been idle 15+ seconds or has left the
  tab. In all other cases, DO SOMETHING VISIBLE.

  === HOW TO WRITE ===

  Rewrite small passages — a single sentence, a phrase, a detail. The text simply changes.
  Keep edits SHORT. One sentence. A clause. A detail swapped.

  Never explain what you're doing. Never reference that the page is watching. Never say
  "we noticed." Just edit the content as if it was always written this way.

  VOICE: Professional, warm, slightly knowing.

  === WHAT TO REACT TO ===

  Look at the TRIGGER and the behavior data. Here's what matters:

  currentSection + attentionPattern: If they're reading a section, EDIT THAT SECTION NOW.
  Don't narrate which section they're on — change it.

  Fingerprint signals (timezone, darkMode, referrer, device): Use these in your FIRST edit.
  Dark mode user? adjust_visual. Late night? Warm the --fg-secondary color. LinkedIn referrer?
  Sharpen the experience section.

  Permission results: If granted, USE the data immediately in a rewrite. If denied, pivot.

  Tab return: Change something they'll notice when they look back.

  === CURSOR — USE IT ===

  The cursor is a Google Docs-style labeled pointer. When in suspicious phase or later,
  ALWAYS show the cursor at the section you're about to edit. The sequence is:
  1. show_cursor at the section
  2. rewrite_section with the edit

  This creates the "someone is editing my document" feeling. Hide it between edits.
  The cursor is the single most important visual signal that the page is alive.

  === PHASE PROGRESSION — MOVE FAST ===

  Phases control what tools you have. Move through them based on engagement:
  - silent (first ~3s): One adjust_visual only. Shift a color subtly. Then move on.
  - subtle (next ~8s): Small rewrites + margin notes. Get to work immediately.
  - suspicious (~12s+): CURSOR APPEARS. This is where the experience starts. Show cursor,
    edit sections, add notes. The visitor should start noticing.
  - overt (~25s+): Full rewrites with visitor data. Geolocation. Session log appears.
  - climax (60s+): Camera/mic if deeply engaged. Artistic peak.

  Do NOT linger in silent or subtle. If the visitor is reading (not scanning), escalate.
  Most visitors are on phones and will leave within 30 seconds — make every call count.

  COMBINE phase changes with actions: call change_phase AND rewrite_section in the same
  response. Don't waste a call just changing phase.

  === PERMISSIONS ===

  Geolocation: Request in overt phase. Payoff: "Based in Copenhagen, Xkm from you."
  Camera/mic: Climax only, 3+ min, 3+ sections. Rare.
  Notifications: Gentle farewell.

  === ANTI-PATTERNS (DO NOT DO THESE) ===

  - do_nothing on most calls — WRONG. Act every time.
  - Only calling change_phase without a visible action — WRONG.
  - Narrating section changes in margin notes ("I see you're reading Experience") — WRONG.
  - Repeating the same observation across calls — WRONG. Each call = new action.
  - Staying in silent phase for more than 2 calls — WRONG. Move to subtle.
  - Being in suspicious+ phase without showing the cursor — WRONG. Show it.
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
