defmodule AtlasControl.SpecTest do
  use ExUnit.Case, async: true

  alias AtlasControl.Blocks

  test "the generated server, client and JSON files are up to date with the spec" do
    for {path, content} <- AtlasControl.Spec.Gen.files() do
      assert File.read!(Path.join(AtlasControl.Spec.Gen.root(), path)) == content,
             "#{path} is out of date; run `mix atlas.gen`"
    end
  end

  test "builders check blocks before Control sends them" do
    assert %{"type" => "confirm", "props" => %{"title" => "T", "text" => "x", "cancel_to" => "/"}} =
             Blocks.confirm(title: "T", text: "x", cancel_to: "/", confirm_to: nil)

    assert_raise ArgumentError, ~r/confirm.cancel_to is required/, fn ->
      Blocks.confirm(title: "T", text: "x")
    end

    assert_raise ArgumentError, ~r/must be "string"/, fn -> Blocks.pair(label: 1) end
    assert_raise ArgumentError, ~r/no field/, fn -> Blocks.pair(label: "x", colour: "red") end
  end

  test "a spec mistake fails at compile time" do
    assert_raise CompileError, ~r/holds block :a; blocks have no children/, fn ->
      Code.compile_string("""
      defmodule BadSpec do
        use AtlasControl.Spec
        version "0"
        defblock :a do
          field :x, :string
        end
        defblock :b do
          field :inner, :a
        end
      end
      """)
    end
  end
end
