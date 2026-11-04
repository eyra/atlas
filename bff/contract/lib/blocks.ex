defmodule AtlasBFFContract.Blocks do
  @moduledoc """
  Control's block catalogue: what Control sends and every client renders.

  Blocks know nothing of what they show. Control fills them from rela's description and
  facts; a client renders them without knowing any kind of fact.

  The contract, the single source of the spec, written in the generator's DSL
  (`AtlasBFF.Schema`). Control and the TUI read it at compile time
  (`AtlasControl.Blocks`, `AtlasTui.Blocks`); `mix atlas.gen` here writes
  `bff/targets/json/blocks.json` for clients in other languages.
  """
  use AtlasBFF.Schema

  # 0.7.0: markup names meaning; part (main, related) replaces border and columns.
  # 0.8.0: a pair may carry its origin: the fact that set it (since, by, cause).
  # 0.9.0: the pages Control serves (defpage); a path outside them is no page.
  # 0.10.0: the form submits Control takes (defendpoint, call :submit).
  # 0.11.0: a form's submit_to and a confirm's confirm_to name an endpoint and its params
  # (a `call`), no longer a path; the session's other calls; hello carries the version.
  # 0.12.0: a part of role todo (what its owner is to do); hello may say `as`, the fact an
  # agent client is.
  # 0.13.0: failure pages, in the test environment only (IS-Atlas-23): what can be made
  # to fail on a page, and a confirm that causes one.
  version "0.13.0"

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

  # The fact that set a value: since when (ISO 8601, UTC), by whom (a key), and why.
  defmodel :origin do
    field :since, :string
    field :by, :string
    field :cause, :string
  end

  # A labelled value, with the fact that set it when that is known.
  defmodel :pair do
    field :label, :string, required: true
    field :value, :string
    field :origin, :origin
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

  # A call of one of the contract's endpoints: its name and its parameters, by name. A
  # client sends it as it is: {"op": "submit", "endpoint": ..., "params": ..., "values": ...}.
  defmodel :call do
    field :endpoint, :string, required: true
    field :params, {:map, :string}
  end

  # Submitting sends the inputs' values to the endpoint `submit_to` names.
  defblock :form do
    field :title, :string, required: true
    field :inputs, {:list, :input}, required: true
    field :submit_label, :string, required: true
    field :submit_to, :call, required: true
    field :cancel_to, :string
    field :errors, {:list, :string}
  end

  # A question before something that cannot be undone. Without `confirm_to` it only
  # explains why the thing cannot be done.
  defblock :confirm do
    field :title, :string, required: true
    field :text, :string, required: true
    field :confirm_label, :string
    field :confirm_to, :call
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
  # planning, proposed, running, done, stopped, failed or cancelled. The user keeps,
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
  # every kind; see AtlasBFF.Markup in the generator. Markup says what a stretch means,
  # never how it looks: each client decides the layout (boxes, columns, tabs) itself.
  # Ask of every new kind: does it name a meaning, or an appearance?

  # A top-level division of a view, with its title. `role` says what it holds: `main`
  # (the item itself), `related` (what it links to) or `todo` (what its owner is to do,
  # shown to the owner only, first). Parts do not nest in parts; sections nest in parts.
  defmarkup :part do
    field :title, :string, required: true
    field :role, :string, required: true
  end

  # A titled stretch of the view; a client may let the user fold a collapsible one.
  defmarkup :section do
    field :title, :string, required: true
    field :collapsible, :boolean
  end

  # The blocks marked, in a tone: info, ok, error or pending.
  defmarkup :highlight do
    field :tone, :string, required: true
  end

  # The pages Control serves, and nothing else: a path outside them is no page. Each is
  # fetched and returns a view model. Generic: a kind is a parameter, never a name. The
  # paths are the ones facts already store (an agent request's page), so they stay.
  # `_` for a kind and `_parent` for a relation are values a client that knows only keys
  # passes; Control resolves them from rela's description.
  defpage :home, "/"
  defpage :kinds, "/_kinds"
  defpage :list, "/k/:kind"
  defpage :new, "/k/:kind/new"
  defpage :new_under, "/k/:kind/new/:relation/:parent"
  defpage :item, "/k/:kind/:key"
  defpage :edit, "/k/:kind/:key/edit"
  defpage :delete, "/k/:kind/:key/delete"
  defpage :links, "/k/:kind/:key/links/:relation"
  defpage :set, "/k/:kind/:key/set/:relation"
  defpage :remove, "/k/:kind/:key/remove/:relation"
  # Test only: what can be made to fail (the node, or a fact), and the confirm for one.
  defpage :faults, "/faults"
  defpage :fact_faults, "/k/:kind/:key/faults"
  defpage :fault, "/fault/:fault"
  defpage :fact_fault, "/k/:kind/:key/fault/:fault"

  # The form submits Control takes: {"op": "submit", "endpoint": name, "params": {...},
  # "values": {name => text}}, as a form's submit_to or a confirm's confirm_to names them
  # (a `call`); the path is what the endpoint is at. The values are the form's inputs by
  # name; what they hold comes from rela's description, at run time, so no kind is named
  # here. stored: the page to go to next (reason "stored"); refused: the form again, with
  # its errors (reason "refused"). Notices come with either.
  @submit [call: :submit, takes: :values, replies: [stored: :view_model, refused: :view_model]]

  defendpoint :create, "/k/:kind/new", @submit
  defendpoint :create_under, "/k/:kind/new/:relation/:parent", @submit
  defendpoint :update, "/k/:kind/:key/edit", @submit
  defendpoint :delete, "/k/:kind/:key/delete", @submit
  defendpoint :link, "/k/:kind/:key/links/:relation", @submit
  defendpoint :accept, "/k/:kind/:key/set/:relation", @submit
  defendpoint :reopen, "/k/:kind/:key/remove/:relation", @submit
  defendpoint :fault, "/fault/:fault", @submit
  defendpoint :fact_fault, "/k/:kind/:key/fault/:fault", @submit

  # The session's other messages, in JSON lines over the socket (bff/README.md, Protocol).
  # Each endpoint's call is the message's "op".

  # A client's first message: its environment, what it is, and the contract version it
  # implements. Control of another environment, or one newer than the client's version,
  # answers bye and closes; else welcome, then its start page. `as`: the key of the fact
  # an agent client is (an agent's, such as coordinator), when it says so; no sign-in yet.
  defmodel :hello do
    field :env, :string, required: true
    field :client, :string, required: true
    field :spec, :string, required: true
    field :as, :string
  end

  defmodel :welcome do
    field :env, :string, required: true
    field :spec, :string, required: true
  end

  defmodel :bye do
    field :text, :string, required: true
  end

  # A line for the status bar: pending (until State answers), ok, error or info.
  defmodel :notice do
    field :tone, :string, required: true
    field :text, :string, required: true
    field :at, :string
  end

  defendpoint :hello, call: :hello, takes: :hello, replies: [welcome: :welcome, bye: :bye]

  # Read the page shown again, from State: what a client does on an interval.
  defendpoint :refresh, call: :refresh, replies: [page: :view_model]

  # What Control sends unasked: a page again when a change it shows was stored by anyone
  # (reason "hint"), a notice, or bye before it closes.
  defendpoint :hint, call: :page, replies: [page: :view_model]
  defendpoint :notice, call: :notice, replies: [notice: :notice]
  defendpoint :bye, call: :bye, replies: [bye: :bye]

  # The agent behind a client's `:` (today `atlas steer`, which the client starts; later
  # Control): ask for a plan made on the page at `on`, run its kept steps, cancel, stop.
  # It answers the plan block, after every change, and notices.
  defmodel :ask do
    field :request, :string, required: true
    field :on, :string, required: true
    field :intent, :string
  end

  defmodel :run_step do
    field :n, :integer, required: true
    field :values, {:map, :string}
  end

  defmodel :run do
    field :steps, {:list, :run_step}, required: true
  end

  defendpoint :ask, call: :ask, takes: :ask, replies: [plan: :plan, notice: :notice]
  defendpoint :run, call: :run, takes: :run, replies: [plan: :plan, notice: :notice]
  defendpoint :cancel, call: :cancel, replies: [plan: :plan]
  defendpoint :stop, call: :stop, replies: [plan: :plan, notice: :notice]
end
