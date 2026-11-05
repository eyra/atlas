defmodule AtlasBFF.TypedWireTest do
  use ExUnit.Case, async: true

  defp schema do
    %{
      models: [%{name: :identity, fields: [%{name: :key, type: :string, required: true}]}],
      endpoints: [],
      protocol: [
        %{
          name: :inspect_one,
          channel: :sample,
          direction: :request,
          request: %{select: %{"op" => "inspect"}, required: %{"target" => :identity}},
          replies: [
            %{
              name: :done,
              select: %{"op" => "done"},
              required: %{"target" => :identity},
              effect: :complete
            }
          ]
        }
      ]
    }
  end

  test "wire envelopes reference shared nested models instead of opaque maps" do
    assert :ok = AtlasBFF.Wire.validate!(schema())
    wires = schema().protocol
    models = Map.new(schema().models, &{&1.name, &1.fields})
    message = %{"op" => "inspect", "target" => %{"key" => "one"}}

    assert {:ok, :inspect_one, ^message} =
             AtlasBFF.Wire.decode_request(wires, :sample, message, models)

    assert {:invalid, _} =
             AtlasBFF.Wire.decode_request(
               wires,
               :sample,
               put_in(message, ["target", "key"], 1),
               models
             )

    assert {:invalid, _} =
             AtlasBFF.Wire.decode_request(
               wires,
               :sample,
               put_in(message, ["target", "extra"], true),
               models
             )
  end

  test "ambiguous command and dispatch bindings fail at compile time" do
    wire = hd(schema().protocol)
    other = %{wire | name: :other}

    assert_raise ArgumentError, ~r/overlapping/, fn ->
      AtlasBFF.Wire.validate!(%{schema() | protocol: [wire, other]})
    end

    wire = Map.put(wire, :cli, ["inspect"])

    other =
      other |> Map.put(:request, %{select: %{"op" => "other"}}) |> Map.put(:cli, ["inspect"])

    assert_raise ArgumentError, ~r/duplicate CLI/, fn ->
      AtlasBFF.Wire.validate!(%{schema() | protocol: [wire, other]})
    end
  end
end
