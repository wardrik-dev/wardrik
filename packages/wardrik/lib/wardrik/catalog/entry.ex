defmodule Wardrik.Catalog.Entry do
  @moduledoc """
  A function of `Wardrik` as an agent is offered it: its `name`, such as
  `agent.trigger.set`, what it does in a line, the `Wardrik.Grant` action it
  takes, and `run`, which acts on what the tool names with the tool's
  input.

  The tool supplies the subject, the agent or the prefix it acts on: the
  calling agent, or one it names. The input is the rest, as
  `WardrikProtocol`'s `input_<name>.json` describes it, `.` written `_`;
  see `input/1`. `run` answers the output, as `JSON.encode!/1` takes it,
  and the `Wardrik.Label`s of what it holds, or the `Wardrik.Error` it met.

  An entry whose action is not `:read` changes something.
  """

  @enforce_keys [:name, :summary, :action, :run]
  defstruct [:name, :summary, :action, :run]

  @type subject() :: Wardrik.AgentID.t() | Wardrik.AgentID.Prefix.t()

  @type t() :: %__MODULE__{
          name: String.t(),
          summary: String.t(),
          action: Wardrik.Grant.action(),
          run: (Wardrik.Session.t(), subject(), map() ->
                  {:ok, term(), [Wardrik.Label.t()]} | {:error, Wardrik.Error.t()})
        }

  @doc "The JSON Schema of `entry`'s input, whole, with no reference to follow."
  @spec input(t()) :: map()
  def input(%__MODULE__{name: name}),
    do: WardrikProtocol.schema("input_" <> String.replace(name, ".", "_"))
end
