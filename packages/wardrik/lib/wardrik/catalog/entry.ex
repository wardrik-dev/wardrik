defmodule Wardrik.Catalog.Entry do
  @moduledoc """
  How an operation is asked for, on any surface: its name, what it does, the
  input it takes, and the request it builds from that input. An operation
  implements this beside `Wardrik.Query` or `Wardrik.Command`, which say what
  it does, and `Wardrik.AgentOperation` or another, which say what it does it
  to.

  The surface supplies the subject, the agent or the prefix the operation
  acts on, as it knows it: a path on HTTP, an argument on the command line,
  the calling agent for a tool. The input is the rest, as
  `wardrik_protocol`'s `input_<name>.json` describes it, `.` written `_`:

      Wardrik.Operations.SetTrigger.new(~A"acme/triage", %{
        "name" => "sweep",
        "trigger" => %{"every" => "30m", "prompt" => "Look."}
      })

  `Wardrik.Catalog` lists the operations that implement it.
  """

  @doc "Its name in the catalog, such as `agent.trigger.set`."
  @callback name() :: String.t()

  @doc "What it does, in a line, as a surface describes it."
  @callback summary() :: String.t()

  @doc "The JSON Schema of its input, whole, with no reference to follow."
  @callback input() :: map()

  @doc "The request it makes of `subject` with `input`, or why the input does not read."
  @callback new(subject :: term(), input :: map()) ::
              {:ok, struct()} | {:error, Wardrik.Error.t()}
end
