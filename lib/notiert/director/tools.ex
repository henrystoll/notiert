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
      show_ghost_cursor(),
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
        "Transition the session to a different phase. You control the narrative arc — move to the next phase when the moment is right, or skip ahead or pull back based on how the visitor is responding. Phase changes affect what UI elements are visible (toolbar, ghost viewer) and set the tone for your subsequent actions. Read the phase guidance carefully before transitioning.",
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
        "Modify CSS custom properties to shift visual presentation. Changes animate smoothly via CSS transitions. Subtle changes early are more unsettling than dramatic ones.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "css_variables" => %{
            "type" => "object",
            "description" =>
              "Map of CSS variable names to new values. Available: --bg, --fg, --fg-secondary, --accent, --surface, --border, --font-size-body, --line-height, --section-gap, --transition-speed, --cursor-color, --highlight-bg, --margin-note-bg"
          },
          "transition_duration_ms" => %{
            "type" => "integer",
            "description" => "Override transition duration for this change (milliseconds)"
          },
          "target" => %{
            "type" => "string",
            "description" => "'global' to set on :root, or a section_id to scope changes"
          }
        },
        "required" => ["css_variables"]
      }
    }
  end

  defp show_ghost_cursor do
    %{
      "name" => "show_ghost_cursor",
      "description" =>
        "Display a second cursor on the page with a name label, like a Google Docs collaborator. Extremely unsettling.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "cursor_label" => %{
            "type" => "string",
            "description" => "Name shown on the cursor label (e.g. 'notiert', 'Henry')"
          },
          "behavior" => %{
            "type" => "string",
            "enum" => ["follow_user", "move_to_element"],
            "description" =>
              "follow_user: trails real cursor with delay. move_to_element: positions at a specific section."
          },
          "target" => %{
            "type" => "string",
            "description" => "For move_to_element: section_id to position near"
          }
        },
        "required" => ["cursor_label", "behavior"]
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

  defp request_browser_permission do
    %{
      "name" => "request_browser_permission",
      "description" =>
        "Trigger a browser permission dialog. Geolocation enables location-aware CV content — use it when it would make the CV more relevant. Camera and microphone require: climax phase, 3+ minutes of active engagement, interaction with 3+ sections. Most sessions should never use camera/mic.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "permission" => %{
            "type" => "string",
            "enum" => ["geolocation", "camera", "microphone", "notifications"],
            "description" =>
              "What to request. Geolocation for location-aware content. Camera/microphone: climax phase only, 3+ min engagement, 3+ sections visited. Notifications as a farewell."
          },
          "pre_request_content" => %{
            "type" => "string",
            "description" => "Margin note shown before the dialog. Sets up the joke."
          },
          "on_granted_content" => %{
            "type" => "string",
            "description" => "Response if they allow it."
          },
          "on_denied_content" => %{
            "type" => "string",
            "description" => "Response if they deny. Should be funnier."
          },
          "target_section" => %{
            "type" => "string",
            "description" => "Section to attach commentary to"
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
