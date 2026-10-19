defprotocol Wardrik.Runtime do
  @moduledoc """
  What runs an agent's turns: it reads the agent's settings from its
  definition, and makes each turn the agent runs under them.

  A host names its runtimes as its `:runtimes`, `Wardrik.LLM.Runtime`'s,
  whose turns ask a model, unless it names others. An agent's config is the
  `Wardrik.Runtime.Settings` a runtime read, whose key names the runtime of
  the host's that makes its turns; see `Wardrik.Host.runtime/2`.

      Wardrik.Host.new(store: store, runtimes: [%Wardrik.LLM.Runtime{}, %MyApp.Harness{}])

  `read/3` answers the settings a definition's `fields` say, with what the
  definition itself resolved, or why they do not read. `turn/3` makes the
  `Wardrik.Turn` an agent runs next under `run`, from its `:history` and the
  messages it is `:asked`, which the turn adds after it, in the task the
  agent runs the turn in.
  """

  @doc "The key an agent's settings name this runtime by."
  @spec key(t()) :: String.t()
  def key(runtime)

  @doc "The settings the definition `fields` say, read with what `context` resolved."
  @spec read(t(), %{String.t() => term()}, Wardrik.Runtime.Context.t()) ::
          {:ok, Wardrik.Runtime.Settings.t()} | {:error, String.t()}
  def read(runtime, fields, context)

  @doc "The turn an agent runs next under `run`, on its `:history`, answering what it is `:asked`."
  @spec turn(t(), Wardrik.Run.t(),
          history: Wardrik.Conversation.t(),
          asked: [Wardrik.Conversation.message()]
        ) :: Wardrik.Turn.t()
  def turn(runtime, run, opts)
end
