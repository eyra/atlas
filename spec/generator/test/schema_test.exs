defmodule AtlasSpec.SchemaTest do
  use ExUnit.Case, async: true

  test "a contract compiles to plain data, in the order written" do
    schema = AtlasSpec.Example.__schema__()
    assert %{version: "1.0.0", file: file} = schema
    assert String.ends_with?(file, "test/support/example.ex")
    assert Enum.map(schema.models, & &1.name) == [:link]
    assert Enum.map(schema.blocks, & &1.name) == [:card, :note]
    assert Enum.map(schema.markup, & &1.name) == [:group, :tint]

    assert [
             %{name: :title, type: :string, required: true},
             %{name: :count},
             %{name: :links, type: {:list, :link}}
           ] =
             hd(schema.blocks).fields
  end

  describe "a mistake fails at compile time" do
    test "a block holding a block" do
      assert_raise CompileError, ~r/holds block :a; blocks have no children/, fn ->
        spec("defblock :a do field :x, :string end\ndefblock :b do field :inner, :a end")
      end
    end

    test "a field that holds markup" do
      assert_raise CompileError, ~r/b.x holds markup :a; markup covers blocks/, fn ->
        spec("defmarkup :a do field :t, :string end\ndefblock :b do field :x, :a end")
      end
    end

    test "markup named like a block" do
      assert_raise CompileError, ~r/:a is defined twice/, fn ->
        spec("defblock :a do field :x, :string end\ndefmarkup :a do field :t, :string end")
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

    test "a name that is not snake_case" do
      assert_raise CompileError, ~r/:Card is not a snake_case atom/, fn ->
        spec("defblock :Card do field :x, :string end")
      end
    end

    test "an option other than required" do
      assert_raise CompileError, ~r/the only option is required/, fn ->
        spec("defblock :a do field :x, :string, requird: true end")
      end
    end

    test "a missing version" do
      assert_raise CompileError, ~r/needs a version/, fn ->
        Code.compile_string("defmodule NoVersion do use AtlasSpec.Schema end")
      end
    end
  end

  defp spec(body) do
    Code.compile_string("""
    defmodule Spec#{System.unique_integer([:positive])} do
      use AtlasSpec.Schema
      version "0"
      #{body}
    end
    """)
  end
end
