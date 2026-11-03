defmodule AtlasSpec.Example do
  @moduledoc false
  # A neutral contract for the generator's tests: none of Atlas's blocks.
  use AtlasSpec.Schema

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
end

defmodule AtlasSpec.Example.Server do
  @moduledoc false
  use AtlasSpec.Targets.Server, contract: AtlasSpec.Example
end

defmodule AtlasSpec.Example.Client do
  @moduledoc false
  use AtlasSpec.Targets.Client, contract: AtlasSpec.Example
end
