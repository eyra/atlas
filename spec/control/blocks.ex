defmodule AtlasControl.Spec.Blocks do
  @moduledoc """
  Control's block catalogue: what Control sends and every client renders.

  Blocks know nothing of what they show. Control fills them from rela's description and
  facts; a client renders them without knowing any kind of fact.

  This file is the single source of the spec (the DSL is `AtlasControl.Spec`); it lives in
  spec/control and compiles into Control. `mix atlas.gen` turns it into server code
  (`AtlasControl.Blocks`), client code for the TUI (`AtlasTui.Blocks`) and
  `spec/control/blocks.json` for other clients.
  """
  use AtlasControl.Spec

  version "0.1.0"

  # Something the user can do from a block: open `to`. `key` is the key a keyboard
  # client binds it to; other clients may show it as a button.
  defmodel :action do
    field :label, :string, required: true
    field :key, :string, required: true
    field :to, :string, required: true
  end

  # One line of a list; opening it opens `to`.
  defmodel :row do
    field :label, :string, required: true
    field :detail, :string
    field :to, :string, required: true
  end

  # A labelled value.
  defmodel :pair do
    field :label, :string, required: true
    field :value, :string
  end

  # A value an input may take, and how to show it.
  defmodel :choice do
    field :value, :string, required: true
    field :label, :string, required: true
  end

  # One input of a form. `kind` is text, choice, boolean or readonly (shown, never
  # changed, such as an id); values travel as text.
  defmodel :input do
    field :name, :string, required: true
    field :label, :string, required: true
    field :kind, :string, required: true
    field :value, :string
    field :required, :boolean
    field :hint, :string
    field :choices, {:list, :choice}
  end

  defblock :list do
    field :title, :string, required: true
    field :rows, {:list, :row}, required: true
    field :empty, :string
    field :actions, {:list, :action}
  end

  defblock :item do
    field :title, :string, required: true
    field :fields, {:list, :pair}, required: true
    field :actions, {:list, :action}
  end

  # Submitting sends the inputs' values to `submit_to`.
  defblock :form do
    field :title, :string, required: true
    field :inputs, {:list, :input}, required: true
    field :submit_label, :string, required: true
    field :submit_to, :string, required: true
    field :cancel_to, :string
    field :errors, {:list, :string}
  end

  # A question before something that cannot be undone. Without `confirm_to` it only
  # explains why the thing cannot be done.
  defblock :confirm do
    field :title, :string, required: true
    field :text, :string, required: true
    field :confirm_label, :string
    field :confirm_to, :string
    field :cancel_to, :string, required: true
  end
end
