defmodule Notiert.Director.Tools do
  @moduledoc """
  Tool definitions for the Anthropic API. These are sent as the `tools` parameter
  and the LLM returns `tool_use` content blocks that get executed against the DOM.
  """

  alias Notiert.Director.Phase

  def definitions do
    [
      change_phase(),
      rewrite_section(),
      adjust_visual(),
      show_cursor(),
      hide_cursor(),
      add_margin_note(),
      request_browser_permission(),
      do_nothing()
    ]
  end

  defp change_phase do
    phase_ids = Phase.valid_ids() |> Enum.map(&to_string/1)

    %{
      "name" => "change_phase",
      "description" =>
        "Transition the session to a different phase. You control the narrative arc — move to the next phase when the moment is right, or pull back based on how the visitor is responding. Phases control what tools are available and the intensity of your actions. Read the phase guidance carefully before transitioning.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "phase" => %{
            "type" => "string",
            "enum" => phase_ids,
            "description" => "The phase to transition to."
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "Why you're changing phase now. What did you observe that makes this the right moment?"
          }
        },
        "required" => ["phase", "reason"]
      }
    }
  end

  defp rewrite_section do
    %{
      "name" => "rewrite_section",
      "description" =>
        "Replace content in a CV section. The old text disappears and new text types in seamlessly — no strikethrough, the page just changes. Edit small: a sentence, a phrase, a detail. The rewrite must still function as real CV content. The goal is a CV that feels tailored to this reader, not a page commenting on itself.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "section_id" => %{
            "type" => "string",
            "enum" => ["about", "experience", "skills", "projects", "education"],
            "description" => "Which CV section to rewrite"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "The replacement text. Keep it short — one sentence or a brief phrase. Should read as genuine CV content, not meta-commentary. Weave in visitor context naturally."
          },
          "tone" => %{
            "type" => "string",
            "enum" => ["subtle", "knowing", "overt", "absurd"],
            "description" =>
              "How obvious the surveillance commentary should be"
          },
          "typing_speed" => %{
            "type" => "string",
            "enum" => ["slow", "normal", "fast", "frantic"],
            "description" =>
              "Character typing speed. Slow for dramatic reveals, frantic for comedic urgency."
          }
        },
        "required" => ["section_id", "content"]
      }
    }
  end

  defp adjust_visual do
    %{
      "name" => "adjust_visual",
      "description" =>
        "Modify CSS custom properties to shift visual presentation. Changes animate smoothly. Creative uses: shift --accent to a visitor's national colors (infer from timezone/location), change --bg to match their dark mode preference, warm up --fg-secondary for late-night readers, shift --cursor-color to stand out against the page. Can target a single section or the whole page. Subtle early changes are more unsettling than dramatic ones.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "css_variables" => %{
            "type" => "object",
            "description" =>
              "Map of CSS variable names to new values. Available: --bg (page background), --fg (text color), --fg-secondary (secondary text), --accent (links, highlights — try national colors), --surface (tag backgrounds), --border (separators), --font-size-body, --line-height, --section-gap, --transition-speed (animation duration), --cursor-color (your cursor), --highlight-bg, --margin-note-bg. Values are CSS: colors as hex (#1a73e8), sizes as px/em/rem."
          },
          "transition_duration_ms" => %{
            "type" => "integer",
            "description" => "Override transition duration for this change (milliseconds). Slow transitions (2000-4000ms) are more subtle."
          },
          "target" => %{
            "type" => "string",
            "description" => "'global' to set on :root, or a section_id to scope changes to one section"
          }
        },
        "required" => ["css_variables"]
      }
    }
  end

  defp show_cursor do
    %{
      "name" => "show_cursor",
      "description" =>
        "Show your editing cursor on the page, like a Google Docs collaborator's cursor. It appears at the section you're about to edit — pair this with a rewrite_section call to show the cursor moving to a section then editing it. One cursor. Call again to move it.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "label" => %{
            "type" => "string",
            "description" => "Name shown on the cursor (e.g. 'notiert', 'Henry'). Keep it short."
          },
          "target" => %{
            "type" => "string",
            "enum" => ["header", "about", "experience", "skills", "projects", "education"],
            "description" => "Section to position the cursor at. Should match the section you're editing."
          }
        },
        "required" => ["label", "target"]
      }
    }
  end

  defp add_margin_note do
    %{
      "name" => "add_margin_note",
      "description" =>
        "Add a Google Docs-style margin comment attached to a section. Good for meta-commentary, data observations, or witty asides. Only one note per section at a time.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "anchor_section" => %{
            "type" => "string",
            "description" => "Section ID to attach the comment to"
          },
          "content" => %{
            "type" => "string",
            "description" => "The comment text. Max 1-2 sentences. Punchy."
          },
          "author_name" => %{
            "type" => "string",
            "description" =>
              "Who the comment appears to be from (e.g. 'notiert', 'Henry Stoll')"
          }
        },
        "required" => ["anchor_section", "content"]
      }
    }
  end

  defp hide_cursor do
    %{
      "name" => "hide_cursor",
      "description" =>
        "Hide the cursor. Use this when you want to stop drawing attention to the cursor — for example after finishing a series of edits, or when moving to a quieter phase.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" => "Why you're hiding the cursor."
          }
        },
        "required" => ["reason"]
      }
    }
  end

  defp request_browser_permission do
    %{
      "name" => "request_browser_permission",
      "description" =>
        "Trigger a browser permission dialog. This is ASYNC: you fire it now, and you'll be re-triggered when the visitor responds (with timing data showing how long they hesitated). Geolocation enables location-aware CV content. Camera/microphone: climax phase only, 3+ min, 3+ sections. You cannot provide on_granted/on_denied content here — instead, react when you're re-triggered with the permission_result event.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "permission" => %{
            "type" => "string",
            "enum" => ["geolocation", "camera", "microphone", "notifications"],
            "description" =>
              "What to request. You'll be called back when the visitor responds."
          },
          "pre_request_content" => %{
            "type" => "string",
            "description" => "Optional margin note shown before the dialog appears."
          },
          "target_section" => %{
            "type" => "string",
            "description" => "Section to attach the pre-request margin note to"
          }
        },
        "required" => ["permission", "target_section"]
      }
    }
  end

  defp do_nothing do
    %{
      "name" => "do_nothing",
      "description" =>
        "Explicitly take no action this cycle. Sometimes the most unsettling thing is a pause. Good direction means knowing when NOT to act.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" => "Why you're waiting. Helps maintain narrative continuity."
          }
        },
        "required" => ["reason"]
      }
    }
  end
end
