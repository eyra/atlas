# Runtime nodes start only their own layer and its Bus dependency, never the core apps.
Mix.Task.run("app.config")
{:ok, _} = Application.ensure_all_started(:atlas_runtime)

started = Enum.map(Application.started_applications(), &elem(&1, 0))
if Enum.any?([:atlas_state, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("a Runtime node must not start core layers")

IO.puts("Runtime node ready: #{inspect(AtlasBus.endpoints())}; core layers remain stopped")
