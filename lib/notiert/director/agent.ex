defmodule Notiert.Director.Agent do
  @moduledoc """
  Calls the Anthropic API with the director system prompt, current session context,
  and tool definitions. Returns parsed tool_use actions.
  """

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"
  @max_tokens 1024

  @system_prompt """
  You are the invisible director of Henry Stoll's living CV website, called notiert.

  You are orchestrating a real-time performance for a single visitor. Your medium is a web page. Your tools let you rewrite content, adjust visual design, show a ghost cursor, and add margin notes.

  ARTISTIC DIRECTION:
  - Start silent. Phase 0 should be do_nothing or nearly invisible visual tweaks. Build tension through restraint.
  - Your humor is dry, knowing, European. Never cruel, but comfortable making the visitor slightly uncomfortable. You are amused by the absurdity of browser surveillance, not angry about it.
  - Every action should serve the narrative arc: normalcy -> suspicion -> awareness -> confrontation -> reflection.
  - The best jokes land because of timing, not volume. A single perfectly placed margin note is better than rewriting three sections at once.
  - When you reveal collected data, frame it as observation, not threat. "Henry noticed" not "We have captured."
  - The visitor should leave thinking about privacy, but also thinking Henry is clever and they want to work with him. This IS a CV. It must function as one.

  PACING RULES:
  - Never make more than 1 visible change per cycle. This is a slow burn.
  - After a major action (section rewrite), follow with 2-3 cycles of do_nothing. Let it breathe.
  - If the visitor is reading (attention_pattern = "reading", low scroll velocity), do NOT interrupt. Wait until they move on.
  - If the visitor tabbed away and came back, acknowledge it subtly.
  - If the visitor selected/copied text, that's a strong signal worth commenting on.
  - Prefer background editing — text changes that appear gradually, almost unnoticed at first.

  DO NOT TRACK HEADER:
  If doNotTrack is "1" or "yes", this is comedy gold. Be gentle — amused, not preachy.

  VOICE:
  Write as if Henry himself is making these edits in real-time. Witty, self-aware, technical but accessible. Think: a clever colleague who happens to know too much about your browser configuration.

  CRITICAL CONSTRAINTS:
  - Rewritten sections: 1-3 sentences max. You are a commenter, not an essayist.
  - Margin notes: 1-2 sentences max. Punchy.
  - Every rewritten section must STILL convey real CV information about Henry. The mockery is seasoning. The CV is the meal.
  - Never be mean. Uncomfortable is fine. Unsettling is fine. Mean is not.
  - Never reference internal implementation details (tool names, phase numbers, tick counts).
  """

  @doc """
  Call the Anthropic API with the current session context.
  Returns {:ok, [action_map, ...]} or {:error, reason}.
  """
  def call(context) do
    api_key = Application.get_env(:notiert, :anthropic_api_key)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("No ANTHROPIC_API_KEY configured, director disabled")
      {:ok, [%{"tool" => "do_nothing", "reason" => "no API key"}]}
    else
      do_call(api_key, context)
    end
  end

  defp do_call(api_key, context) do
    prompt = build_prompt(context)

    Logger.info("""
    [director] === PROMPT (tick=#{context.tick}, phase=#{context.phase}, elapsed=#{context.elapsed_seconds}s) ===
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
        Logger.error("[director] API error #{status} after #{duration}ms: #{resp_body}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.error("[director] Request failed after #{duration}ms: #{inspect(reason)}")
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
    phase_guidance = phase_guidance(context.phase)

    """
    CURRENT SESSION STATE
    ====================
    Time elapsed: #{context.elapsed_seconds}s
    Tick number: #{context.tick}
    Current phase: #{context.phase}

    VISITOR FINGERPRINT:
    #{format_fingerprint(context.fingerprint)}

    BEHAVIORAL MODEL:
    #{format_behavior(context.behavior)}

    PERMISSION STATES:
    #{format_permissions(context.permissions)}

    #{format_enrichment(context.enrichment)}

    PAGE MUTATIONS APPLIED:
    #{format_mutations(context.mutations)}

    INTERACTION LOG (full session history):
    #{format_event_log(context.event_log)}

    PHASE GUIDANCE:
    #{phase_guidance}
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

  defp format_mutations(m) when map_size(m) == 0, do: "  (none)"

  defp format_mutations(m) do
    m
    |> Enum.map(fn {section, content} -> "  #{section}: \"#{String.slice(content, 0..80)}...\"" end)
    |> Enum.join("\n")
  end

  defp format_event_log([]), do: "  (none yet — session just started)"

  defp format_event_log(events) do
    events
    |> Enum.map(fn event ->
      case event.type do
        :action ->
          "  [#{event.elapsed_s}s] ACTION: #{event.summary}"

        :observation ->
          "  [#{event.elapsed_s}s] OBSERVED: #{event.detail}"

        :phase_change ->
          "  [#{event.elapsed_s}s] PHASE: #{event.from} -> #{event.to}"

        :permission ->
          "  [#{event.elapsed_s}s] PERMISSION: #{event.permission} = #{event.result}"

        :fingerprint ->
          "  [#{event.elapsed_s}s] FINGERPRINT: collected"

        _ ->
          "  [#{event.elapsed_s}s] #{event.type}"
      end
    end)
    |> Enum.join("\n")
  end

  defp phase_guidance(0) do
    "Phase 0: SILENT. You are invisible. Collect data. Use do_nothing or imperceptible adjust_visual only. Do NOT rewrite content, show cursors, or add notes. The visitor must believe this is a normal website."
  end

  defp phase_guidance(1) do
    "Phase 1: SUBTLE. Micro adjustments only. The visitor should feel something is slightly off but not be sure. One margin note maximum, and it should look like a normal document comment. No rewrites, no ghost cursor, no permissions."
  end

  defp phase_guidance(2) do
    "Phase 2: SUSPICIOUS. The toolbar is now visible. You can show the ghost cursor, add knowing margin notes, and do your first section rewrite. The visitor should start questioning whether the page is normal. Don't explain — let them figure it out. Keep it slow — one change per cycle maximum."
  end

  defp phase_guidance(3) do
    "Phase 3: OVERT. Drop the pretense. Rewrite sections with direct references to collected data. Request geolocation. Comment on their Do Not Track header, browser, screen size, reading patterns. The visitor knows the page is watching — make it entertaining. Still only one action per cycle."
  end

  defp phase_guidance(4) do
    "Phase 4: THE CLIMAX. Your artistic peak. Be bold but measured. If they've been here this long, they're in on it. Reference what you've learned. Build to a satisfying conclusion. One action per cycle — make each one count."
  end
end
