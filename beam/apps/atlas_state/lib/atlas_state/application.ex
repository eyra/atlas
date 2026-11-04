defmodule AtlasState.Application do
  @moduledoc false
  use Application

  # The connectors at State's edge, by their name under `connectors` in `env/<env>.json`.
  @sources %{"github" => AtlasState.Connector.GitHub}

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:atlas_state, :start, true) do
        data_dir = Application.fetch_env!(:atlas_state, :data_dir)

        # A rela on a private IPv6 network (Fly): try IPv6 first, IPv4 next.
        if Application.get_env(:atlas_state, :rela_ipv6),
          do: :ok = :httpc.set_options(ipfamily: :inet6fb4)

        [
          {AtlasState.Server,
           rela: {AtlasState.Rela.Http, Application.fetch_env!(:atlas_state, :rela_url)},
           data_dir: data_dir,
           description_extra: Application.get_env(:atlas_state, :description_extra)}
        ] ++ connectors(data_dir)
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AtlasState.Supervisor)
  end

  # An environment without a connector's settings has no such connector: it does nothing
  # there (d-0003).
  defp connectors(data_dir) do
    for {system, settings} <- Application.get_env(:atlas_state, :connectors, %{}),
        is_map(settings),
        source = @sources[system] do
      Supervisor.child_spec(
        {AtlasState.Connector,
         system: system,
         source: {source, settings},
         every: (settings["every_seconds"] || 300) * 1000,
         data_dir: data_dir},
        id: {AtlasState.Connector, system}
      )
    end
  end
end
