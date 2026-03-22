defmodule Notiert.Director.SessionTest do
  use ExUnit.Case, async: false

  alias Notiert.Director.Session

  setup do
    session_id = "test-#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  describe "start_link/1" do
    test "starts a session process", %{session_id: session_id} do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      assert Process.alive?(pid)
    end
  end

  describe "update_fingerprint/2" do
    test "accepts fingerprint and triggers director", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      fingerprint = %{
        "userAgent" => "TestBrowser/1.0",
        "platform" => "TestOS",
        "language" => "en",
        "doNotTrack" => "1",
        "screenWidth" => 1920,
        "screenHeight" => 1080,
        "pixelRatio" => 2,
        "maxTouchPoints" => 0
      }

      assert :ok == Session.update_fingerprint(session_id, fingerprint)
      # Fingerprint triggers a debounced director call
      # With no API key, it returns do_nothing
      assert_receive {:director_action, %{"tool" => "do_nothing"}}, 5_000
    end
  end

  describe "update_behavior/2" do
    test "detects section change and triggers director", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      # First behavior establishes baseline
      Session.update_behavior(session_id, %{
        "attentionPattern" => "browsing",
        "currentSection" => "header",
        "viewportFocused" => true,
        "idleSeconds" => 0,
        "scrollVelocity" => 100,
        "tabAwayCount" => 0,
        "tabAwayTotalMs" => 0,
        "textSelections" => [],
        "sectionDwells" => %{}
      })

      Process.sleep(50)

      # Second update with section change triggers director
      Session.update_behavior(session_id, %{
        "attentionPattern" => "reading",
        "currentSection" => "about",
        "viewportFocused" => true,
        "idleSeconds" => 0,
        "scrollVelocity" => 50,
        "tabAwayCount" => 0,
        "tabAwayTotalMs" => 0,
        "textSelections" => [],
        "sectionDwells" => %{"header" => %{"totalMs" => 3000, "entries" => 1}}
      })

      # Should trigger director via debounce (section_change + attention_change)
      assert_receive {:director_action, _}, 5_000
    end
  end

  describe "focus pausing" do
    test "pauses when visitor tabs away", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      Session.update_behavior(session_id, %{
        "attentionPattern" => "browsing",
        "currentSection" => "header",
        "viewportFocused" => true,
        "idleSeconds" => 0,
        "textSelections" => []
      })

      Process.sleep(50)

      Session.update_behavior(session_id, %{
        "attentionPattern" => "idle",
        "currentSection" => "header",
        "viewportFocused" => false,
        "idleSeconds" => 0,
        "textSelections" => []
      })

      Process.sleep(50)
    end
  end

  describe "session lifecycle" do
    test "session stops when LiveView process dies", %{session_id: session_id} do
      lv_pid = spawn(fn -> Process.sleep(10_000) end)

      {:ok, session_pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: lv_pid}}
        )

      assert Process.alive?(session_pid)
      Process.exit(lv_pid, :kill)
      Process.sleep(100)
      refute Process.alive?(session_pid)
    end
  end

  describe "permission timing" do
    test "permission result triggers director immediately", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      # Wait for initial trigger to complete
      assert_receive {:director_action, _}, 5_000

      # Simulate permission result
      Session.update_permission(session_id, "geolocation", "granted", %{
        "latitude" => 55.6761,
        "longitude" => 12.5683,
        "accuracy" => 20
      })

      # Permission results fire immediately (no debounce)
      assert_receive {:director_action, _}, 5_000
    end
  end
end
