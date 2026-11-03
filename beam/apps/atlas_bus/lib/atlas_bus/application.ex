defmodule AtlasBus.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AtlasBus.Endpoints},
      {Registry, keys: :duplicate, name: AtlasBus.Listeners},
      AtlasBus.Router
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: AtlasBus.Supervisor)
  end
end
