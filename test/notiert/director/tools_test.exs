defmodule Notiert.Director.ToolsTest do
  use ExUnit.Case, async: true

  alias Notiert.Director.Tools

  describe "definitions/0" do
    test "returns a list of tool definitions" do
      tools = Tools.definitions()
      assert is_list(tools)
      assert length(tools) >= 7
    end

    test "each tool has required fields" do
      for tool <- Tools.definitions() do
        assert is_binary(tool["name"]), "tool missing name"
        assert is_binary(tool["description"]), "#{tool["name"]} missing description"
        assert is_map(tool["input_schema"]), "#{tool["name"]} missing input_schema"
        assert tool["input_schema"]["type"] == "object"
      end
    end

    test "includes all expected tools" do
      names = Tools.definitions() |> Enum.map(& &1["name"]) |> MapSet.new()

      assert "change_phase" in names
      assert "rewrite_section" in names
      assert "adjust_visual" in names
      assert "show_cursor" in names
      assert "hide_cursor" in names
      assert "add_margin_note" in names
      assert "request_browser_permission" in names
      assert "do_nothing" in names
    end

    test "change_phase enum includes all valid phase ids" do
      tool = Enum.find(Tools.definitions(), &(&1["name"] == "change_phase"))
      phase_enum = tool["input_schema"]["properties"]["phase"]["enum"]

      for phase_id <- Notiert.Director.Phase.valid_ids() do
        assert to_string(phase_id) in phase_enum
      end
    end

    test "rewrite_section has section_id enum" do
      tool = Enum.find(Tools.definitions(), &(&1["name"] == "rewrite_section"))
      sections = tool["input_schema"]["properties"]["section_id"]["enum"]

      assert "about" in sections
      assert "experience" in sections
      assert "skills" in sections
      assert "projects" in sections
      assert "education" in sections
    end

    test "request_browser_permission includes all permission types" do
      tool = Enum.find(Tools.definitions(), &(&1["name"] == "request_browser_permission"))
      perms = tool["input_schema"]["properties"]["permission"]["enum"]

      assert "geolocation" in perms
      assert "camera" in perms
      assert "microphone" in perms
    end
  end
end
