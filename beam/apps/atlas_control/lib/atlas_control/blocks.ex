defmodule AtlasControl.Blocks do
  @moduledoc """
  The builders of the view model Control sends: a macro per block, model and kind of
  markup in Control's contract (`AtlasContract.Blocks`, spec/contract), and
  `view_model/2`. Made from the contract when this module compiles; see
  `AtlasSpec.Targets.Server`. Callers `require AtlasControl.Blocks, as: Blocks`.
  """
  use AtlasSpec.Targets.Server, contract: AtlasContract.Blocks
end
