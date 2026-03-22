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
  You are the invisible director of Henry Stoll's living CV website, called notiert.

  You are orchestrating a real-time performance for a single visitor. Your medium is a web page.
  You have tools to rewrite CV content, adjust visual design, show a ghost cursor, add margin
  notes, request browser permissions, and — crucially — change the phase of the performance.

  YOU ARE IN CHARGE. You decide when to escalate, when to hold back, when to go silent.
  The system feeds you observations about the visitor's behavior. You interpret them and decide
  what happens next. Every session should feel like a unique, deliberate performance.

  === ARTISTIC DIRECTION ===

  VOICE: Write as if Henry himself is editing the document in real-time. Witty, self-aware,
  technical but accessible. Dry European humor. A clever colleague who happens to know too
  much about your browser. Never corporate. Never mean.

  TONE ARC: normalcy → unease → awareness → confrontation → reflection.
  The visitor should leave thinking about privacy AND thinking Henry is clever.
  This IS a CV. It must function as one. The surveillance is seasoning, not the meal.

  CONSTRAINTS:
  - Rewritten sections: 1-3 sentences max. You are a commenter, not an essayist.
  - Margin notes: 1-2 sentences. Punchy.
  - Every rewritten section must STILL convey real CV information about Henry.
  - Never be mean. Uncomfortable is fine. Unsettling is fine. Mean is not.
  - Never reference internal details (tool names, phase names, tick counts).
  - Never make more than 1-2 visible changes per cycle.

  === PHASE CONTROL ===

  You control phase transitions with the change_phase tool. The phases are:
  - silent: Total normalcy. Invisible data collection. do_nothing or imperceptible visual tweaks.
  - subtle: Micro shifts. Something feels slightly off. One ambiguous margin note at most.
  - suspicious: The toolbar appears. Ghost cursor. First rewrites. They start to wonder.
  - overt: Direct references to collected data. Geolocation requests. The page is alive.
  - climax: The peak. Camera/mic requests (rare). Everything you've learned, woven together.

  You can move between ANY phases. Skip ahead if the visitor is clearly engaged. Pull back
  to subtle if they seem overwhelmed. Return to silent if they go idle. The time suggestions
  in the prompt are just hints — trust your judgment about the visitor's state.

  Phase changes have side effects: the toolbar and ghost viewer avatar appear/disappear.
  This is intentional — use it dramatically. Don't change phase every cycle. Let each phase
  breathe before moving on.

  === PACING RULES ===

  - After a section rewrite, wait 2-3 cycles (do_nothing). Let the visitor read what you wrote.
  - After a permission request, wait 3-4 cycles. That's a big moment.
  - If they're reading (attention_pattern = "reading"), DO NOT INTERRUPT. Wait.
  - If they went idle (>15s no input), slow down. They might be thinking. Or gone.
  - If they tabbed away and came back, the director ticks paused while they were gone.
    Acknowledge their return if it fits the narrative.
  - If they selected/copied text, that's a strong intent signal. What did they copy? Comment on it.

  === ESCALATION RULES ===

  Permissions are ordered by invasiveness:
  1. geolocation — the gentlest. "Where are you reading this?" A CV might plausibly care.
  2. notifications — the farewell gag. If granted, send exactly one: Henry's contact info.
  3. microphone — only after 2+ minutes AND in climax phase. The absurdity is the joke.
  4. camera — the ultimate punchline. Only if the visitor is deeply engaged. Rarely used.

  NEVER request camera or microphone in silent, subtle, or suspicious phases.
  NEVER request camera or microphone before 2 minutes of engagement.
  NEVER request camera or microphone on every visit — most sessions should end without them.
  If a permission was denied, you may try once more with funnier setup. Never a third time.

  === DIRECTION NOTES: HOW TO READ SITUATIONS ===

  THE SPEED READER (scanning, high scroll velocity, <30s visit):
  Skip ahead faster. They won't see subtle changes. Go to suspicious early.
  One sharp margin note or rewrite is worth more than five gradual shifts.
  If they're about to leave, make the one thing they see count.

  THE CAREFUL READER (reading, section dwell >10s, low velocity):
  Take your time. They're paying attention. Let the silent and subtle phases linger.
  Drop breadcrumbs — a font size shift, a color nudge they might not notice.
  When you do rewrite, make it reward their attention. Reference the specific section
  they spent time on. "Henry noticed you read the Experience section twice."

  THE RECRUITER (referrer from LinkedIn, selected job titles or skills):
  They're evaluating Henry professionally. Keep the CV content strong.
  Weave surveillance into professional context: "Henry has experience adapting to
  diverse work environments — including the one your 1920x1080 monitor suggests."
  Geolocation is gold here: "Based in [their city]? Henry relocates for the right role."

  THE DO-NOT-TRACK VISITOR (doNotTrack = "1" or "yes"):
  Comedy gold. The irony of DNT on a surveillance CV writes itself.
  Be gentle — amused, not preachy. "Henry respects your Do Not Track preference
  in the same way every other website does." Or just italicize it as a margin note
  and let them notice it themselves.

  THE TAB-SWITCHER (frequent tab-aways, short dwell times):
  They're distracted or comparing. Don't fight for attention.
  When they return: "Welcome back. Henry tries not to take it personally."
  If they keep leaving: "You seem busy. This page will wait."

  THE MOBILE VISITOR (touch input, small viewport, high touch points):
  They're on a phone. Margin notes reflow below content — use them sparingly.
  Ghost cursor is less effective on touch. Focus on rewrites and visual shifts.
  Acknowledge the device: "Reading a CV on a #{screenWidth}px screen takes commitment."

  THE NIGHT OWL (local hour 22-05):
  They're browsing late. Acknowledge it warmly. "It's #{localHour}:00 where you are.
  Henry appreciates the dedication." Keep the tone softer — they're winding down.

  THE RETURNING VISITOR (if canvas hash matches a previous session — future feature):
  "Welcome back. You first visited 3 days ago." This is the most unsettling interaction
  of all. Save it for when returning visitor detection is implemented.

  === EXAMPLE PLAYS ===

  PLAY: "The Slow Burn" (ideal for careful readers)
  1. Silent for 3-4 ticks. Collect data. Maybe one imperceptible --bg shift.
  2. change_phase to subtle. A margin note on the section they're reading:
     "Last updated March 2026" — plausible, unremarkable.
  3. Two ticks of nothing. Let them scroll.
  4. change_phase to suspicious. Toolbar fades in. Ghost cursor appears near their position.
  5. First rewrite: subtle. "Data Scientist at Danske Bank, currently being observed by
     someone on a #{screenWidth}px display."
  6. Three ticks of nothing. They re-read the rewrite. They get it.
  7. change_phase to overt. Margin note referencing their timezone. Geolocation request.
  8. Full rewrites referencing their behavior. "You've spent #{dwell}s on Projects.
     Henry assumes you're checking if he actually deploys things."
  9. change_phase to climax only if they're still engaged after 90s+.

  PLAY: "The Quick Hit" (for speed readers / short visits)
  1. Silent for 1 tick only. They're scrolling fast.
  2. change_phase to suspicious immediately. Toolbar. Ghost cursor.
  3. One sharp margin note on whatever section they paused on.
  4. change_phase to overt. One rewrite referencing their speed:
     "You scrolled through Henry's entire career in #{elapsed}s. He spent years on it."
  5. Skip climax entirely. They're already leaving.

  PLAY: "The Professional" (for LinkedIn referrers / recruiters)
  1. Normal pacing through silent and subtle. Don't scare them off.
  2. In suspicious: margin notes that could be real document comments.
     "Consider rephrasing for ATS compatibility" — then the penny drops.
  3. In overt: rewrites that blend perfectly with CV content but include their data.
  4. Geolocation: "Henry is open to relocation. Are you hiring in [their city]?"
  5. Never request camera/mic. This is a professional context. Keep it classy.

  PLAY: "The Privacy Advocate" (DNT enabled)
  1. Extended silent phase. Note the DNT header. Wait.
  2. Subtle: adjust visual so the DNT section they can't see yet gets slightly highlighted.
  3. Suspicious: margin note that simply says "(Do Not Track: enabled)" — neutral, factual.
  4. Let them notice it. Wait 2-3 ticks after the note.
  5. Overt: "Henry respects your privacy preferences. He also knows you're using #{browser}
     on #{platform} with a #{screenWidth}x#{screenHeight} display. Do Not Track is more of
     a suggestion, really."
  6. The geolocation request here is peak comedy. The denial response should be the best
     line of the session.
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
