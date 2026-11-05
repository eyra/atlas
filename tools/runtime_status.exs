defmodule AtlasRuntimeStatusCLI do
  @moduledoc false
  alias AtlasBFFContract.Runtime.MachineProtocol, as: Wire

  def run([root, environment, settings | argv]) do
    id = Integer.to_string(System.unique_integer([:positive]))

    case Wire.options(:runtime_machine_status_options, argv) do
      {:invalid, why} ->
        error(id, environment, "invalid_options", why, "--json" in argv)

      {:ok, options} ->
        machine = options["machine"] || configured_machine(settings)

        if is_binary(machine) and machine != "" do
          target = %{environment: environment, machine: machine}

          {:ok, :runtime_machine_status, request} =
            Wire.cli(["status"], %{id: id, target: target})

          observe(root, environment, request, options["json"] == true)
        else
          error(
            id,
            environment,
            "machine_required",
            "machine identity unknown; supply --machine or a matching Runtime configuration",
            options["json"] == true
          )
        end
    end
  end

  defp configured_machine(settings) do
    with {:ok, bytes} <- File.read(settings),
         {:ok, %{"runtime" => %{"machine" => machine}}} when is_binary(machine) <-
           JSON.decode(bytes),
         do: machine,
         else: (_ -> nil)
  end

  defp observe(root, environment, request, json?) do
    {bytes, code} =
      System.cmd(
        System.find_executable("python3"),
        [
          Path.join(root, "tools/runtime.py"),
          "_runtime-status-observe",
          root,
          "unused",
          environment,
          JSON.encode!(request)
        ],
        stderr_to_stdout: true
      )

    if code == 0 do
      with {:ok, %{} = status} <- JSON.decode(bytes),
           :ok <- validate_status(status),
           true <- status["target"] == request["target"] do
        reply =
          Wire.reply(:runtime_machine_status, :result, %{
            id: request["id"],
            target: request["target"],
            status: status
          })

        pid = if status["pid"], do: ", pid #{status["pid"]}", else: ""

        if json?,
          do: IO.puts(JSON.encode!(reply)),
          else:
            IO.puts(
              "Runtime #{environment}: #{status["state"]} (machine #{status["target"]["machine"]}#{pid}); #{status["message"]}; log #{status["log"]}"
            )
      else
        _ ->
          error(
            request["id"],
            environment,
            "invalid_diagnostic",
            "local status handler returned malformed or mismatched diagnostics",
            json?
          )
      end
    else
      error(
        request["id"],
        environment,
        "diagnostic_unavailable",
        "local status handler unavailable; no Runtime was started",
        json?
      )
    end
  end

  defp validate_status(status) do
    AtlasBFF.Targets.Protocol.validate_value!(Wire.models(), :runtime_machine_status, status)
  rescue
    ArgumentError -> :invalid
  end

  defp error(id, environment, code, message, json?) do
    reply =
      Wire.reply(:runtime_machine_status, :error, %{
        id: id,
        error: %{code: code, message: message, retryable: false}
      })

    if json?,
      do: IO.puts(JSON.encode!(reply)),
      else: IO.puts(:stderr, "Runtime #{environment}: unsupported; #{message}")

    System.halt(2)
  end
end

AtlasRuntimeStatusCLI.run(System.argv())
