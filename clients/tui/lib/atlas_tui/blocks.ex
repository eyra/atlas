defmodule AtlasTui.Blocks do
  @moduledoc """
  The view model Control sends, decoded: a struct per block, model and kind of markup in
  Control's contract (`AtlasContract.Blocks`, spec/contract), `decode/1` and
  `view_model/1`. Made from the contract when this module compiles; see
  `AtlasSpec.Targets.Client`.
  """
  use AtlasSpec.Targets.Client, contract: AtlasContract.Blocks
end
