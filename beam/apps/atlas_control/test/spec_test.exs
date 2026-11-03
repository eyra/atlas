defmodule AtlasControl.SpecTest do
  use ExUnit.Case, async: true

  require AtlasControl.Blocks, as: Blocks

  test "the generated server, client and JSON files are up to date with the spec" do
    for {path, content} <- AtlasControl.Spec.Gen.files() do
      assert File.read!(Path.join(AtlasControl.Spec.Gen.root(), path)) == content,
             "#{path} is out of date; run `mix atlas.gen`"
    end
  end

  test "builders check blocks before Control sends them" do
    assert %{"type" => "confirm", "props" => %{"title" => "T", "text" => "x", "cancel_to" => "/"}} =
             Blocks.confirm(title: "T", text: "x", cancel_to: "/", confirm_to: nil)

    # Props only known when Control runs are checked when the block is built.
    missing = [title: "T", text: "x"]

    assert_raise ArgumentError, ~r/confirm.cancel_to is required/, fn ->
      Blocks.confirm(missing)
    end

    assert_raise ArgumentError, ~r/confirm.cancel_to is required/, fn ->
      Blocks.confirm(title: "T", text: "x", cancel_to: nil)
    end

    assert_raise ArgumentError, ~r/must be "string"/, fn -> Blocks.pair(label: 1) end
    unknown = [label: "x", colour: "red"]
    assert_raise ArgumentError, ~r/no field/, fn -> Blocks.pair(unknown) end
  end

  test "a builder call with a missing or unknown prop fails at compile time" do
    assert_raise CompileError, ~r/confirm.cancel_to is required/, fn ->
      compile("Blocks.confirm(title: \"T\", text: \"x\")")
    end

    assert_raise CompileError, ~r/pair has no field\(s\) \["colour"\]/, fn ->
      compile("Blocks.pair(label: \"x\", colour: \"red\")")
    end

    assert_raise CompileError, ~r/row.to is required/, fn ->
      compile("Enum.map([1], &Blocks.row(label: &1))")
    end
  end

  describe "a spec mistake fails at compile time" do
    test "a block holding a block" do
      assert_raise CompileError, ~r/holds block :a; blocks have no children/, fn ->
        spec("""
        defblock :a do
          field :x, :string
        end
        defblock :b do
          field :inner, :a
        end
        """)
      end
    end

    test "an unknown type" do
      assert_raise CompileError, ~r/a.x has unknown type :strnig/, fn ->
        spec("defblock :a do field :x, {:list, :strnig} end")
      end
    end

    test "a name defined twice" do
      assert_raise CompileError, ~r/:a is defined twice/, fn ->
        spec("defmodel :a do field :x, :string end\ndefblock :a do field :y, :string end")
      end
    end

    test "a field defined twice" do
      assert_raise CompileError, ~r/:a has field :x twice/, fn ->
        spec("defblock :a do field :x, :string\nfield :x, :integer end")
      end
    end

    test "an option other than required" do
      assert_raise CompileError, ~r/the only option is required/, fn ->
        spec("defblock :a do field :x, :string, requird: true end")
      end
    end

    test "a missing version" do
      assert_raise CompileError, ~r/needs a version/, fn ->
        Code.compile_string("defmodule NoVersion do use AtlasControl.Spec end")
      end
    end
  end

  defp compile(call) do
    Code.compile_string("""
    defmodule Caller#{System.unique_integer([:positive])} do
      require AtlasControl.Blocks, as: Blocks
      def page, do: #{call}
    end
    """)
  end

  defp spec(body) do
    Code.compile_string("""
    defmodule Spec#{System.unique_integer([:positive])} do
      use AtlasControl.Spec
      version "0"
      #{body}
    end
    """)
  end
end
