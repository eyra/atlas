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

    assert %{
             name: :card,
             call: :open,
             page: :card,
             params: [:id],
             replies: [%{name: :page, returns: :view_model}]
           } = hd(schema.endpoints)

    # Then the contract's own endpoints, after one per page.
    assert [%{name: :save_card, call: :submit, page: nil, takes: :values} = save] =
             Enum.drop(schema.endpoints, length(schema.pages))

    assert save.replies == [
             %{name: :saved, returns: :view_model},
             %{name: :refused, returns: :view_model}
           ]
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

  test "an endpoint is matched within its call: the same path is a page and a submit" do
    for target <- [Server, Client] do
      assert target.endpoint(:submit, "/cards/C-1") == {:ok, :save_card, %{id: "C-1"}}
      assert target.endpoint(:open, "/cards/C-1") == {:ok, :card, %{id: "C-1"}}
      assert target.endpoint(:submit, "/cards/new") == {:ok, :save_card, %{id: "new"}}
      assert target.endpoint(:submit, "/") == :error
      assert target.endpoint(:hello, "/cards/C-1") == :error
      assert length(target.endpoints()) == 4
    end
  end

  describe "an endpoint mistake fails at compile time" do
    test "no call, the pages' call, or no replies" do
      assert_raise CompileError, ~r/endpoint :a needs call: <a snake_case atom>/, fn ->
        spec(~s(defendpoint :a, "/a", replies: [ok: :view_model]))
      end

      assert_raise CompileError, ~r/call :open is for pages; use defpage/, fn ->
        spec(~s(defendpoint :a, "/a", call: :open, replies: [ok: :view_model]))
      end

      assert_raise CompileError, ~r/endpoint :a needs replies: \[reply: what it returns\]/, fn ->
        spec(~s(defendpoint :a, "/a", call: :submit))
      end

      assert_raise CompileError, ~r/the options are call:, takes: and replies:/, fn ->
        spec(~s(defendpoint :a, "/a", call: :submit, replies: [ok: :x], method: :post))
      end
    end

    test "two endpoints of one call for the same paths, or one name twice" do
      assert_raise CompileError, ~r/endpoints :a and :b match the same paths/, fn ->
        spec(~s(defendpoint :a, "/x/:id", call: :submit, replies: [ok: :x]
                defendpoint :b, "/x/:key", call: :submit, replies: [ok: :x]))
      end

      assert_raise CompileError, ~r/endpoint :a \(submit\) is defined twice/, fn ->
        spec(~s(defendpoint :a, "/x", call: :submit, replies: [ok: :x]
                defendpoint :a, "/y", call: :submit, replies: [ok: :x]))
      end
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
