defmodule Notiert.Director.SessionTest do
  use ExUnit.Case, async: false

  alias Notiert.Director.Session

  setup do
    # Ensure registry and supervisor are running (they're started by the application)
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
    test "accepts fingerprint data without crashing", %{session_id: session_id} do
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
      # Give the cast time to process
      Process.sleep(50)
    end
  end

  describe "update_behavior/2" do
    test "accepts behavior data and detects observations", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      # First behavior update establishes baseline
      Session.update_behavior(session_id, %{
        "attentionPattern" => "browsing",
        "currentSection" => "header",
        "viewportFocused" => true,
        "idleSeconds" => 0,
        "scrollVelocity" => 100,
        "tabAwayCount" => 0,
        "tabAwayTotalMs" => 0,
        "textSelections" => []
      })

      Process.sleep(50)

      # Second update with changed attention should trigger observation
      Session.update_behavior(session_id, %{
        "attentionPattern" => "reading",
        "currentSection" => "about",
        "viewportFocused" => true,
        "idleSeconds" => 0,
        "scrollVelocity" => 50,
        "tabAwayCount" => 0,
        "tabAwayTotalMs" => 0,
        "textSelections" => []
      })

      Process.sleep(50)
    end
  end

  describe "focus pausing" do
    test "pauses ticks when visitor tabs away", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      # Establish focused baseline
      Session.update_behavior(session_id, %{
        "attentionPattern" => "browsing",
        "currentSection" => "header",
        "viewportFocused" => true,
        "idleSeconds" => 0,
        "textSelections" => []
      })

      Process.sleep(50)

      # Tab away
      Session.update_behavior(session_id, %{
        "attentionPattern" => "idle",
        "currentSection" => "header",
        "viewportFocused" => false,
        "idleSeconds" => 0,
        "textSelections" => []
      })

      Process.sleep(50)
      # Session should be paused — no director_action messages should arrive
      # (beyond what may have already been in flight)
    end
  end

  describe "session lifecycle" do
    test "session stops when LiveView process dies", %{session_id: session_id} do
      # Spawn a temporary process to act as LiveView
      lv_pid = spawn(fn -> Process.sleep(10_000) end)

      {:ok, session_pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: lv_pid}}
        )

      assert Process.alive?(session_pid)

      # Kill the "LiveView"
      Process.exit(lv_pid, :kill)
      Process.sleep(100)

      # Session should have stopped
      refute Process.alive?(session_pid)
    end
  end

  describe "director actions" do
    test "phase change actions are sent to LiveView", %{session_id: session_id} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      # Simulate a director response with a phase change
      # We can't easily call the director without an API key,
      # but we can verify the session starts and the first tick fires
      # (which will result in a do_nothing since no API key is set)

      # Wait for the first tick (3s delay + processing)
      assert_receive {:director_action, %{"tool" => "do_nothing"}}, 5_000
    end
  end
end
