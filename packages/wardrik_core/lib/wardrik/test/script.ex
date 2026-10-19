defmodule Wardrik.Test.Script do
  @moduledoc """
  An agent's settings that `Wardrik.Test.Runtime` runs: what each of its
  turns does, as functions of a test's own, in place of a model.

  `:run` makes the turn, `:resume` carries on a waiting one with the
  decisions it was given, and `:recover` one lost part way. Each is
  `{module, function, args}`, called with the `Wardrik.LLM.Turn` it acts on
  appended to `args`, and `:resume` with the decisions after it, and hands
  the turn back; see `Wardrik.Test.AgentRunners`. An agent's settings are
  written down and read back on another node, and a function is code rather
  than data. `:resume` and `:recover` carry the turn on as it carries itself
  on unless given. `:model` is what the agent's status shows.

      Wardrik.Test.Fleet.start_agent(
        config: Wardrik.Test.Script.new({AgentRunners, :parking, [self(), "call_1"]},
          resume: {AgentRunners, :resuming, [self(), {:ok, []}]}
        )
      )
  """

  @enforce_keys [:run]
  defstruct [
    :run,
    resume: {Wardrik.Turn, :resume, []},
    recover: {Wardrik.Turn, :recover, []},
    model: "test:script"
  ]

  @type t() :: %__MODULE__{run: step(), resume: step(), recover: step(), model: term()}

  @typedoc "A function as `{module, function, args}`, the arguments it is called with first."
  @type step() :: {module(), atom(), list()}

  @doc "The script whose turns `run` makes, with the `:resume`, `:recover` and `:model` in `opts`."
  @spec new(step(), keyword()) :: t()
  def new({module, function, args} = run, opts \\ [])
      when is_atom(module) and is_atom(function) and is_list(args),
      do: struct!(__MODULE__, [run: run] ++ opts)

  defimpl Wardrik.Runtime.Settings do
    def key(_script), do: "test"
    def model(script), do: script.model
    def dump(script), do: script
    def load(script), do: script
  end
end
