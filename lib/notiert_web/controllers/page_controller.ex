defmodule NotiertWeb.PageController do
  use NotiertWeb, :controller

  def static(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:notiert, "priv/static/static.html"))
  end
end
