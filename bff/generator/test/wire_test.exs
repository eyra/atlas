defmodule AtlasBFF.WireTest do
  use ExUnit.Case, async: true
  alias AtlasBFF.Wire

  defmodule Contract do
    def __schema__ do
      %{
        version: "1",
        models: [],
        pages: [],
        endpoints: [%{name: :probe, call: :probe, wire: :probe, path: nil, takes: nil}],
        protocol: [
          %{
            name: :probe,
            channel: :remote,
            direction: :request,
            request: %{select: %{"op" => "probe"}, required: %{"tag" => :string}},
            replies: [
              %{name: :ready, select: %{"op" => "ready"}, effect: :progress},
              %{
                name: :done,
                select: %{"op" => "answer"},
                absent: ["error"],
                required: %{"value" => :integer},
                effect: :complete,
                requires: [:ready]
              },
              %{
                name: :failed,
                select: %{"op" => "answer"},
                present: ["error"],
                required: %{"error" => :string},
                effect: :error
              }
            ]
          },
          %{
            name: :stop,
            channel: :remote,
            direction: :push,
            replies: [%{name: :stop, select: %{"op" => "stop"}, effect: :terminal}]
          },
          %{
            name: :local,
            channel: :local,
            direction: :stream,
            request: %{select: %{"op" => "local"}},
            replies: [%{name: :part, select: %{"op" => "part"}, effect: :progress}]
          }
        ]
      }
    end
  end

  defmodule Protocol do
    use AtlasBFF.Targets.Protocol, contract: Contract
  end

  test "plain schema alone supplies new envelopes and classification without target edits" do
    assert Protocol.request(:probe, [tag: "α"], :remote) == %{"op" => "probe", "tag" => "α"}

    assert {:reply, %{name: :done, effect: :complete, requires: [:ready]}} =
             Protocol.classify(
               :probe,
               %{"op" => "answer", "value" => 3, "additive" => true},
               :remote
             )

    assert {:reply, %{effect: :error}} =
             Protocol.classify(:probe, %{"op" => "answer", "error" => "no"}, :remote)

    assert {:reply, %{effect: :terminal}} = Protocol.classify(:probe, %{"op" => "stop"}, :remote)
    assert {:invalid, _} = Protocol.classify(:probe, %{"op" => "answer"}, :remote)
    assert {:invalid, _} = Protocol.classify(:probe, %{"op" => "answer", "value" => "3"}, :remote)
    assert {:invalid, _} = Protocol.classify(:probe, [], :remote)
    assert :ignore = Protocol.classify(:probe, %{"op" => "part"}, :remote)

    for {name, channel} <- [
          {:stop, :remote},
          {:local, :remote},
          {:local, :local},
          {:probe, :local}
        ] do
      assert_raise ArgumentError, fn -> Protocol.request(name, %{}, channel) end
    end

    assert_raise ArgumentError, fn -> Protocol.request(:probe, [tag: 3], :remote) end

    assert_raise ArgumentError, fn ->
      Protocol.request(:probe, [tag: "x", other: true], :remote)
    end
  end

  test "invalid, incomplete, overlapping or executable selectors and classification fail" do
    schema = Contract.__schema__()
    [wire | rest] = schema.protocol
    [ready, done, failed] = wire.replies

    for {replacement, error} <- [
          {%{wire | direction: :other}, "direction"},
          {%{wire | replies: []}, "incomplete"},
          {%{wire | replies: [ready]}, "completion"},
          {%{wire | replies: [%{done | select: %{}}]}, "needs an op"},
          {%{wire | replies: [%{done | select: %{"op" => fn -> true end}}]}, "needs an op"},
          {%{wire | replies: [done, done]}, "duplicate"},
          {%{wire | replies: [ready, done, Map.merge(failed, %{present: [], absent: []})]},
           "overlapping"},
          {%{wire | replies: [ready, %{done | requires: [:missing]}, failed]},
           "unknown required"},
          {%{wire | replies: [ready, %{done | requires: [:done]}, failed]}, "prerequisite"},
          {%{wire | replies: [ready, Map.put(done, :absent, ["op"]), failed]}, "contradictory"},
          {%{wire | replies: [ready, Map.put(done, :required, %{"value" => :bad}), failed]},
           "invalid envelope"}
        ] do
      assert_raise ArgumentError, ~r/#{error}/, fn ->
        Wire.validate!(%{schema | protocol: [replacement | rest]})
      end
    end

    assert_raise ArgumentError, ~r/unclassified/, fn ->
      Wire.validate!(%{schema | endpoints: [%{name: :extra, wire: nil}]})
    end

    assert_raise ArgumentError, ~r/call mismatch/, fn ->
      Wire.validate!(%{schema | endpoints: [%{name: :extra, call: :other, wire: :probe}]})
    end

    assert_raise ArgumentError, ~r/unclassified endpoint reply/, fn ->
      Wire.validate!(%{
        schema
        | endpoints: [%{name: :probe, call: :probe, wire: :probe, replies: [%{name: :missing}]}]
      })
    end

    assert_raise ArgumentError, ~r/overlapping/, fn ->
      push = %{
        name: :bad,
        channel: :remote,
        direction: :push,
        replies: [Map.delete(done, :requires)]
      }

      Wire.validate!(%{schema | protocol: [wire, push]})
    end
  end

  test "DSL validates protocol and exports it as plain data" do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use AtlasBFF.Schema
          version "1"
          protocol(unquote(Macro.escape(Contract.__schema__().protocol)))
          defendpoint :probe, call: :probe, wire: :probe, replies: [done: :view_model]
        end
      end
    )

    assert module.__schema__().protocol == Contract.__schema__().protocol
  end
end
