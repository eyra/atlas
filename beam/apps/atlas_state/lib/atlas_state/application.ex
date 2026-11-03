defmodule AtlasState.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:atlas_state, :start, true) do
        [
          {AtlasState.Server,
           rela: {AtlasState.Rela.Http, Application.fetch_env!(:atlas_state, :rela_url)},
           data_dir: Application.fetch_env!(:atlas_state, :data_dir)}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasState.Supervisor)
  end
end
