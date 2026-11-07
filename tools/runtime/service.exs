# Runtime service. Neither Atlas core services nor an orchestration engine starts.
Application.put_env(:atlas_runtime, :start, false)
{:ok, _} = Application.ensure_all_started(:atlas_runtime)
started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:atlas_state, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("Runtime must not start Atlas core services")

[dir] = System.argv()
{:ok, _} = AtlasRuntime.Service.start(dir)
IO.puts("Runtime ready; Atlas core services remain stopped")
Process.sleep(:infinity)
