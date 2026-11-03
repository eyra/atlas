defmodule AtlasBFF.Example do
  @moduledoc false
  # A neutral contract for the generator's tests: none of Atlas's blocks.
  use AtlasBFF.Schema

  version "1.0.0"

  defmodel :link do
    field :label, :string, required: true
    field :to, :string, required: true
  end

  defblock :card do
    field :title, :string, required: true
    field :count, :integer
    field :links, {:list, :link}
  end

  defblock :note do
    field :text, :string, required: true
    field :done, :boolean
  end

  defmarkup :group do
    field :title, :string, required: true
  end

  defmarkup :tint do
    field :shade, :string
  end

  # Written in an order that is not the one they match in: a literal wins.
  defpage(:card, "/cards/:id")
  defpage(:new_card, "/cards/new")
  defpage(:home, "/")
end

defmodule AtlasBFF.Example.Server do
  @moduledoc false
  use AtlasBFF.Targets.Server, contract: AtlasBFF.Example
end

defmodule AtlasBFF.Example.Client do
  @moduledoc false
  use AtlasBFF.Targets.Client, contract: AtlasBFF.Example
end
