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

  test "supplied highlight tones remain labeled without color and do not infer workflow state" do
    for {tone, label, style} <- [
          {"ok", "OK", :ok},
          {"pending", "Pending", :pending},
          {"error", "Error", :error},
          {"info", "Info", :info},
          {"custom", "custom", :dim}
        ] do
      m = model()

      m = %{
        m
        | markup: [
            %{
              "kind" => "highlight",
              "start" => "list",
              "end" => "list",
              "value" => %AtlasTui.Blocks.Highlight{tone: tone}
            }
          ]
      }

      rows = View.render(m, 60, 40, 5)
      assert View.plain(rows) =~ "[#{label}]"
      assert Enum.any?(rows, &Enum.member?(&1, {style, "[#{label}]"}))
      assert View.plain(rows) =~ "W-01"
      refute model() |> View.render(60, 40, 5) |> View.plain() =~ "[#{label}]"
    end
  end

  test "list headings retain their count across the minimum framing width" do
    for width <- 1..20 do
      rows = View.render(model(), width, 240, 5)
      heading = for row <- rows, {:bold, text} <- row, into: "", do: text
      assert String.replace(heading, ~r/\s/u, "") =~ "Widgets·2"
      for row <- rows, do: assert(Enum.sum(Enum.map(row, &String.length(elem(&1, 1)))) <= width)
    end
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

  defp narrow_content(width, framed, label, detail) do
    m = model()
    row = %AtlasTui.Blocks.Row{id: "ID12345", label: label, detail: detail, to: "/k/widget/one"}

    markup =
      if framed,
        do: [
          %{
            "kind" => "part",
            "start" => "items",
            "end" => "items",
            "value" => %AtlasTui.Blocks.Part{title: "Part", role: "related"}
          }
        ],
        else: []

    m = %{
      m
      | blocks: [%AtlasTui.Blocks.List{title: "Items", rows: [row]}],
        ids: ["items"],
        markup: markup,
        console: %{m.console | shell: nil},
        updated: nil
    }

    rows = View.render(m, width, 160, 5)
    title = for row <- rows, {style, text} <- row, style == :selected, into: "", do: text

    metadata =
      for row <- rows,
          {style, text} <- row,
          style == :dim and String.starts_with?(text, "   "),
          into: "",
          do: text

    {String.replace(title, ~r/[\s›A-Z0-9…]/u, ""), String.replace(metadata, ~r/\s/u, "")}
  end

  test "narrow bare and framed lists preserve entire title and metadata in reading order" do
    label = "abcdefghijklmnopqrstuvwxyz"
    detail = "lowercase metadata stays complete"

    for {width, framed} <- [
          {19, false},
          {20, false},
          {38, true},
          {20, true},
          {12, false},
          {8, false},
          {5, false}
        ] do
      {visible_title, visible_detail} = narrow_content(width, framed, label, detail)
      assert visible_title == label, "#{width} columns framed=#{framed}"
      assert visible_detail =~ String.replace(detail, " ", "")
    end
  end

  test "narrow wrapping preserves multibyte and combining graphemes" do
    label = "éàñøüéíçáößőűæœ"
    detail = "éàñøü éíçáöß őűæœ"

    for {width, framed} <- [{19, false}, {20, true}, {8, false}] do
      {visible_title, visible_detail} = narrow_content(width, framed, label, detail)
      assert visible_title == label
      assert visible_detail =~ String.replace(detail, " ", "")
    end
  end
end
