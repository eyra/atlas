defmodule AtlasBFFContract.Console do
  @moduledoc "Console presentation vocabulary. Operations are data, never dynamic calls."

  @contexts ~w(browse form confirm ask plan_planning plan_proposed plan_running plan_done step_form legend)
  @tokens ~w(Tab Shift+Tab Up Down Left Right Home End PageUp PageDown Enter Esc Backspace Space Ctrl+C Ctrl+S)
  @local ~w(tab_next tab_previous move_next move_previous select_first select_last page_next page_previous part_next part_previous back refresh quit legend_open legend_close focus_next focus_previous submit_form cancel_form form_enter input_up input_down input_left input_right input_home input_end input_backspace ask_send ask_cancel plan_cancel plan_run plan_toggle plan_edit plan_previous plan_next plan_stop plan_close step_save step_cancel)

  def contexts, do: @contexts
  def named_keys, do: @tokens
  def operations, do: @local ++ ~w(open open_url agent_ask)

  def key?(key) when is_binary(key),
    do:
      key in @tokens or
        (String.valid?(key) and String.length(key) == 1 and String.printable?(key))

  def key?(_), do: false

  def operation?(%{"name" => name} = op) do
    {required, optional} =
      cond do
        name == "open" -> {["name", "to"], []}
        name == "open_url" -> {["name", "url"], []}
        name == "agent_ask" -> {["name"], ["intent"]}
        name in @local -> {["name"], []}
        true -> {[], []}
      end

    required != [] and Map.keys(op) -- (required ++ optional) == [] and
      Enum.all?(required, &text?(op[&1], 2_048)) and
      Enum.all?(optional, &(not Map.has_key?(op, &1) or text?(op[&1], 128)))
  end

  def operation?(_), do: false

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and String.valid?(value) and
        String.trim(value) != ""
end
