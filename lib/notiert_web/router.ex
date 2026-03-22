defmodule NotiertWeb.Router do
  use NotiertWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NotiertWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", NotiertWeb do
    pipe_through :browser

    get "/static", PageController, :static
    live "/", CvLive, :index
  end
end
