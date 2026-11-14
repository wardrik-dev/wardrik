defmodule Wardrik.Policy.Ask do
  @moduledoc """
  What a call waits on when a policy asks. `Wardrik.Policy.Middleware` parks on it.

    * `:interrupt` - `"tool_approval"` or `"model_approval"`.
    * `:message` - the prompt for the person.
    * `:labels` - labels for what the run had read.
    * `:call` - the tool call it decided, or `nil` for a model call. A call made inside another,
      such as a coding agent's request, is that call, not the one that parked.

  An agent keeps it as `policy_ask`. See `WardrikCore.Format`.
  """

  @behaviour WardrikCore.Format

  alias WardrikCore.ToolCall

  @enforce_keys [:interrupt, :message]
  defstruct [:interrupt, :message, :call, labels: []]

  @type t() :: %__MODULE__{
          interrupt: String.t(),
          message: String.t(),
          call: WardrikCore.ToolCall.t() | nil,
          labels: [String.t()]
        }

  @impl WardrikCore.Format
  def type, do: "policy_ask"

  @impl WardrikCore.Format
  def version, do: 1

  @impl WardrikCore.Format
  def dump(%__MODULE__{} = ask) do
    %{
      "interrupt" => ask.interrupt,
      "message" => ask.message,
      "call" => ask.call && ToolCall.dump(ask.call),
      "labels" => ask.labels
    }
  end

  @impl WardrikCore.Format
  def load(1, %{
        "interrupt" => interrupt,
        "message" => message,
        "call" => call,
        "labels" => labels
      }) do
    with {:ok, call} <- call(call),
         do:
           {:ok, %__MODULE__{interrupt: interrupt, message: message, call: call, labels: labels}}
  end

  defp call(nil), do: {:ok, nil}
  defp call(call), do: ToolCall.load(1, call)
end
