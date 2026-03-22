defmodule Notiert.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Notiert.PubSub},
      {Registry, keys: :unique, name: Notiert.SessionRegistry},
      {DynamicSupervisor, name: Notiert.SessionSupervisor, strategy: :one_for_one},
      NotiertWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Notiert.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NotiertWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
