defmodule AtlasContract.Blocks do
  @moduledoc """
  Control's block catalogue: what Control sends and every client renders.

  Blocks know nothing of what they show. Control fills them from rela's description and
  facts; a client renders them without knowing any kind of fact.

  The contract, the single source of the spec, written in the generator's DSL
  (`AtlasSpec.Schema`). Control and the TUI read it at compile time
  (`AtlasControl.Blocks`, `AtlasTui.Blocks`); `mix atlas.gen` here writes
  `spec/targets/json/blocks.json` for clients in other languages.
  """
  use AtlasSpec.Schema

  version "0.6.0"

  # Something the user can do from a block: open `to`. `key` is the key a keyboard
  # client binds it to; other clients may show it as a button.
  defmodel :action do
    field :label, :string, required: true
    field :key, :string, required: true
    field :to, :string, required: true
  end

  # A web address the user can open outside the client, in a browser: `url`. `key` is
  # the key a keyboard client binds it to. A client opens only http and https addresses.
  defmodel :link do
    field :label, :string, required: true
    field :key, :string, required: true
    field :url, :string, required: true
  end

  # One line of a list; opening it opens `to`. Its links are for the row while it is
  # selected.
  # `id` is the item's id, which a client shows first, in a column of its own.
  defmodel :row do
    field :id, :string
    field :label, :string, required: true
    field :detail, :string
    field :to, :string, required: true
    field :links, {:list, :link}
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

  # One input of a form. `kind` is text (one line, wrapped when long), multiline (lines
  # and sections; enter starts a new line), choice, boolean or readonly (shown, never
  # changed, such as an id); values travel as text. A client that does not know a kind
  # edits it as text.
  defmodel :input do
    field :name, :string, required: true
    field :label, :string, required: true
    field :kind, :string, required: true
    field :value, :string
    field :required, :boolean
    field :hint, :string
    field :choices, {:list, :choice}
  end

  # A list inside a section may leave its title to the section.
  defblock :list do
    field :title, :string
    field :rows, {:list, :row}, required: true
    field :empty, :string
    field :actions, {:list, :action}
  end

  defblock :item do
    field :title, :string, required: true
    field :fields, {:list, :pair}, required: true
    field :actions, {:list, :action}
    field :links, {:list, :link}
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

  # One step of an agent's plan: the form it fills (`label`, its title; `inputs`, its
  # inputs with the values the step gives them), why, and how far it got. `state` is
  # proposed, blocked (it cannot run; `detail` says why), dropped, running, stored,
  # refused or not_run. `detail` is what happened: the id it stored, or why not.
  defmodel :step do
    field :n, :integer, required: true
    field :label, :string, required: true
    field :state, :string, required: true
    field :why, :string
    field :detail, :string
    field :inputs, {:list, :input}
  end

  # What an agent proposes for a request, and then does: its steps, in order. `state` is
  # planning, proposed, running, done, stopped, failed or cancelled. A person keeps,
  # edits or drops each proposed step before any of it runs. `before` says what became
  # of the previous plan for the same request, when this one follows a refusal.
  defblock :plan do
    field :title, :string, required: true
    field :request, :string, required: true
    field :state, :string, required: true
    field :summary, :string
    field :by, :string
    field :before, :string
    field :steps, {:list, :step}, required: true
  end

  # Markup: kinds that cover a stretch of a view model's blocks. All markup nests, of
  # every kind; see AtlasSpec.Markup in the generator.

  # A titled part of the view; a client may let the user fold a collapsible one.
  defmarkup :section do
    field :title, :string, required: true
    field :collapsible, :boolean
  end

  # A line drawn around the blocks, with an optional title in it.
  defmarkup :border do
    field :title, :string
  end

  # The blocks side by side, `count` to a row; a client too narrow stacks them.
  defmarkup :columns do
    field :count, :integer, required: true
  end

  # The blocks marked, in a tone: info, ok, error or pending.
  defmarkup :highlight do
    field :tone, :string, required: true
  end
end
