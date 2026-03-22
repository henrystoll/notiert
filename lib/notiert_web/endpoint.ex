defmodule NotiertWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :notiert

  @session_options [
    store: :cookie,
    key: "_notiert_key",
    signing_salt: "notiertSS",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :uri, :user_agent]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :notiert,
    gzip: false,
    only: NotiertWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug :security_headers

  plug NotiertWeb.Router

  defp security_headers(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header(
      "permissions-policy",
      "camera=(self), microphone=(self), geolocation=(self)"
    )
  end
end
