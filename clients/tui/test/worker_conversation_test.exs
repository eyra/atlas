defmodule AtlasTui.WorkerConversationTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Blocks, Console, Model, Protocol, View}
  alias AtlasTui.ConsoleProjectionFixture, as: Fixture
  alias AtlasBFFContract.Workers.Protocol, as: Wire

  @params %{machine: "box", worker: "W-1", turn: "R-1", attempt: "attempt-1"}
  @execution %{
    "worker" => %{"environment" => "test", "machine" => "box", "worker" => "W-1"},
    "turn" => "R-1",
    "attempt" => "attempt-1"
  }

  defp form_page(key \\ "original-key", params \\ @params) do
    %{
      "op" => "page",
      "path" => Blocks.path(:worker_guidance, params),
      "reason" => "open",
      "title" => "Guidance",
      "back" => Blocks.path(:worker, params),
      "blocks" => [
        %{
          "id" => "guidance-form",
          "type" => "form",
          "props" => %{
            "title" => "Queue literal guidance",
            "submit_label" => "Queue for this exact turn",
            "submit_to" => %{
              "endpoint" => "queue_worker_guidance",
              "params" => Map.new(params, fn {k, v} -> {Atom.to_string(k), v} end)
            },
            "cancel_to" => Blocks.path(:worker, params),
            "inputs" => [
              %{
                "name" => "client_key",
                "label" => "Key",
                "kind" => "readonly",
                "value" => key,
                "required" => true
              },
              %{
                "name" => "body",
                "label" => "Literal guidance",
                "kind" => "multiline",
                "value" => "",
                "required" => true
              },
              %{
                "name" => "cause",
                "label" => "Why",
                "kind" => "text",
                "value" => "Operator request",
                "required" => true
              }
            ]
          }
        }
      ]
    }
  end

  defp initial do
    Fixture.model(%{
      "op" => "page",
      "path" => "/workers",
      "title" => "Workers",
      "blocks" => [%{"id" => "workers", "type" => "list", "props" => %{"rows" => []}}]
    })
  end

  defp editor do
    {model, _effects} = Fixture.receive(initial(), form_page())
    model
  end

  defp request(effects, op),
    do:
      Enum.find_value(effects, fn
        {:send, %{"op" => ^op} = request} -> request
        _ -> nil
      end)

  defp reply(request, fields) do
    {:ok, operation, _} = Wire.decode_request(request)
    Wire.reply(operation, :result, Map.put(fields, "id", request["id"]))
  end

  defp reconnect(model, page) do
    model = Console.disconnected(model)

    {model, []} =
      Console.receive(model, %{
        "op" => "welcome",
        "surface" => "console",
        "env" => "test",
        "spec" => Protocol.version()
      })

    {model, _} = Console.receive(model, %{"op" => "page"})

    {model, _} =
      Console.receive(model, %{
        "op" => "boot",
        "title" => "Atlas",
        "env" => "test",
        "spec" => Protocol.version(),
        "revision" => "restored",
        "initial_to" => "/workers",
        "active_tab" => "workers",
        "tabs" => [%{"id" => "workers", "label" => "Workers", "to" => "/workers"}]
      })

    Fixture.receive(model, page)
  end

  defp interaction(submit) do
    Map.merge(submit["guidance"], %{
      "key" => "interaction-1",
      "environment" => "test",
      "actor" => "H-1",
      "body_digest" => "opaque",
      "worker" => "W-1",
      "turn" => "R-1",
      "attempt" => "attempt-1",
      "mode" => "queued_guidance",
      "execution" => "execution-1",
      "recorded_at" => "2026-11-06T10:00:00Z",
      "recorded_position" => 1,
      "projection" => %{"proven" => "recorded", "uncertain" => false, "closures" => []},
      "receipt_count" => 0
    })
  end

  test "partial literal drafts and original submission key survive handshake and resize" do
    text = "/stop is literal\n  界é unfinished"
    {model, []} = Model.key(editor(), {:char, text})
    assert model.values["body"] == text
    {restored, effects} = reconnect(model, form_page("new-server-default"))
    assert restored.values == model.values
    assert restored.values["client_key"] == "original-key"
    refute request(effects, "worker_submit")
    refute request(effects, "worker_query")

    Enum.reduce([38, 140, 38], restored, fn width, current ->
      {_rows, resized} = View.frame(current, width, 40, 5)
      assert resized.values == model.values
      assert resized.conversation.guidance.values == model.values
      resized
    end)
  end

  test "lost acceptance is queried on reconnect and never resubmitted or retargeted" do
    {model, []} = Model.key(editor(), {:char, "literal guidance"})
    {model, effects} = Model.key(model, :ctrl_s)
    submit = request(effects, "worker_submit")
    assert submit["execution"] == @execution
    {model, []} = Model.key(model, {:char, "must not mutate in-flight payload"})
    assert model.values == submit["guidance"]
    {model, effects} = reconnect(model, form_page("replacement-default"))
    query = request(effects, "worker_query")
    assert query["execution"] == submit["execution"]
    assert query["client_key"] == submit["guidance"]["client_key"]
    refute request(effects, "worker_submit")

    {model, effects} =
      Console.receive(
        model,
        reply(query, %{"found" => true, "interaction" => interaction(submit)})
      )

    assert model.conversation.guidance.status == :accepted
    assert request(effects, "open")["to"] == Blocks.path(:worker, @params)
    refute request(effects, "worker_submit")
  end

  test "live lost reply uses declared submit to query before an identical explicit retry" do
    {model, []} = Model.key(editor(), {:char, "one payload"})
    {model, effects} = Model.key(model, :ctrl_s)
    original = request(effects, "worker_submit")
    {model, effects} = Model.key(model, :ctrl_s)
    query = request(effects, "worker_query")
    refute request(effects, "worker_submit")
    {model, effects} = Console.receive(model, reply(query, %{"found" => false}))
    refute request(effects, "worker_submit")
    {_, effects} = Model.key(model, :ctrl_s)
    retry = request(effects, "worker_submit")
    assert retry["execution"] == original["execution"]
    assert retry["guidance"] == original["guidance"]
  end

  test "unexpected successor page cannot replace the displayed exact-turn draft" do
    {model, []} = Model.key(editor(), {:char, "old-turn draft"})
    {model, _} = Console.navigate(model, model.path)
    successor = %{@params | turn: "R-2", attempt: "attempt-2"}
    {model, effects} = Fixture.receive(model, form_page("successor-key", successor))
    assert model.path == Blocks.path(:worker_guidance, @params)
    assert model.values["body"] == "old-turn draft"
    assert model.conversation.execution == @execution
    assert model.notice.text =~ "target changed"
    refute request(effects, "worker_submit")
  end

  test "unavailable exact turn retains readable draft without manufacturing a send form" do
    {model, []} = Model.key(editor(), {:char, "retained 界é draft"})

    page = %{
      form_page()
      | "blocks" => [
          %{
            "id" => "unavailable",
            "type" => "item",
            "props" => %{
              "title" => "Worker unavailable",
              "fields" => [%{"label" => "Reason", "value" => "stale_target"}]
            }
          }
        ]
    }

    {model, effects} = reconnect(model, page)
    assert Model.form(model) == nil
    assert View.plain(View.render(model, 100, 50, 5)) =~ "retained 界é draft"
    assert View.plain(View.render(model, 100, 50, 5)) =~ "stale_target"
    refute request(effects, "worker_submit")
    {_, effects} = Model.operation(model, "submit_form")
    refute request(effects, "worker_submit")
  end

  defp history_model do
    path = Blocks.path(:worker, @params)

    page =
      Fixture.project(%{
        "op" => "page",
        "path" => path,
        "title" => "Worker",
        "blocks" => [
          %{
            "id" => "guidance-history",
            "type" => "item",
            "props" => %{"title" => "Durable guidance", "fields" => []}
          },
          %{
            "id" => "guidance-details",
            "type" => "item",
            "props" => %{
              "title" => "Fallback details",
              "fields" => [%{"label" => "Body", "value" => "superseded fallback body"}]
            }
          }
        ]
      })

    operations = [
      {"history-next", "h",
       %{"name" => "worker_history", "execution" => @execution, "cursor" => "declared-first"}},
      {"history-receipts", "e",
       %{
         "name" => "worker_receipts",
         "execution" => @execution,
         "interaction_source" => "selected_history"
       }}
    ]

    actions =
      Enum.map(operations, fn {id, key, op} ->
        %{
          "id" => id,
          "type" => "console_action",
          "props" => %{
            "label" => id,
            "keys" => [key],
            "operation" => op,
            "available" => true,
            "scope" => %{
              "page" => path,
              "context" => "browse",
              "on" => "guidance-history",
              "revision" => page["actions_revision"]
            }
          }
        }
      end)

    page =
      page
      |> Map.update!("blocks", &(&1 ++ actions))
      |> Map.update!(
        "markup",
        &(&1 ++
            [
              %{
                "kind" => "legend",
                "start" => "history-next",
                "end" => "history-receipts",
                "props" => %{"title" => "History", "context" => "browse"}
              }
            ])
      )

    {model, effects} = Console.receive(initial(), page)
    {model, request(effects, "worker_history")}
  end

  defp history_record(key, position) do
    interaction(%{
      "guidance" => %{"client_key" => key, "body" => "Literal " <> key, "cause" => "operator"}
    })
    |> Map.merge(%{"key" => key, "recorded_position" => position})
  end

  test "declared history action follows correlated frontier and receipts bind later loaded selection" do
    {model, first} = history_model()
    assert model.console.action_error == nil
    assert AtlasTui.Interactions.capture(model, {:char, "e"}) == nil
    assert View.plain(View.render(model, 120, 80, 5)) =~ "superseded fallback body"

    {model, []} =
      Console.receive(
        model,
        reply(first, %{
          "interactions" => [history_record("I-1", 1)],
          "cursor" => "accepted-one",
          "more" => true
        })
      )

    rendered = View.plain(View.render(model, 120, 80, 5))
    assert rendered =~ "Literal I-1"
    refute rendered =~ "superseded fallback body"

    {model, effects} = Model.key(model, {:char, "h"})
    second = request(effects, "worker_history")
    assert second["cursor"] == "accepted-one"
    assert AtlasTui.Interactions.capture(model, {:char, "h"}) == nil

    {model, []} =
      Console.receive(
        model,
        reply(second, %{
          "interactions" => [history_record("I-2", 2)],
          "cursor" => "accepted-two",
          "more" => false
        })
      )

    assert AtlasTui.Interactions.capture(model, {:char, "h"}) == nil
    model = %{model | selected: 1}
    {_, effects} = Model.key(model, {:char, "e"})
    assert request(effects, "worker_receipts")["interaction"] == "I-2"
    assert request(effects, "worker_receipts")["execution"] == @execution
    # Loaded rows do not authorize movement disabled by the original Server declaration.
    assert AtlasTui.Interactions.capture(model, :down) == nil

    {refreshed, _reads} =
      Fixture.receive(model, %{
        "op" => "page",
        "path" => model.path,
        "reason" => "refresh",
        "title" => "Worker",
        "blocks" => [
          %{
            "id" => "guidance-history",
            "type" => "list",
            "props" => %{
              "rows" => [%{"id" => "I-1", "label" => "Literal I-1", "to" => model.path}]
            }
          }
        ]
      })

    assert Enum.at(Model.rows(refreshed), refreshed.selected).id == "I-2"
  end

  test "late history replies cannot replace a different displayed page" do
    {model, pending} = history_model()
    {model, _} = Console.navigate(model, "/workers")

    {model, _} =
      Fixture.receive(model, %{
        "op" => "page",
        "path" => "/workers",
        "title" => "Workers",
        "blocks" => [%{"id" => "workers", "type" => "list", "props" => %{"rows" => []}}]
      })

    {updated, []} =
      Console.receive(
        model,
        reply(pending, %{
          "interactions" => [history_record("I-1", 1)],
          "cursor" => "accepted-one",
          "more" => false
        })
      )

    assert updated.path == "/workers"
    assert updated.blocks == model.blocks
    assert updated.ids == ["workers"]
  end
end
