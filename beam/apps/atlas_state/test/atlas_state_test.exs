defmodule AtlasStateTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasState.FakeRela

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    rela = FakeRela.start()
    start_supervised!({AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    %{rela: rela, dir: dir}
  end

  defp fact(op, key, values \\ %{}, opts \\ []) do
    envelope = Envelope.new("fact", Keyword.get(opts, :kind, "widget"), Keyword.take(opts, [:id]))
    content = %{"op" => op, "key" => key, "values" => values, "version" => opts[:version]}
    send_and_wait(envelope, content)
  end

  defp read(kind, content \\ %{}) do
    {"answer", answer, _} = send_and_wait(Envelope.new("read", kind), content)
    answer
  end

  defp send_and_wait(envelope, content) do
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id} = reply, answer}, 1_000
    {reply.class, answer, reply.position}
  end

  test "a fact is stored once and answered with stored and a position", %{rela: rela} do
    assert {"stored", %{"op" => "create", "key" => "W-1"}, 1} =
             fact("create", "W-1", %{"title" => "One", "shade" => "dark"})

    assert {"stored", _, 2} = fact("create", "W-2", %{"title" => "Two"})
    assert %{"W-1" => {%{"title" => "One", "shade" => "dark"}, _}} = FakeRela.facts(rela)
  end

  test "a resent id is stored once and gets the same answer again", %{rela: rela} do
    first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    FakeRela.poke(rela, "W-1", %{"title" => "Changed by someone else"})
    assert ^first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    assert {"stored", _, 1} = first
    assert {"stored", _, 2} = fact("change", "W-1", %{"title" => "Again"})
  end

  test "the answers survive a restart of State", %{rela: rela, dir: dir} do
    first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    stop_supervised!(AtlasState.Server)
    start_supervised!({AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir})
    assert ^first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    assert {"stored", _, 2} = fact("create", "W-2", %{"title" => "Two"})
  end

  test "a create that rela already has, after a lost answer, counts as stored", %{rela: rela} do
    {:ok, _} = FakeRela.create(rela, "widgets", "W-1", %{"title" => "One"})
    assert {"stored", _, 1} = fact("create", "W-1", %{"title" => "One"})

    assert {"refused", %{"reasons" => ["W-1 already exists"], "code" => "exists"}, nil} =
             fact("create", "W-1", %{"title" => "Other"})
  end

  test "values that do not fit the description are refused before rela sees them", %{rela: rela} do
    assert {"refused", %{"reasons" => reasons}, nil} =
             fact("create", "W-1", %{"shade" => "purple", "done" => "yes", "size" => 3})

    assert "shade must be one of light, dark" in reasons
    assert "done must be true or false" in reasons
    assert "size is not described" in reasons
    assert "title is required" in reasons

    assert {"refused", %{"reasons" => ["id must start with W-", "title is required"]}, nil} =
             fact("create", "X-1", %{})

    assert FakeRela.facts(rela) == %{}
  end

  test "an unknown kind is refused", _ do
    assert {"refused", %{"reasons" => ["rela does not describe \"gadget\""]}, nil} =
             fact("create", "G-1", %{"title" => "x"}, kind: "gadget")
  end

  test "a change on an old version is refused, unless it is already applied", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    %{"fact" => %{"version" => version}} = read("widget", %{"key" => "W-1"})
    assert {"stored", _, _} = fact("change", "W-1", %{"title" => "Two"}, version: version)
    assert {"stored", _, _} = fact("change", "W-1", %{"title" => "Two"}, version: version)

    assert {"refused", %{"reasons" => ["W-1 changed meanwhile; open it again"]}, nil} =
             fact("change", "W-1", %{"title" => "Three"}, version: version)

    assert {%{"title" => "Two"}, _} = FakeRela.facts(rela)["W-1"]
  end

  test "an empty optional value clears it; a required one cannot be cleared", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One", "shade" => "dark"})
    assert {"stored", _, _} = fact("change", "W-1", %{"shade" => ""})
    assert {%{"title" => "One"}, _} = FakeRela.facts(rela)["W-1"]

    assert {"refused", %{"reasons" => ["title is required"]}, nil} =
             fact("change", "W-1", %{"title" => ""})
  end

  test "a delete on an old version is refused", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    %{"fact" => %{"version" => version}} = read("widget", %{"key" => "W-1"})
    FakeRela.poke(rela, "W-1", %{"title" => "Changed by someone else"})

    assert {"refused", %{"reasons" => ["W-1 changed meanwhile; open it again"]}, nil} =
             fact("delete", "W-1", %{}, version: version)
  end

  test "a deleted id is reserved for a while, and State says so", _ do
    fact("create", "W-1", %{"title" => "One"})
    assert {"stored", %{"op" => "delete"}, _} = fact("delete", "W-1")
    assert {"stored", _, _} = fact("delete", "W-1")

    assert {"refused", %{"reasons" => [reason], "code" => "reserved"}, nil} =
             fact("create", "W-1", %{"title" => "One"})

    assert reason =~ "deleted a moment ago"
  end

  test "when rela is down, State still answers, and the id can be stored later", %{rela: rela} do
    FakeRela.down(rela)

    assert {"refused", %{"reasons" => ["rela is not reachable"]}, nil} =
             fact("create", "W-1", %{"title" => "One"}, id: "later")

    FakeRela.up(rela)
    assert {"stored", _, 1} = fact("create", "W-1", %{"title" => "One"}, id: "later")
  end

  test "reads: the description, all facts of a kind, one fact with what points at it",
       %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    fact("create", "W-2", %{"title" => "Two"})
    FakeRela.link(rela, "P-1", "W-1")

    assert %{"description" => %{"entities" => %{"widget" => _}}, "position" => 2} =
             read("_description")

    assert %{"facts" => [%{"key" => "W-1"}, %{"key" => "W-2"}]} = read("widget")

    assert %{
             "fact" => %{"key" => "W-1", "values" => %{"title" => "One"}, "version" => "v0"},
             "incoming" => %{"of_widget" => ["P-1"]}
           } = read("widget", %{"key" => "W-1"})

    assert %{"fact" => nil} = read("widget", %{"key" => "W-9"})
    assert %{"error" => "rela does not describe \"gadget\""} = read("gadget")
  end

  test "Atlas's additions are merged into the description State answers", %{rela: rela, dir: dir} do
    extra = Path.join(dir, "atlas.json")

    File.write!(
      extra,
      ~s({"_about": "x", "entities": {"widget": {"create": {"ask": ["title"]}}}})
    )

    stop_supervised!(AtlasState.Server)

    start_supervised!(
      {AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    %{"description" => description} = read("_description")
    assert description["entities"]["widget"]["create"] == %{"ask" => ["title"]}
    assert description["entities"]["widget"]["plural"] == "widgets"
    refute Map.has_key?(description, "_about")
  end

  test "a stored fact is a hint to listeners of its kind", _ do
    test = self()

    spawn_link(fn ->
      :ok = AtlasBus.attach("listener-#{System.unique_integer([:positive])}")
      :ok = AtlasBus.listen("widget")
      send(test, :listening)

      receive do
        {:atlas_bus, envelope, content} -> send(test, {:hint, envelope, content})
      end
    end)

    assert_receive :listening
    fact("create", "W-1", %{"title" => "One"})

    assert_receive {:hint, %Envelope{class: "stored", kind: "widget", position: 1},
                    %{"key" => "W-1"}}
  end
end
