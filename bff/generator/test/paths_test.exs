defmodule AtlasBFF.PathsTest do
  use ExUnit.Case, async: true

  alias AtlasBFF.Example.{Client, Server}
  alias AtlasBFF.Paths

  @pages AtlasBFF.Example.__schema__().pages

  test "a contract lists its pages, and each page is the endpoint that fetches it" do
    schema = AtlasBFF.Example.__schema__()

    assert [
             %{name: :card, path: "/cards/:id", params: [:id]},
             %{name: :new_card, path: "/cards/new", params: []},
             %{name: :home, path: "/", params: []}
           ] = schema.pages

    assert %{name: :card, call: :open, page: :card, params: [:id], returns: :view_model} =
             hd(schema.endpoints)

    assert length(schema.endpoints) == length(schema.pages)
  end

  test "a path is matched to its page, a literal before a parameter, whatever the order" do
    assert Paths.match(@pages, "/") == {:ok, :home, %{}}
    assert Paths.match(@pages, "/cards/new") == {:ok, :new_card, %{}}
    assert Paths.match(@pages, "/cards/C-1") == {:ok, :card, %{id: "C-1"}}
    # A value is decoded; an empty one, or a path no page has, is no page.
    assert Paths.match(@pages, "/cards/C%201") == {:ok, :card, %{id: "C 1"}}
    assert Paths.match(@pages, "/cards/") == :error
    assert Paths.match(@pages, "/cards/C-1/more") == :error
    assert Paths.match(@pages, "/nothing") == :error
    assert Paths.match(@pages, nil) == :error
  end

  test "a page's path is built from its parameters, encoded; a missing one raises" do
    assert Paths.build(@pages, :card, id: "C 1/2") == "/cards/C%201%2F2"

    assert Paths.match(@pages, Paths.build(@pages, :card, %{"id" => "C 1/2"})) ==
             {:ok, :card, %{id: "C 1/2"}}

    assert Paths.build(@pages, :home, %{}) == "/"
    assert_raise ArgumentError, ~r/needs :id/, fn -> Paths.build(@pages, :card, %{}) end
    assert_raise ArgumentError, ~r/no page :gone/, fn -> Paths.build(@pages, :gone, %{}) end
  end

  test "the server and client targets have the contract's pages" do
    for target <- [Server, Client] do
      assert target.pages() == @pages
      assert target.match("/cards/new") == {:ok, :new_card, %{}}
      assert target.path(:card, id: "C-1") == "/cards/C-1"
    end
  end

  describe "a page mistake fails at compile time" do
    test "a path that is not a path" do
      assert_raise CompileError, ~r/page :a: the path "a" does not start with \//, fn ->
        spec(~s(defpage :a, "a"))
      end

      assert_raise CompileError, ~r/"x y" in \/x y is neither a literal nor :name/, fn ->
        spec(~s(defpage :a, "/x y"))
      end

      assert_raise CompileError, ~r/parameter :id is in \/a\/:id\/:id twice/, fn ->
        spec(~s(defpage :a, "/a/:id/:id"))
      end
    end

    test "two pages for the same paths, or one name twice" do
      assert_raise CompileError, ~r/pages :a and :b match the same paths/, fn ->
        spec(~s(defpage :a, "/x/:id"\ndefpage :b, "/x/:key"))
      end

      assert_raise CompileError, ~r/page :a is defined twice/, fn ->
        spec(~s(defpage :a, "/x"\ndefpage :a, "/y"))
      end
    end

    test "a page inside a block" do
      assert_raise CompileError, ~r/page :p inside :a/, fn ->
        spec(~s(defblock :a do\ndefpage :p, "/p"\nend))
      end
    end
  end

  defp spec(body) do
    name = "AtlasBFF.PathsTest.Spec#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use AtlasBFF.Schema
      version "0.0.1"
      #{body}
    end
    """)
  end
end
