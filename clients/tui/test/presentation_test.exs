defmodule AtlasTui.PresentationTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Palette, View}

  defp model do
    model = %{
      Model.new("test")
      | connected: true,
        console: %{
          Console.new()
          | phase: :ready,
            stale: false,
            shell: %{
              "title" => "Atlas Console",
              "revision" => "fixture",
              "tabs" => [
                %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"}
              ]
            }
        }
    }

    page = %{
      "op" => "page",
      "path" => "/k/widget",
      "title" => "Widgets",
      "blocks" => [
        %{
          "id" => "list",
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [
              %{
                "id" => "W-01",
                "to" => "/k/widget/W-01",
                "label" => "A title that remains readable at narrow widths",
                "detail" => "Descriptive metadata without workflow inference"
              },
              %{
                "id" => "W-02",
                "to" => "/k/widget/W-02",
                "label" => "Second title",
                "detail" => "Another detail"
              }
            ]
          }
        }
      ]
    }

    actual =
      __DIR__ |> Path.join("fixtures/console-actions.json") |> File.read!() |> JSON.decode!()

    page = actual |> Map.merge(page) |> Map.put("blocks", page["blocks"] ++ actual["blocks"])
    {model, []} = Console.receive(model, page)
    assert model.console.action_error == nil
    model
  end

  test "both themes keep all text roles above 4.5:1 contrast on their own surface" do
    for theme <- [:light, :dark],
        role <- [:plain, :bold, :dim, :selected, :cursor, :prod, :ok, :pending, :error, :info] do
      {fg, bg} = Palette.colors(role, theme)
      [low, high] = Enum.sort([luminance(fg), luminance(bg)])
      assert (high + 0.05) / (low + 0.05) >= 4.5, "#{theme} #{role}"
    end
  end

  test "theme selection is deterministic and unknown settings retain dark default" do
    assert Palette.theme("light") == :light
    assert Palette.theme("dark") == :dark
    assert Palette.theme(nil) == :dark
    assert Palette.theme("other") == :dark
  end

  test "actual rendering preserves labels, selection marker and status in either palette" do
    model = model()

    for width <- [20, 38, 100] do
      rows = View.render(model, width, 40, 5)
      text = View.plain(rows)
      assert text =~ "Widgets · 2"
      assert text =~ "› W-01"
      assert text =~ "Second"
      assert text =~ "title"
      assert text =~ "connected"
      for row <- rows, do: assert(Enum.sum(Enum.map(row, &String.length(elem(&1, 1)))) <= width)
      assert Enum.any?(rows, &Enum.any?(&1, fn {style, _} -> style == :border end))

      for theme <- [:light, :dark] do
        ansi = rows |> View.to_ansi(theme) |> IO.iodata_to_binary()
        assert String.replace(ansi, ~r/\e\[[0-9;]*[mKHJ]/, "") |> String.contains?("› W-01")
        assert ansi =~ "48;2;"
      end
    end

    assert model.values == %{}
  end

  test "empty content remains visible and disconnected/error status keeps literal meaning" do
    model = model()

    model = %{
      model
      | blocks: [%AtlasTui.Blocks.List{title: "Widgets", rows: [], empty: "No widgets yet."}]
    }

    assert model |> View.render(60, 20, 5) |> View.plain() =~ "No widgets yet."
    model = %{model | connected: false, notice: %{tone: "error", text: "Cannot save"}}
    text = model |> View.render(60, 20, 5) |> View.plain()
    assert text =~ "not connected"
    assert text =~ "✗ Cannot save"
  end

  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn value ->
      value = value / 255
      if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
    end)
    |> Enum.zip([0.2126, 0.7152, 0.0722])
    |> Enum.sum_by(fn {value, weight} -> value * weight end)
  end
end
